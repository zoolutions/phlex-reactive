# frozen_string_literal: true

require "rails_helper"
require_relative "../support/fake_pgbus_presence"

# Issue #358: js.presence reaches the generated presence_set action through
# the ordinary endpoint — the signed token, the typed state schema
# (undeclared keys dropped), authorize_presence_state! — and the write lands
# on the row of the connection the X-Reactive-Presence header names.
RSpec.describe "presence_set (issue #358)", type: :request do
  let(:todo) { Todo.create!(title: "Ship it") }
  let(:stream_name) { Phlex::Reactive::Presence::Transport.stream_name([todo, :presence, :viewers]) }
  let(:presence) { Pgbus.stream(stream_name).presence }

  before do
    FakePgbusPresence.install!(self)
    allow(Phlex::Reactive::Streamable).to receive(:broadcast_component)
    presence.join(member_id: 1, connection_id: "conn-a", seat: "seat-a", metadata: { name: "Ada" })
    presence.join(member_id: 2, connection_id: "conn-b", seat: "seat-b", metadata: { name: "Bob" })
  end

  def set_state(params, connection: "conn-a")
    token = reactive_action_token(TodoViewersComponent, { "gid" => todo.to_gid.to_s })
    post Phlex::Reactive.action_path,
      params: { token:, act: "presence_set", params: }.to_json,
      headers: { "Content-Type" => "application/json", "Accept" => "text/vnd.turbo-stream.html",
                 Phlex::Reactive::Presence::HEADER => connection, "X-Pgbus-Connection" => "app-stream-conn" }
  end

  def state_of(connection) = presence.members.find { it["connection_id"] == connection }["state"]

  it "writes the typed state to the header's connection only, morphs the actor and excludes it from the broadcast" do
    set_state({ selected: "2", colour: "red" })

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('method="morph"')
    expect(state_of("conn-a")).to include("selected" => 2)
    expect(state_of("conn-a")).not_to have_key("colour")
    expect(state_of("conn-b")).to eq({})
    expect(Phlex::Reactive::Streamable).to have_received(:broadcast_component)
      .with(TodoViewersComponent, :replace, anything, anything, anything, hash_including(exclude: "conn-a"))
  end

  # A connection with no row (its row expired, or pgbus never joined it: no
  # identity). Nothing changed, so the peers get no broadcast; the actor still
  # gets its morph.
  it "broadcasts nothing when the connection has no row, and still morphs the actor" do
    set_state({}, connection: "conn-not-joined-yet")

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('method="morph"')
    expect(Phlex::Reactive::Streamable).not_to have_received(:broadcast_component)
  end

  it "shows the actor its own selection in the reply" do
    set_state({ selected: 2 })
    expect(response.body).to include('data-reactive-presence-peer="seat-a"')
  end

  it "refuses what authorize_presence_state! refuses (403) and writes nothing" do
    set_state({ selected: 9 })

    expect(response).to have_http_status(:forbidden)
    expect(state_of("conn-a")).to eq({})
  end

  # The client announces with {} on every pgbus:connected. There is no value
  # to check, so authorize_presence_state! (whose kwargs may be required) is
  # not called; the write is the reverse note on the actor's own row.
  it "always hands the transport a Hash (pgbus raises on anything else), the announce included" do
    allow(Phlex::Reactive::Presence::Transport).to receive(:set_state).and_call_original
    set_state({})
    set_state({ selected: 1 })

    expect(Phlex::Reactive::Presence::Transport).to have_received(:set_state).twice
      .with(stream_name, connection_id: "conn-a", state: an_instance_of(Hash))
  end

  it "accepts the empty announce without calling authorize_presence_state!" do
    allow_any_instance_of(TodoViewersComponent).to receive(:authorize_presence_state!) { |_, selected:| selected } # rubocop:disable RSpec/AnyInstance
    set_state({})

    expect(response).to have_http_status(:ok)
    expect(state_of("conn-a")).to eq("_rp" => { "c" => "TodoViewersComponent", "gid" => todo.to_gid.to_s })
  end

  it "passes verify_authorized without an authorization call (the declared exemption)" do
    Phlex::Reactive.verify_authorized = true
    set_state({ selected: 1 })
    expect(response).to have_http_status(:ok)
  ensure
    Phlex::Reactive.verify_authorized = false
  end
end
