# frozen_string_literal: true

require "rails_helper"

# Issue #248: broadcast_collection_to — the broadcast-side counterpart of
# reply.append/reply.remove. broadcast_to(append:) emits the BARE row and
# nothing else, so every app re-derived the count companion and the 0<->1
# empty-state boundary by hand. This routes the same Collections bookkeeping
# through Turbo::StreamsChannel.
RSpec.describe "Streamable.broadcast_collection_to (issue #248)", type: :request do
  let(:row_component) do
    Class.new(ApplicationComponent) do
      include Phlex::Reactive::Streamable

      def self.name = "BcastCollRow"
      def self.model_param_name = :todo
      def initialize(todo:) = @todo = todo
      def id = dom_id(@todo)
      def view_template = li(id:) { @todo.title }
    end
  end

  let(:empty_component) do
    Class.new(ApplicationComponent) do
      include Phlex::Reactive::Streamable

      def self.name = "BcastCollEmpty"
      def id = "bcastcoll-empty"
      def view_template = div(id:) { "Nothing here" }
    end
  end

  let(:container_class) do
    row = row_component
    empty = empty_component
    Class.new(ApplicationComponent) do
      include Phlex::Reactive::Streamable
      include Phlex::Reactive::Component

      def self.name = "BcastCollList"

      reactive_collection :todos,
        item: row,
        container: "bcastcoll-list",
        count: "bcastcoll-count",
        empty: empty,
        size: -> { @size }

      def initialize(size: 0) = @size = size
      def id = "bcastcoll-root"
      def view_template = div(id:, **reactive_attrs) { "" }
    end
  end

  let(:todo) { Todo.create!(title: "buy milk", done: false) }
  let(:dom_id) { ActionView::RecordIdentifier.dom_id(todo) }

  # Capture every Turbo::StreamsChannel call rather than asserting on a live
  # transport — this must pass identically on Action Cable and pgbus.
  def capture_broadcasts
    calls = []
    allow(Turbo::StreamsChannel).to receive(:broadcast_append_to) { |*a, **k| calls << [:append, a, k] }
    allow(Turbo::StreamsChannel).to receive(:broadcast_prepend_to) { |*a, **k| calls << [:prepend, a, k] }
    allow(Turbo::StreamsChannel).to receive(:broadcast_remove_to) { |*a, **k| calls << [:remove, a, k] }
    allow(Turbo::StreamsChannel).to receive(:broadcast_update_to) { |*a, **k| calls << [:update, a, k] }
    yield
    calls
  end

  describe "append:" do
    it "broadcasts the row INTO the container, plus the count companion" do
      container = container_class.new(size: 1)
      calls = capture_broadcasts do
        container.class.broadcast_collection_to("todos", container:, append: todo, in: :todos)
      end

      append = calls.find { it.first == :append && it.last[:target] == "bcastcoll-list" }
      expect(append).not_to be_nil
      expect(append[1]).to eq(["todos"])
      expect(append.last[:html].to_s).to include(%(id="#{dom_id}"), "buy milk")

      count = calls.find { it.last[:target] == "bcastcoll-count" }
      expect(count).not_to be_nil
      expect(count.last[:html].to_s).to include("1")
    end

    it "clears the empty-state at the 0->1 boundary" do
      container = container_class.new(size: 1)
      calls = capture_broadcasts do
        container.class.broadcast_collection_to("todos", container:, append: todo, in: :todos)
      end

      expect(calls.find { it.first == :remove && it.last[:target] == "bcastcoll-empty" }).not_to be_nil
    end

    it "leaves the empty-state alone when the list was already populated" do
      container = container_class.new(size: 4)
      calls = capture_broadcasts do
        container.class.broadcast_collection_to("todos", container:, append: todo, in: :todos)
      end

      expect(calls.map { it.last[:target] }).not_to include("bcastcoll-empty")
    end
  end

  describe "remove:" do
    it "broadcasts the row remove, the count and the 1->0 empty-state restore" do
      container = container_class.new(size: 0)
      calls = capture_broadcasts do
        container.class.broadcast_collection_to("todos", container:, remove: todo, in: :todos)
      end

      expect(calls.find { it.first == :remove && it.last[:target] == dom_id }).not_to be_nil
      expect(calls.find { it.last[:target] == "bcastcoll-count" }).not_to be_nil
      expect(calls.find { it.first == :append && it.last[:target] == "bcastcoll-list" }.last[:html].to_s)
        .to include("Nothing here")
    end
  end

  describe "validation" do
    it "needs exactly one verb" do
      container = container_class.new
      expect { container_class.broadcast_collection_to("todos", container:, in: :todos) }
        .to raise_error(ArgumentError, /exactly ONE verb/)
    end

    it "refuses an undeclared collection" do
      container = container_class.new
      expect { container_class.broadcast_collection_to("todos", container:, append: todo, in: :nope) }
        .to raise_error(Phlex::Reactive::Error, /undeclared reactive_collection :nope/)
    end
  end

  describe "coalescing the aggregate streams (pgbus#465)" do
    it "coalesces the count companion but never the row stream" do
      container = container_class.new(size: 2)
      seen = []
      allow(Turbo::StreamsChannel).to receive(:broadcast_append_to) do |*, **|
        seen << [:append, Thread.current[:pgbus_broadcast_coalesce]]
      end
      allow(Turbo::StreamsChannel).to receive(:broadcast_update_to) do |*, **|
        seen << [:update, Thread.current[:pgbus_broadcast_coalesce]]
      end
      allow(Phlex::Reactive).to receive(:pgbus_streams?).and_return(true)

      container.class.broadcast_collection_to("todos", container:, append: todo, in: :todos, coalesce: 50)

      expect(seen).to include([:append, nil])
      expect(seen).to include([:update, 50])
    end

    it "sets no coalesce thread-local when coalesce: is absent" do
      container = container_class.new(size: 2)
      seen = []
      allow(Turbo::StreamsChannel).to receive(:broadcast_append_to) { |*, **| seen << Thread.current[:pgbus_broadcast_coalesce] }
      allow(Turbo::StreamsChannel).to receive(:broadcast_update_to) { |*, **| seen << Thread.current[:pgbus_broadcast_coalesce] }
      allow(Phlex::Reactive).to receive(:pgbus_streams?).and_return(true)

      container.class.broadcast_collection_to("todos", container:, append: todo, in: :todos)

      expect(seen.compact).to be_empty
    end
  end
end
