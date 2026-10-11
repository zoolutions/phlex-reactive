# frozen_string_literal: true

require "rails_helper"
require_relative "../support/fake_pgbus_presence"

# Issue #358: js.presence reaches the generated presence_set action through
# the ordinary endpoint — the signed token, the typed state schema
# (undeclared keys dropped), authorize_presence_state! — and the write lands
# on the row of the connection the X-Reactive-Presence header names.
RSpec.describe "presence_set (issue #358)", type: :request do
  let(:todo) { Todo.create!(title: "Ship it") }
  let(:stream_name) { "#{todo.to_gid_param}:presence:viewers" }
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

  it "shows the actor its own selection in the reply" do
    set_state({ selected: 2 })
    expect(response.body).to include('data-reactive-presence-peer="seat-a"')
  end

  it "refuses what authorize_presence_state! refuses (403) and writes nothing" do
    set_state({ selected: 9 })

    expect(response).to have_http_status(:forbidden)
    expect(state_of("conn-a")).to eq({})
  end

  it "passes verify_authorized without an authorization call (the declared exemption)" do
    Phlex::Reactive.verify_authorized = true
    set_state({ selected: 1 })
    expect(response).to have_http_status(:ok)
  ensure
    Phlex::Reactive.verify_authorized = false
  end
end
