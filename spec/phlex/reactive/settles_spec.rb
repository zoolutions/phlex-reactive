# frozen_string_literal: true

require "rails_helper"

# Issue #248 — the job side: Phlex::Reactive::Settles gives a job
# `reactive_settle`, which rebuilds the container off the request thread and
# emits the SAME collection bookkeeping the actor's reply would have.
RSpec.describe Phlex::Reactive::Settles, type: :request do
  let(:row_component) do
    Class.new(ApplicationComponent) do
      include Phlex::Reactive::Streamable

      def self.name = "SettleSpecRow"
      def self.model_param_name = :todo
      def initialize(todo:) = @todo = todo
      def id = dom_id(@todo)
      def view_template = li(id:) { @todo.title }
    end
  end

  let(:empty_component) do
    Class.new(ApplicationComponent) do
      include Phlex::Reactive::Streamable

      def self.name = "SettleSpecEmpty"
      def id = "settle-empty"
      def view_template = div(id:) { "All done" }
    end
  end

  let(:container_class) do
    row = row_component
    empty = empty_component
    stub_const("SettleSpecList", Class.new(ApplicationComponent) do
      include Phlex::Reactive::Streamable
      include Phlex::Reactive::Component

      reactive_collection :todos,
        item: row,
        container: "settle-list",
        count: "settle-count",
        empty: empty,
        size: -> { Todo.count }

      reactive_collection :archive,
        item: row,
        container: "settle-archive",
        size: -> { Todo.count }

      def id = "settle-root"
      def view_template = div(id:, **reactive_attrs) { "" }
    end)
  end

  let(:todo) { Todo.create!(title: "buy milk", done: false) }

  let(:handle) do
    Phlex::Reactive::Pending::Handle.new(
      stream_key: "prdefer_abc123",
      container_class: container_class.name,
      container_payload: { "c" => container_class.name },
      anchor: "settle-root",
      collection: :todos,
      count: 1,
      peers: nil,
      connection_id: "conn-1"
    )
  end

  # Capture what the job broadcasts on the actor's one-shot stream.
  let(:broadcasts) { [] }

  before do
    captured = broadcasts
    # A STRING reference on purpose: pgbus is optional, so the constant may not
    # be loaded — verifying against it would make this spec pgbus-dependent.
    # rubocop:disable-next RSpec/VerifiedDoubleReference
    stream = instance_double("Pgbus::Streams::Stream")
    allow(stream).to receive(:broadcast) { |html, **| captured << html.to_s }
    stub_const("Pgbus", Module.new) unless defined?(Pgbus)
    allow(Pgbus).to receive(:stream).and_return(stream)
  end

  # A job whose handle is already installed (as ActiveJob deserialize would).
  def job_with(handle_value)
    klass = Class.new do
      include Phlex::Reactive::Settles

      def self.name = "SettleSpecJob"
    end
    job = klass.new
    job.instance_variable_set(:@reactive_settle_handle, handle_value)
    job
  end

  describe "no handle (a sweep or webhook enqueued the same job)" do
    it "is a no-op — the block never runs and nothing is broadcast" do
      ran = false
      job_with(nil).reactive_settle { ran = true }

      expect(ran).to be(false)
      expect(broadcasts).to be_empty
    end

    it "returns nil so the job can branch on it" do
      expect(job_with(nil).reactive_settle { :x }).to be_nil
    end
  end

  describe "s.remove" do
    it "broadcasts the row remove, the count companion and the empty-state restore" do
      todo_id = ActionView::RecordIdentifier.dom_id(todo)
      todo.destroy!
      job_with(handle).reactive_settle { it.remove(todo, from: :todos) }

      payload = broadcasts.join
      expect(payload).to include('action="remove"', %(target="#{todo_id}"))
      expect(payload).to include('target="settle-count"')
      expect(payload).to include('action="append"', 'target="settle-list"', "All done")
    end

    it "defaults from: to the collection the pending call named" do
      todo_id = ActionView::RecordIdentifier.dom_id(todo)
      job_with(handle).reactive_settle { it.remove(todo) }

      expect(broadcasts.join).to include('action="remove"', %(target="#{todo_id}"))
    end
  end

  describe "s.replace" do
    it "re-renders the row in place with no count churn (a replace moves no boundary)" do
      job_with(handle).reactive_settle { it.replace(todo) }

      payload = broadcasts.join
      expect(payload).to include('action="replace"', "buy milk")
      expect(payload).not_to include('target="settle-count"')
    end
  end

  describe "s.append" do
    it "broadcasts the row into the container plus the aggregates" do
      job_with(handle).reactive_settle { it.append(todo, to: :todos) }

      payload = broadcasts.join
      expect(payload).to include('action="append"', 'target="settle-list"', "buy milk")
      expect(payload).to include('target="settle-count"')
    end
  end

  describe "s.move" do
    it "removes the row first, then appends it into the other container" do
      todo_id = ActionView::RecordIdentifier.dom_id(todo)
      job_with(handle).reactive_settle { it.move(todo, from: :todos, to: :archive) }

      payload = broadcasts.join
      # Ordered remove-then-append: the row is never momentarily in both lists.
      expect(payload.index(%(target="#{todo_id}"))).to be < payload.index('target="settle-archive"')
      expect(payload).to include('action="append"', 'target="settle-archive"')
      # Both collections' aggregates refresh — the source list's count too.
      expect(payload).to include('target="settle-count"')
    end
  end

  describe "s.flash" do
    it "appends a flash so the operator learns the outcome" do
      job_with(handle).reactive_settle { it.flash(:alert, "Could not re-execute") }

      expect(broadcasts.join).to include("Could not re-execute", 'target="flash"')
    end
  end

  describe "finish (teardown of the SHARED one-shot subscription)" do
    it "tears down when the pending call marked exactly one target" do
      job_with(handle).reactive_settle { it.replace(todo) }

      payload = broadcasts.join
      expect(payload).to include('action="remove"', 'target="reactive-defer-src-settle-root"')
      expect(payload).to include("data-reactive-pending")
    end

    it "does NOT tear down mid-fan-out — a shared key must outlive the first arrival" do
      fanned = handle.with(count: 177)
      job_with(fanned).reactive_settle { it.replace(todo) }

      expect(broadcasts.join).not_to include('target="reactive-defer-src-settle-root"')
    end

    it "tears down on an explicit finish: true (the batch's on_finish callback)" do
      fanned = handle.with(count: 177)
      job_with(fanned).reactive_settle(finish: true) { it.replace(todo) }

      expect(broadcasts.join).to include('target="reactive-defer-src-settle-root"')
    end

    it "suppresses teardown on an explicit finish: false even for a single target" do
      job_with(handle).reactive_settle(finish: false) { it.replace(todo) }

      expect(broadcasts.join).not_to include('target="reactive-defer-src-settle-root"')
    end
  end

  describe "failure safety" do
    it "clears the target's pending markers and re-raises for the retry policy" do
      expect do
        job_with(handle).reactive_settle { raise "work failed" }
      end.to raise_error("work failed")

      payload = broadcasts.join
      expect(payload).to include('action="reactive:js"')
      expect(payload).to include("remove_attr")
    end

    it "does NOT tear the subscription down on failure — a retry must still reach the actor" do
      expect { job_with(handle).reactive_settle { raise "work failed" } }.to raise_error("work failed")

      expect(broadcasts.join).not_to include('target="reactive-defer-src-settle-root"')
    end

    it "clears pending for a container that vanished while the job was queued" do
      allow(container_class).to receive(:from_identity)
        .and_raise(ActiveRecord::RecordNotFound, "gone")

      expect { job_with(handle).reactive_settle { it.replace(todo) } }
        .to raise_error(ActiveRecord::RecordNotFound)
      expect(broadcasts.join).to include("remove_attr")
    end

    it "never swallows a cleanup-broadcast failure — that propagates to the retry policy" do
      allow(Pgbus).to receive(:stream).and_raise(RuntimeError, "postgres down")

      expect { job_with(handle).reactive_settle { it.replace(todo) } }
        .to raise_error(RuntimeError, "postgres down")
    end
  end

  describe "peers" do
    it "broadcasts the same delta to the peer stream, excluding the actor's echo" do
      peered = handle.with(peers: [{ "gid" => todo.to_gid.to_s }])
      calls = []
      allow(Turbo::StreamsChannel).to receive(:broadcast_remove_to) { |*a, **k| calls << [a, k] }
      allow(Turbo::StreamsChannel).to receive(:broadcast_update_to) { |*a, **k| calls << [a, k] }
      allow(Turbo::StreamsChannel).to receive(:broadcast_append_to) { |*a, **k| calls << [a, k] }
      allow(Phlex::Reactive).to receive(:pgbus_streams?).and_return(true)

      excludes = []
      allow(Phlex::Reactive::Streamable).to receive(:dispatch_broadcast).and_wrap_original do |m, *a|
        excludes << Thread.current[:pgbus_broadcast_exclude]
        m.call(*a)
      end

      job_with(peered).reactive_settle { it.remove(todo, from: :todos) }

      expect(calls).not_to be_empty
      expect(excludes.uniq).to eq(["conn-1"])
    end

    it "does not touch the channel when the handle carries no peers" do
      expect(Turbo::StreamsChannel).not_to receive(:broadcast_remove_to)
      job_with(handle).reactive_settle { it.remove(todo, from: :todos) }
    end
  end

  describe "ActiveJob metadata round trip" do
    it "captures the handle at enqueue and restores it at perform" do
      klass = Class.new(ActiveJob::Base) do
        include Phlex::Reactive::Settles

        def self.name = "SettleSpecRoundTrip"
        def perform(*) = nil
      end

      job = klass.new
      data = Phlex::Reactive::Pending.with_handle(handle) { job.serialize }
      expect(data["phlex_reactive_settle"]).to include("key" => "prdefer_abc123")

      restored = klass.new
      restored.deserialize(data)
      expect(restored.instance_variable_get(:@reactive_settle_handle).stream_key).to eq("prdefer_abc123")
    end

    it "carries no metadata key when no pending call was in flight" do
      klass = Class.new(ActiveJob::Base) do
        include Phlex::Reactive::Settles

        def self.name = "SettleSpecNoHandle"
        def perform(*) = nil
      end

      expect(klass.new.serialize).not_to have_key("phlex_reactive_settle")
    end
  end
end
