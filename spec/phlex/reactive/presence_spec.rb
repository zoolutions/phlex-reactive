# frozen_string_literal: true

require "rails_helper"
require_relative "../../support/fake_pgbus_presence"

# Issue #358: reactive_presence — the roster of a presence stream. Who is
# viewing (one peer per tab, grouped by member), each tab's declared state,
# the generated presence_set action, and the root's subscription marker. The
# default suite has no pgbus; FakePgbusPresence stubs the #515 transport shape.
RSpec.describe Phlex::Reactive::Presence, "reactive_presence (issue #358)" do
  let(:todo) { Todo.create!(title: "Ship it") }
  let(:stream_name) { Phlex::Reactive::Presence::Transport.stream_name([todo, :presence, :viewers]) }

  def render_html(component) = Phlex::Reactive.render(component)

  context "with a seat-capable transport" do
    let(:presence) { Pgbus.stream(stream_name).presence }

    before do
      FakePgbusPresence.install!(self)
      presence.join(member_id: 1, connection_id: "c1", seat: "seat-a", metadata: { name: "Ada" })
      presence.join(member_id: 1, connection_id: "c2", seat: "seat-b", metadata: { name: "Ada" })
      presence.join(member_id: 2, connection_id: "c3", seat: "seat-c", metadata: { name: "Bob" })
      presence.set_state(connection_id: "c3", state: { "selected" => 2, "_rp" => { "c" => "X" } })
      # A seatless row: pgbus joins every connection on a presence stream, and
      # one without ?seat= (an app's own turbo_stream_from of the stream, a
      # source without `presence`, a stale client) has no seat. Its connection
      # id is the bearer key for writing its row: it must never be a peer.
      presence.join(member_id: 3, connection_id: "secret-conn-7f3a", seat: nil, metadata: { name: "Cy" })
      presence.set_state(connection_id: "secret-conn-7f3a", state: { "selected" => 2 })
    end

    it "declares presence_set with the state schema and skips verify_authorized for it" do
      actions = TodoViewersComponent.reactive_actions
      expect(actions[:presence_set].params).to eq(selected: :integer)
      expect(TodoViewersComponent.skip_verify_authorized?(:presence_set)).to be(true)
      expect(TodoViewersComponent.skip_verify_authorized?(:other)).to be(false)
    end

    # Real SSE: the raw "<gid param>:presence:<name>" overflows pgbus's
    # stream-name budget (41 chars) once the record's id has two digits —
    # StreamNameTooLong on render. pgbus's stream_key digests the record to a
    # fixed length and keeps the ":presence:<name>" suffix the patterns match.
    # The key is "<16 hex of the record's global id>:presence:<name>": a fixed
    # length whatever the model is called (a digest per model name, like
    # pgbus's own record fragment, overflows for Document, Conversation, …).
    context "with a record whose global id is long" do
      let(:todo) { Todo.create!(id: 987_654_321, title: "Ship it") }

      it "keys the stream by a digest of the record and uses that one key everywhere" do
        component = TodoViewersComponent.new(todo:)
        expect(stream_name).to eq("#{Digest::SHA256.hexdigest(todo.to_gid_param)[0, 16]}:presence:viewers")
        expect(component.reactive_presence_stream_name).to eq(stream_name)
        expect(render_html(component)).to include(%(data-reactive-presence="/pgbus/streams/signed-#{stream_name}"))

        allow(Phlex::Reactive::Streamable).to receive(:broadcast_component)
        presence.join(member_id: 1, connection_id: "c9", seat: "seat-z", metadata: {})
        described_class.with_connection_id("c9") { component.presence.set(selected: 1) }
        expect(presence.members.find { it["connection_id"] == "c9" }["state"]).to include("selected" => 1)
        expect(Phlex::Reactive::Streamable).to have_received(:broadcast_component)
          .with(TodoViewersComponent, :replace, anything, anything, [stream_name], anything)

        described_class.render_roster(stream_name)
        expect(Phlex::Reactive::Streamable).to have_received(:broadcast_component)
          .with(TodoViewersComponent, :replace, anything, anything, [stream_name], hash_including(exclude: nil))
      end
    end

    context "with a long model name" do
      it "renders a :viewers roster within pgbus's stream-name budget" do
        stub_const("ProjectBoardConversation", Class.new(Todo))
        stub_const("ProjectBoardConversationViewers", Class.new(ApplicationComponent) do
          include Phlex::Reactive::Component

          reactive_record :board
          reactive_presence :viewers

          def initialize(board:) = @board = board
          def id = "board-viewers-#{@board.id}"
          def view_template = div(**reactive_root)
        end)
        board = ProjectBoardConversation.new(id: 123_456_789, title: "Roadmap")

        component = ProjectBoardConversationViewers.new(board:)
        expect { render_html(component) }.not_to raise_error
        expect(component.reactive_presence_stream_name.length).to be <= Pgbus.stream_name_budget
      end
    end

    context "with a presence name too long for the budget" do
      def oversized_class
        Class.new(ApplicationComponent) do
          include Phlex::Reactive::Component

          def self.name = "OversizedViewers"
          reactive_record :todo
          reactive_presence :everyone_on_this_page_right_now

          def initialize(todo:) = @todo = todo
          def id = "oversized-#{@todo.id}"
          def view_template = div(**reactive_root)
        end
      end

      it "refuses the name at declaration, naming it and the budget" do
        expect { oversized_class }
          .to raise_error(Phlex::Reactive::ConfigurationError, /everyone_on_this_page_right_now.*41/m)
      end

      # Declared while the transport was not wired (no check then): the render
      # is the backstop.
      it "raises the same ConfigurationError at render when the declaration could not check" do
        allow(Phlex::Reactive::Presence::Transport).to receive(:wired?).and_return(false)
        klass = oversized_class
        allow(Phlex::Reactive::Presence::Transport).to receive(:wired?).and_call_original

        expect { render_html(klass.new(todo:)) }
          .to raise_error(Phlex::Reactive::ConfigurationError, /everyone_on_this_page_right_now.*41/m)
      end
    end

    it "keeps its own error for a roster with neither reactive_record nor key:" do
      nokey = Class.new(ApplicationComponent) do
        include Phlex::Reactive::Component

        def self.name = "NoKeyViewers"
        reactive_state :value
        reactive_presence :viewers

        def initialize(value: 1) = @value = value
        def id = "nokey"
        def view_template = div(**reactive_root)
      end

      expect { render_html(nokey.new) }.to raise_error(ArgumentError, /needs reactive_record/) do
        expect(it).not_to be_a(Phlex::Reactive::ConfigurationError)
      end
    end

    # For a strict per-record check in streams_authorize: the key of each
    # record the user may view, compared with the stream name pgbus asks about.
    it "computes a record's presence stream name from the class, the same key the roster uses" do
      expect(TodoViewersComponent.reactive_presence_stream_name_for(todo))
        .to eq(TodoViewersComponent.new(todo:).reactive_presence_stream_name)
      other = Todo.create!(title: "Other")
      expect(TodoViewersComponent.reactive_presence_stream_name_for(other)).not_to eq(stream_name)
    end

    it "marks the root with the signed presence stream src" do
      html = render_html(TodoViewersComponent.new(todo:))
      expect(html).to include(%(data-reactive-presence="/pgbus/streams/signed-#{stream_name}"))
    end

    # Real SSE: a roster need not render an element per tab (this one shows
    # people, and tabs only where they selected a step), so the root itself
    # names the seats it rendered — what the client diffs for reactive:presence
    # and checks to know its own tab is on the roster. Seats only: no member id
    # or connection id rides on it.
    it "names every seat it rendered on the root, whatever the template shows" do
      html = render_html(TodoViewersComponent.new(todo:))
      expect(html).to include(%(data-reactive-presence-roster="seat-a seat-b seat-c"))
    end

    it "names no seats on the root of an empty roster" do
      presence.leave(connection_id: "c1")
      presence.leave(connection_id: "c2")
      presence.leave(connection_id: "c3")
      expect(render_html(TodoViewersComponent.new(todo:))).to include(%(data-reactive-presence-roster=""))
    end

    it "lists one peer per tab and groups them by member" do
      roster = TodoViewersComponent.new(todo:).presence
      expect(roster.peers.map(&:seat)).to eq(%w[seat-a seat-b seat-c])
      expect(roster.count).to eq(3)
      expect(roster.members.map(&:id)).to eq(%w[1 2])
      expect(roster.members.first.seats.map(&:seat)).to eq(%w[seat-a seat-b])
      expect(roster.members.last.metadata).to eq("name" => "Bob")
    end

    it "exposes only the declared state, never the reverse note" do
      bob = TodoViewersComponent.new(todo:).presence.peers.last
      expect(bob.state).to eq(selected: 2)
      expect(TodoViewersComponent.new(todo:).presence.where(selected: 2).map(&:seat)).to eq(["seat-c"])
    end

    # The connection id is the bearer key for writing a row: it stays inside
    # the Roster (only `me` uses it) and never reaches a template.
    it "never exposes a connection id on a peer or in the render" do
      peer = TodoViewersComponent.new(todo:).presence.peers.first
      expect(peer).not_to respond_to(:connection_ids)
      expect(peer.to_h.values.flatten.map(&:to_s)).not_to include("c1")
      expect(render_html(TodoViewersComponent.new(todo:))).not_to match(/\bc[123]\b/)
    end

    it "leaves a seatless row out of the roster, so its connection id is never rendered" do
      roster = TodoViewersComponent.new(todo:).presence
      expect(roster.peers.map(&:seat)).to eq(%w[seat-a seat-b seat-c])
      expect(roster.members.map(&:id)).to eq(%w[1 2])
      expect(roster.where(selected: 2).map(&:seat)).to eq(["seat-c"])

      html = render_html(TodoViewersComponent.new(todo:))
      expect(html).not_to include("secret-conn-7f3a")
      expect(html).to include(%(data-reactive-presence-roster="seat-a seat-b seat-c"))
    end

    it "finds no `me` for an actor whose own row has no seat" do
      roster = described_class.with_connection_id("secret-conn-7f3a") { TodoViewersComponent.new(todo:).presence }
      expect(roster.me).to be_nil
    end

    it "merges two connections of one seat into one peer" do
      presence.join(member_id: 2, connection_id: "c4", seat: "seat-c", metadata: { name: "Bob" })
      roster = TodoViewersComponent.new(todo:).presence
      expect(roster.peers.map(&:seat)).to eq(%w[seat-a seat-b seat-c])
      expect(roster.peers.last.state).to eq(selected: 2)
    end

    it "renders who is here and who is on which step" do
      html = render_html(TodoViewersComponent.new(todo:))
      expect(html).to include(%(data-reactive-presence-member="1" data-reactive-presence-seats="2"))
      expect(html).to include(%(data-reactive-presence-peer="seat-c" data-reactive-presence-member="2"))
    end

    describe "#presence.set" do
      it "writes the merged state and the reverse note to the actor's own row, then broadcasts to the others" do
        component = TodoViewersComponent.new(todo:)
        allow(Phlex::Reactive::Streamable).to receive(:broadcast_component)

        peer = described_class.with_connection_id("c1") { component.presence.set(selected: 3) }

        expect(peer.seat).to eq("seat-a")
        expect(peer.state).to eq(selected: 3)
        row = presence.members.find { it["connection_id"] == "c1" }
        expect(row["state"]).to eq("selected" => 3, "_rp" => { "c" => "TodoViewersComponent", "gid" => todo.to_gid.to_s })
        expect(Phlex::Reactive::Streamable).to have_received(:broadcast_component)
          .with(TodoViewersComponent, :replace, anything, anything, [stream_name],
            hash_including(morph: true, exclude: "c1", coalesce: Phlex::Reactive::Presence::COALESCE_MS))
      end

      # A seatless actor (its connection sent no ?seat=) is on no roster, so
      # nothing any viewer sees changed: the row is written, nothing broadcast.
      it "writes a seatless actor's row but broadcasts nothing" do
        component = TodoViewersComponent.new(todo:)
        allow(Phlex::Reactive::Streamable).to receive(:broadcast_component)

        result = described_class.with_connection_id("secret-conn-7f3a") { component.presence.set(selected: 1) }

        expect(result).to be_nil
        expect(presence.members.find { it["connection_id"] == "secret-conn-7f3a" }["state"]).to include("selected" => 1)
        expect(Phlex::Reactive::Streamable).not_to have_received(:broadcast_component)
      end

      it "is a no-op without a presence connection (the tab has not connected yet)" do
        allow(Phlex::Reactive::Streamable).to receive(:broadcast_component)
        expect(TodoViewersComponent.new(todo:).presence.set(selected: 1)).to be_nil
        expect(Phlex::Reactive::Streamable).not_to have_received(:broadcast_component)
      end

      it "refuses undeclared state keys" do
        expect { TodoViewersComponent.new(todo:).presence.set(colour: "red") }
          .to raise_error(ArgumentError, /colour/)
      end

      it "knows the actor's own peer" do
        roster = described_class.with_connection_id("c2") { TodoViewersComponent.new(todo:).presence }
        expect(roster.me.seat).to eq("seat-b")
        expect(TodoViewersComponent.new(todo:).presence.me).to be_nil
      end
    end

    describe "#presence_set" do
      it "calls authorize_presence_state! first" do
        component = TodoViewersComponent.new(todo:)
        expect do
          described_class.with_connection_id("c1") { component.presence_set(selected: 9) }
        end.to raise_error(TodoViewersComponent::Denied)
        expect(presence.members.find { it["connection_id"] == "c1" }["state"]).to eq({})
      end

      it "replies with a morph" do
        allow(Phlex::Reactive::Streamable).to receive(:broadcast_component)
        reply = described_class.with_connection_id("c1") do
          TodoViewersComponent.new(todo:).presence_set(selected: 1)
        end
        expect(reply).to be_a(Phlex::Reactive::Response)
      end
    end
  end

  context "without a seat-capable transport" do
    it "raises a configuration error at render (no pgbus)" do
      skip "pgbus is loaded in this process" if defined?(Pgbus)
      expect { render_html(TodoViewersComponent.new(todo:)) }
        .to raise_error(Phlex::Reactive::ConfigurationError, /pgbus.*connection/m)
    end

    it "raises on a pgbus whose presence is keyed by member (the old shape)" do
      FakePgbusPresence.install!(self, shape: :old)
      expect { render_html(TodoViewersComponent.new(todo:)) }
        .to raise_error(Phlex::Reactive::ConfigurationError)
    end
  end

  describe "the declaration" do
    def declare(&)
      Class.new(Phlex::HTML) do
        include Phlex::Reactive::Component

        def self.name = "Roster"

        reactive_record :board
        class_exec(&)
      end
    end

    it "validates ttl:, the name, the state types and the reserved key" do
      expect { declare { reactive_presence :viewers, ttl: 0 } }.to raise_error(ArgumentError, /ttl/)
      expect { declare { reactive_presence "bad name" } }.to raise_error(ArgumentError, /name/)
      expect { declare { reactive_presence :viewers, state: { a: :nope } } }
        .to raise_error(Phlex::Reactive::UnknownParamType)
      expect { declare { reactive_presence :viewers, state: { _rp: :string } } }.to raise_error(ArgumentError, /_rp/)
    end

    # A ttl at or below the transport's heartbeat would expire a live tab
    # between two beats. The interval is read from configuration (no query),
    # 15 s without pgbus.
    it "refuses a ttl at or below the heartbeat interval" do
      expect { declare { reactive_presence :viewers, ttl: 15 } }.to raise_error(ArgumentError, /heartbeat.*15/)
      expect { declare { reactive_presence :viewers, ttl: 16 } }.not_to raise_error
    end

    it "reads the heartbeat interval from pgbus's configuration" do
      _store, config = FakePgbusPresence.install!(self)
      config.streams_heartbeat_interval = 5
      expect { declare { reactive_presence :viewers, ttl: 10 } }.not_to raise_error
      expect { declare { reactive_presence :viewers, ttl: 5 } }.to raise_error(ArgumentError, /heartbeat.*5/)
    end

    it "refuses a dormant presence root" do
      expect { declare { reactive_dormant; reactive_presence :viewers } } # rubocop:disable Style/Semicolon
        .to raise_error(ArgumentError, /dormant/)
      expect { declare { reactive_presence :viewers; reactive_dormant } } # rubocop:disable Style/Semicolon
        .to raise_error(ArgumentError, /dormant/)
    end

    it "is not on a client-only component (presence needs the signed token)" do
      expect do
        Class.new(Phlex::HTML) do
          include Phlex::Reactive::ClientBindings

          reactive_presence :viewers
        end
      end.to raise_error(NoMethodError, /reactive_presence/)
    end

    it "keeps Object#presence on components that declare no presence" do
      expect(Phlex::Reactive::Component).not_to be_method_defined(:presence_set)
      expect(CounterComponent.new.presence).to be_a(CounterComponent)
    end
  end

  describe "the helpers" do
    let(:peer) do
      Phlex::Reactive::Presence::Peer.new(seat: "s1", member_id: "7", metadata: {}, state: {}, joined_at: nil)
    end

    it "reactive_presence_peer marks a seat and its member" do
      FakePgbusPresence.install!(self)
      component = TodoViewersComponent.new(todo:)
      expect(component.reactive_presence_peer(peer))
        .to eq(data: { reactive_presence_peer: "s1", reactive_presence_member: "7" })
      member = Phlex::Reactive::Presence::Member.new(id: "7", metadata: {}, seats: [peer, peer])
      expect(component.reactive_presence_member(member))
        .to eq(data: { reactive_presence_member: "7", reactive_presence_seats: "2" })
    end
  end
end
