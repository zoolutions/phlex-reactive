# frozen_string_literal: true

require "spec_helper"
require "phlex"

# Issue #350: sortable lists — reactive_sortable (a list whose rows drag to
# reorder, firing a declared action), reactive_sortable_source (a list whose
# rows are dragged in as copies) and reactive_sortable_item (a row and its key).
RSpec.describe Phlex::Reactive::Component::Sortable do
  let(:klass) do
    Class.new(Phlex::HTML) do
      include Phlex::Reactive::Component

      def self.name = "TaskList"

      reactive_state :n
      action :move, params: { item: :integer, position: :integer }
      action :insert, params: { item: :string, after: :integer, from: :string }

      def initialize = @n = 0

      def id = "tasks"

      def view_template
        ul(**mix(reactive_root, reactive_sortable(:move, group: "tasks", handle: "[data-drag-handle]"))) do
          li(id: "task_1", **reactive_sortable_item(1)) { "One" }
        end
      end
    end
  end

  let(:client_only) do
    Class.new(Phlex::HTML) do
      include Phlex::Reactive::ClientBindings

      def self.name = "Templates"

      def view_template
        div(**mix(reactive_root, reactive_sortable_source(group: "tasks", name: "templates"))) do
          button(**reactive_sortable_item("bug")) { "Bug" }
        end
      end
    end
  end

  let(:view) { klass.new }

  def data(attrs) = attrs.fetch(:data)

  # Unit specs run without Rails, so verbose_errors (the render-time action
  # check) is off unless an example turns it on.
  def with_verbose_errors
    Phlex::Reactive.verbose_errors = true
    yield
  ensure
    Phlex::Reactive.remove_instance_variable(:@verbose_errors)
  end

  describe "#reactive_sortable" do
    it "marks the list with its action" do
      expect(data(view.reactive_sortable(:move))).to include(reactive_sortable: "move")
    end

    it "renders the default announcement words, with {position}/{count} placeholders" do
      messages = JSON.parse(data(view.reactive_sortable(:move))[:reactive_sortable_messages])
      expect(messages).to eq(
        "picked" => "Picked up item {position} of {count}",
        "moved" => "Moved to position {position} of {count}",
        "dropped" => "Dropped",
        "cancelled" => "Cancelled"
      )
    end

    it "merges app-supplied words over the defaults (translations)" do
      messages = JSON.parse(data(view.reactive_sortable(:move,
        messages: { dropped: "Abgelegt" }))[:reactive_sortable_messages])
      expect(messages).to include("dropped" => "Abgelegt", "cancelled" => "Cancelled")
    end

    it "emits group, handle, name, a from: map, static params and disabled" do
      attrs = data(view.reactive_sortable(:move, group: :tasks, handle: "[data-drag-handle]", name: "backlog",
        from: { "templates" => :insert }, params: { lane: "todo" },
        disabled: true))
      expect(attrs).to include(
        reactive_sortable_group: "tasks",
        reactive_sortable_handle: "[data-drag-handle]",
        reactive_sortable_name: "backlog",
        reactive_sortable_disabled: "true"
      )
      expect(JSON.parse(attrs[:reactive_sortable_from])).to eq("templates" => "insert")
      expect(JSON.parse(attrs[:reactive_sortable_params])).to eq("lane" => "todo")
    end

    it "omits every optional attribute by default" do
      expect(data(view.reactive_sortable(:move)).keys).to contain_exactly(:reactive_sortable, :reactive_sortable_messages)
    end

    it "takes busy: in on(busy:)'s vocabulary (String shorthand included)" do
      expect(JSON.parse(data(view.reactive_sortable(:move, busy: "Saving…"))[:reactive_sortable_busy]))
        .to eq("disable" => true, "text" => "Saving…")
      expect(JSON.parse(data(view.reactive_sortable(:move, busy: { add_class: "opacity-50" }))[:reactive_sortable_busy]))
        .to eq("add_class" => ["opacity-50"])
    end

    it "raises on an unknown busy: hint" do
      expect { view.reactive_sortable(:move, busy: { wobble: true }) }.to raise_error(ArgumentError, /unknown busy hint/)
    end

    it "raises on a blank action" do
      expect { view.reactive_sortable("") }.to raise_error(ArgumentError, /reactive_sortable needs an action/)
      expect { view.reactive_sortable(nil) }.to raise_error(ArgumentError, /reactive_sortable needs an action/)
    end

    it "raises (verbose_errors) on an undeclared action, listing the declared ones" do
      with_verbose_errors do
        expect { view.reactive_sortable(:mvoe) }.to raise_error(Phlex::Reactive::Error, /no declared action :mvoe/)
      end
    end

    it "raises (verbose_errors) on an undeclared from: action" do
      with_verbose_errors do
        expect { view.reactive_sortable(:move, from: { "templates" => :inzert }) }
          .to raise_error(Phlex::Reactive::Error, /no declared action :inzert/)
      end
    end

    it "raises on a blank or boolean handle:" do
      expect { view.reactive_sortable(:move, handle: " ") }.to raise_error(ArgumentError, /handle: needs a CSS selector/)
      expect { view.reactive_sortable(:move, handle: true) }.to raise_error(ArgumentError, /handle: needs a CSS selector/)
    end

    it "raises on a blank group:" do
      expect { view.reactive_sortable(:move, group: "") }.to raise_error(ArgumentError, /group: needs a name/)
      expect { view.reactive_sortable(:move, group: 1) }.to raise_error(ArgumentError, /group: needs a name/)
    end

    it "raises on a from: that is not a non-empty Hash of list name => action" do
      expect do
        view.reactive_sortable(:move, from: :insert)
      end.to raise_error(ArgumentError, /from: maps a source list's name/)
      expect { view.reactive_sortable(:move, from: {}) }.to raise_error(ArgumentError, /from: maps a source list's name/)
      expect do
        view.reactive_sortable(:move, from: { "" => :insert })
      end.to raise_error(ArgumentError, /from: maps a source list's name/)
    end

    it "raises on a name: that is blank or the reserved \"self\"" do
      expect { view.reactive_sortable(:move, name: "") }.to raise_error(ArgumentError, /name: needs a name/)
      expect { view.reactive_sortable(:move, name: "self") }.to raise_error(ArgumentError, /"self" is reserved/)
    end

    it "raises on params: that is not a Hash, or that names a drop param" do
      expect { view.reactive_sortable(:move, params: [1]) }.to raise_error(ArgumentError, /params: must be a Hash/)
      expect { view.reactive_sortable(:move, params: { position: 3 }) }
        .to raise_error(ArgumentError, /params: cannot set :position/)
    end

    it "raises on messages: that is not a Hash" do
      expect { view.reactive_sortable(:move, messages: "Dropped") }
        .to raise_error(ArgumentError, /messages: must be a Hash/)
    end

    it "raises on a messages: value that is not a String" do
      expect { view.reactive_sortable(:move, messages: { dropped: 1 }) }
        .to raise_error(ArgumentError, /messages: dropped must be a String/)
    end

    it "raises on an unknown messages: key" do
      expect { view.reactive_sortable(:move, messages: { grabbed: "x" }) }
        .to raise_error(ArgumentError, /unknown messages: key :grabbed/)
    end

    it "is refused on a ClientBindings view (a target needs an action, and the action a token)" do
      expect { client_only.new.reactive_sortable(:move) }
        .to raise_error(ArgumentError, /reactive_sortable needs the full Phlex::Reactive::Component/)
    end
  end

  describe "#reactive_sortable_source" do
    it "marks a list whose rows are copied, never moved" do
      expect(data(view.reactive_sortable_source(group: "tasks"))).to eq(
        reactive_sortable_source: "source", reactive_sortable_group: "tasks"
      )
    end

    it "takes a name: (what a target's from: maps and the from param carries)" do
      expect(data(view.reactive_sortable_source(group: "tasks", name: :templates)))
        .to include(reactive_sortable_source: "templates")
    end

    it "works on a ClientBindings view (a source needs no token)" do
      html = client_only.new.call
      expect(html).to include('data-reactive-sortable-source="templates"', 'data-reactive-sortable-group="tasks"')
    end

    it "raises on a blank group: or name:" do
      expect { view.reactive_sortable_source(group: "") }.to raise_error(ArgumentError, /group: needs a name/)
      expect { view.reactive_sortable_source(group: "t", name: " ") }.to raise_error(ArgumentError, /name: needs a name/)
      expect { view.reactive_sortable_source(group: "t", name: "self") }.to raise_error(ArgumentError, /"self" is reserved/)
    end
  end

  describe "#reactive_sortable_item" do
    it "marks a row with its JSON-typed key and makes it focusable" do
      expect(view.reactive_sortable_item(7)).to eq(tabindex: 0, data: { reactive_sortable_item: "7" })
      expect(view.reactive_sortable_item("bug")).to eq(tabindex: 0, data: { reactive_sortable_item: '"bug"' })
    end

    it "takes disabled: — and a disabled row is left out of the tab order" do
      attrs = view.reactive_sortable_item(7, disabled: true)
      expect(data(attrs)).to include(reactive_sortable_disabled: "true")
      expect(attrs).not_to have_key(:tabindex)
    end

    it "raises on a key that is not a String or an Integer, or is blank" do
      expect { view.reactive_sortable_item(nil) }.to raise_error(ArgumentError, /key must be a String or an Integer/)
      expect { view.reactive_sortable_item(1.5) }.to raise_error(ArgumentError, /key must be a String or an Integer/)
      expect { view.reactive_sortable_item(" ") }.to raise_error(ArgumentError, /key must be a String or an Integer/)
    end
  end

  it "renders a whole sortable list through Phlex" do
    html = view.call
    expect(html).to include('data-reactive-sortable="move"', 'data-reactive-sortable-item="1"', 'tabindex="0"')
    expect(html).to include('data-controller="reactive"')
  end
end
