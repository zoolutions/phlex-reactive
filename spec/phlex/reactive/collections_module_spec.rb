# frozen_string_literal: true

require "rails_helper"

# Issue #248: the reactive_collection bookkeeping (row stream + count companion
# + the 0<->1 empty-state toggle) moved out of Response's privates into a
# PUBLIC module, so the reply path and the job-side settle path run the SAME
# code and can never drift. Response.build_collection_* keeps its behaviour by
# delegating.
RSpec.describe Phlex::Reactive::Collections, type: :request do
  let(:row_component) do
    Class.new(ApplicationComponent) do
      include Phlex::Reactive::Streamable

      def self.name = "CollModSpecRow"
      def self.model_param_name = :todo
      def initialize(todo:) = @todo = todo
      def id = dom_id(@todo)
      def view_template = li(id:) { @todo.title }
    end
  end

  let(:empty_component) do
    Class.new(ApplicationComponent) do
      include Phlex::Reactive::Streamable

      def self.name = "CollModSpecEmpty"
      def id = "collmod-empty"
      def view_template = div(id:) { "No todos yet" }
    end
  end

  let(:container_class) do
    row = row_component
    empty = empty_component
    Class.new(ApplicationComponent) do
      include Phlex::Reactive::Streamable
      include Phlex::Reactive::Component

      def self.name = "CollModSpecList"

      reactive_collection :todos,
        item: row,
        container: "collmod-list",
        count: "collmod-count",
        empty: empty,
        size: -> { @size }

      def initialize(size: 0) = @size = size
      def id = "collmod-root"
      def view_template = div(id:, **reactive_attrs) { "" }
    end
  end

  let(:todo) { Todo.create!(title: "buy milk", done: false) }
  let(:dom_id) { ActionView::RecordIdentifier.dom_id(todo) }

  describe ".definition!" do
    it "resolves a declared collection off the container's class" do
      container = container_class.new
      expect(described_class.definition!(container, :todos).name).to eq(:todos)
    end

    it "raises a guided error for an undeclared name" do
      container = container_class.new
      expect { described_class.definition!(container, :nope) }
        .to raise_error(Phlex::Reactive::Error, /undeclared reactive_collection :nope/)
    end
  end

  describe ".add_streams" do
    it "emits the row stream, the count companion and the 0->1 empty-state clear" do
      container = container_class.new(size: 1)
      definition = described_class.definition!(container, :todos)
      streams = described_class.add_streams(definition, container, todo, :append)

      expect(streams.first).to include('action="append"', 'target="collmod-list"', %(id="#{dom_id}"))
      expect(streams.join).to include('target="collmod-count"')
      expect(streams.join).to include('action="remove"', 'target="collmod-empty"')
    end

    it "leaves the empty-state alone when the list was already populated" do
      container = container_class.new(size: 5)
      definition = described_class.definition!(container, :todos)
      streams = described_class.add_streams(definition, container, todo, :append)

      expect(streams.join).not_to include('target="collmod-empty"')
    end

    it "prepends with the :prepend action" do
      container = container_class.new(size: 1)
      definition = described_class.definition!(container, :todos)
      streams = described_class.add_streams(definition, container, todo, :prepend)

      expect(streams.first).to include('action="prepend"', 'target="collmod-list"')
    end
  end

  describe ".remove_streams" do
    it "emits the row remove, the count companion and the 1->0 empty-state restore" do
      container = container_class.new(size: 0)
      definition = described_class.definition!(container, :todos)
      streams = described_class.remove_streams(definition, container, todo)

      expect(streams.first).to include('action="remove"', %(target="#{dom_id}"))
      expect(streams.join).to include('target="collmod-count"')
      expect(streams.join).to include('action="append"', 'target="collmod-list"', "No todos yet")
    end

    it "accepts an already-built dom-id string" do
      container = container_class.new(size: 3)
      definition = described_class.definition!(container, :todos)
      streams = described_class.remove_streams(definition, container, "todo_99")

      expect(streams.first).to include('action="remove"', 'target="todo_99"')
    end
  end

  describe "resolving the size ONCE per delta" do
    # The resolver is usually a DB count. Evaluating it twice per delta is an
    # extra query AND a correctness hazard: a concurrent write landing between
    # the two reads would ship a count companion that disagrees with the
    # empty-state toggle beside it.
    it "evaluates the size resolver exactly once for an add" do
      calls = 0
      counter = lambda {
        calls += 1
        1
      }
      klass = Class.new(container_class) do
        def self.name = "CollModSpecCounted"
      end
      klass.reactive_collection :todos,
        item: row_component, container: "collmod-list",
        count: "collmod-count", empty: empty_component, size: counter

      container = klass.new
      described_class.add_streams(described_class.definition!(container, :todos), container, todo, :append)

      expect(calls).to eq(1)
    end

    it "evaluates the size resolver exactly once for a remove" do
      calls = 0
      counter = lambda {
        calls += 1
        0
      }
      klass = Class.new(container_class) do
        def self.name = "CollModSpecCountedRemove"
      end
      klass.reactive_collection :todos,
        item: row_component, container: "collmod-list",
        count: "collmod-count", empty: empty_component, size: counter

      container = klass.new
      described_class.remove_streams(described_class.definition!(container, :todos), container, todo)

      expect(calls).to eq(1)
    end

    it "passes the SAME size to the count companion and the empty-state boundary" do
      sizes = [1, 99] # a second evaluation would return a different number
      klass = Class.new(container_class) do
        def self.name = "CollModSpecDrifting"
      end
      klass.reactive_collection :todos,
        item: row_component, container: "collmod-list",
        count: "collmod-count", empty: empty_component, size: -> { sizes.shift }

      container = klass.new
      streams = described_class.add_streams(
        described_class.definition!(container, :todos), container, todo, :append
      ).join

      # size 1 => count reads "1" AND the 0->1 empty-state clear fires. If the
      # resolver ran twice, the toggle would have seen 99 and stayed silent.
      expect(streams).to include(">1<")
      expect(streams).to include('action="remove"', 'target="collmod-empty"')
    end
  end

  describe ".count_streams" do
    it "emits only the count companion update" do
      container = container_class.new(size: 7)
      definition = described_class.definition!(container, :todos)
      streams = described_class.count_streams(definition, container)

      expect(streams.size).to eq(1)
      expect(streams.first).to include('target="collmod-count"', "7")
    end

    it "is empty when the declaration has no count companion" do
      klass = Class.new(ApplicationComponent) do
        include Phlex::Reactive::Streamable
        include Phlex::Reactive::Component

        def self.name = "CollModSpecNoCount"
        def id = "nocount-root"
      end
      klass.reactive_collection :todos, item: row_component, container: "nocount-list"
      container = klass.new
      definition = described_class.definition!(container, :todos)

      expect(described_class.count_streams(definition, container)).to eq([])
    end
  end

  describe "Response.build_collection_* delegation" do
    it "produces the same streams as the module" do
      container = container_class.new(size: 1)
      definition = described_class.definition!(container, :todos)

      via_reply = container.reply.append(todo, to: :todos).streams.map(&:to_s)
      via_module = described_class.add_streams(definition, container, todo, :append).map(&:to_s)

      expect(via_reply).to eq(via_module)
    end
  end
end
