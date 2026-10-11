# frozen_string_literal: true

require "rails_helper"
require_relative "../../support/fake_pgbus_presence"

# Issue #358: a join, leave or expiry on a presence stream re-renders the
# roster for every viewer. The stream name cannot be turned back into a record
# (pgbus digests it), so the job reads the reverse note a presence write
# leaves on each seat row and rebuilds every component class it names.
RSpec.describe Phlex::Reactive::PresenceRenderJob do
  let(:todo) { Todo.create!(title: "Ship it") }
  let(:stream_name) { Phlex::Reactive::Presence::Transport.stream_name([todo, :presence, :viewers]) }
  let(:note) { { "c" => "TodoViewersComponent", "gid" => todo.to_gid.to_s } }

  before do
    FakePgbusPresence.install!(self)
    allow(Phlex::Reactive::Streamable).to receive(:broadcast_component)
  end

  def presence = Pgbus.stream(stream_name).presence

  it "morphs the roster for every viewer, the joiner included, coalesced" do
    presence.join(member_id: 1, connection_id: "c1", seat: "a", metadata: {})
    presence.set_state(connection_id: "c1", state: { "_rp" => note })

    described_class.perform_now(stream_name)

    expect(Phlex::Reactive::Streamable).to have_received(:broadcast_component).once
      .with(TodoViewersComponent, :replace, an_instance_of(TodoViewersComponent), anything,
        [stream_name],
        hash_including(morph: true, exclude: nil, coalesce: Phlex::Reactive::Presence::COALESCE_MS))
  end

  it "renders nothing when no seat carries a note (nobody left, or nobody announced yet)" do
    presence.join(member_id: 1, connection_id: "c1", seat: "a", metadata: {})
    described_class.perform_now(stream_name)
    expect(Phlex::Reactive::Streamable).not_to have_received(:broadcast_component)
  end

  it "refuses a note that names a class without presence" do
    presence.join(member_id: 1, connection_id: "c1", seat: "a", metadata: {})
    presence.set_state(connection_id: "c1", state: { "_rp" => note.merge("c" => "CounterComponent") })
    described_class.perform_now(stream_name)
    expect(Phlex::Reactive::Streamable).not_to have_received(:broadcast_component)
  end

  it "renders once per distinct component class on the stream" do
    presence.join(member_id: 1, connection_id: "c1", seat: "a", metadata: {})
    presence.join(member_id: 2, connection_id: "c2", seat: "b", metadata: {})
    presence.set_state(connection_id: "c1", state: { "_rp" => note })
    presence.set_state(connection_id: "c2", state: { "_rp" => note })
    described_class.perform_now(stream_name)
    expect(Phlex::Reactive::Streamable).to have_received(:broadcast_component).once
  end

  it "drops a stream whose record is gone" do
    presence.join(member_id: 1, connection_id: "c1", seat: "a", metadata: {})
    presence.set_state(connection_id: "c1", state: { "_rp" => note })
    todo.destroy!
    expect { described_class.perform_now(stream_name) }.not_to raise_error
    expect(Phlex::Reactive::Streamable).not_to have_received(:broadcast_component)
  end
end
