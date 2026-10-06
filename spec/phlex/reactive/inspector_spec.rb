# frozen_string_literal: true

require "rails_helper"

# The Inspector is the ONE read-only introspection layer (issue #168) consumed by
# the rake tasks, the MCP tools, and Doctor. It discovers every constant-backed
# reactive component and, per declared action, its param schema, source location,
# full method-definition source (via Prism), and a heuristic authorization
# status. It reports NAMES/paths/schemas only — never tokens, secrets, or state.
RSpec.describe Phlex::Reactive::Inspector do
  # A real, constant-backed dummy component the whole-app scan must surface.
  # CounterComponent declares many actions (increment, set with params, boom).
  before { Rails.application.eager_load! }

  describe ".components" do
    subject(:components) { described_class.components }

    it "returns ComponentInfo objects" do
      expect(components).to all(be_a(Phlex::Reactive::Inspector::ComponentInfo))
    end

    it "includes a constant-backed dummy component (CounterComponent)" do
      names = components.map(&:name)
      expect(names).to include("CounterComponent")
    end

    it "excludes anonymous classes (name nil)" do
      Class.new(ApplicationComponent) do
        include Phlex::Reactive::Component

        reactive_state :n
        def initialize(n: 0) = (@n = n)
        def id = "anon"
      end

      expect(described_class.components.map(&:klass)).not_to include(
        satisfy { it.name.nil? }
      )
    end

    it "excludes a class whose faked self.name does not resolve to itself" do
      Class.new(ApplicationComponent) do
        include Phlex::Reactive::Component

        # not a real constant
        def self.name = "Phantom::StateWidget"
        reactive_state :n
        action :ghost
        def initialize(n: 0) = (@n = n)
      end

      expect(described_class.components.map(&:name)).not_to include("Phantom::StateWidget")
    end

    # Issue #302: a subclass inherits the mixin instead of including it.
    context "with a subclass of a reactive component" do
      it "lists a constant-backed subclass with its inherited and own actions" do
        info = components.find { it.name == "InheritedSkipComponent" }
        expect(info).not_to be_nil
        expect(info.actions.map(&:name)).to include(:increment, :reset)
        expect(info.actions.map(&:authorization_skip)).to all(eq(:class))
      end

      it "lists a subclass defined after the inventory was first read" do
        described_class.components
        klass = stub_const("Phlex::Reactive::InspectorSpec::LateSubclass", Class.new(PublicCounterComponent))

        expect(described_class.components.map(&:klass)).to include(klass)
      end

      it "excludes an anonymous subclass" do
        anon = Class.new(PublicCounterComponent)
        expect(described_class.components.map(&:klass)).not_to include(anon)
      end
    end

    describe "a ComponentInfo" do
      subject(:info) { described_class.components.find { it.name == "CounterComponent" } }

      it "carries the class, name, source path, and action list" do
        expect(info.klass).to eq(CounterComponent)
        expect(info.name).to eq("CounterComponent")
        expect(info.path).to be_an(Array) # [file, line] from const_source_location
        expect(info.path.first).to end_with("counter_component.rb")
        expect(info.path.last).to be_a(Integer)
        expect(info.actions).to all(be_a(Phlex::Reactive::Inspector::ActionInfo))
      end

      it "reports the state keys for a state-backed component" do
        expect(info.state_keys).to include(:count)
        expect(info.record_key).to be_nil
      end

      it "reports the record key for a record-backed component" do
        todo_info = described_class.components.find { it.name == "TodoItemComponent" }
        expect(todo_info.record_key).to eq(:todo)
      end
    end
  end

  describe "an ActionInfo" do
    subject(:info) { described_class.components.find { it.name == "CounterComponent" } }

    let(:increment) { info.actions.find { it.name == :increment } }
    let(:set_action) { info.actions.find { it.name == :set } }

    it "carries the action name and declared params" do
      expect(increment.name).to eq(:increment)
      expect(increment.params).to eq({})
      expect(set_action.params).to eq({ count: :integer })
    end

    it "locates the method definition via instance_method(name).source_location" do
      expect(increment.source_location).to be_an(Array)
      expect(increment.source_location.first).to end_with("counter_component.rb")
      expect(increment.source_location.last).to be_a(Integer)
    end

    it "extracts the full `def ... end` source with Prism" do
      # `def set(count:) = @count = count` — an endless method def.
      expect(set_action.definition).to include("def set(count:)")
      # `def increment = @count += 1`
      expect(increment.definition).to include("def increment")
    end

    it "has a nil source_location and definition for a declared-but-missing method" do
      klass = Class.new(ApplicationComponent) do
        include Phlex::Reactive::Component

        def self.name = "Phlex::Reactive::InspectorSpec::MissingMethod"
        reactive_state :n
        action :ghost # no `def ghost`
        def initialize(n: 0) = (@n = n)
        def id = "missing"
      end
      stub_const(klass.name, klass)

      info = described_class.components.find { it.klass == klass }
      ghost = info.actions.find { it.name == :ghost }
      expect(ghost.source_location).to be_nil
      expect(ghost.definition).to be_nil
    end

    it "degrades definition to nil (never raises) when the source file is unreadable" do
      # extract_definition is fed the method's real [file, line]; when that file
      # can't be read/parsed it must return nil, never raise. Drive the private
      # helper directly with a nonexistent path — the public path can't easily
      # forge an unreadable source_location for a real in-memory method.
      definition = described_class.send(:extract_definition, ["/no/such/file.rb", 1])
      expect(definition).to be_nil
    end
  end

  describe "authorization heuristic (Prism scan of the method body)" do
    it "flags an action whose body calls a configured authorization method" do
      klass = Class.new(ApplicationComponent) do
        include Phlex::Reactive::Component

        def self.name = "Phlex::Reactive::InspectorSpec::Authorized"
        reactive_record :todo
        action :rename, params: { title: :string }
        def initialize(todo:) = (@todo = todo)

        def rename(title:)
          authorize! @todo, :update?
          @todo.update!(title:)
        end
      end
      stub_const(klass.name, klass)

      info = described_class.components.find { it.klass == klass }
      rename = info.actions.find { it.name == :rename }
      expect(rename.authorization_call_detected?).to be(true)
    end

    it "does not flag an action with no authorization call" do
      klass = Class.new(ApplicationComponent) do
        include Phlex::Reactive::Component

        def self.name = "Phlex::Reactive::InspectorSpec::Unauthorized"
        reactive_state :n
        action :bump
        def initialize(n: 0) = (@n = n)
        def id = "unauth"
        def bump = @n += 1
      end
      stub_const(klass.name, klass)

      info = described_class.components.find { it.klass == klass }
      bump = info.actions.find { it.name == :bump }
      expect(bump.authorization_call_detected?).to be(false)
    end

    it "flags mark_authorized! as an authorization call" do
      klass = Class.new(ApplicationComponent) do
        include Phlex::Reactive::Component

        def self.name = "Phlex::Reactive::InspectorSpec::MarkAuthorized"
        reactive_state :n
        action :bump
        def initialize(n: 0) = (@n = n)
        def id = "mark"

        def bump
          mark_authorized!
          @n += 1
        end
      end
      stub_const(klass.name, klass)

      info = described_class.components.find { it.klass == klass }
      bump = info.actions.find { it.name == :bump }
      expect(bump.authorization_call_detected?).to be(true)
    end

    # A misconfigured Phlex::Reactive.authorization_methods (nil, or a single
    # symbol) must not raise inside authorization_method_names — the caller's
    # rescue would swallow it and silently report "no authorization" everywhere.
    # Array() coerces both, falling back to the default set on nil.
    describe "resilience to a misconfigured authorization_methods" do
      it "falls back to the default set when authorization_methods is nil" do
        allow(Phlex::Reactive).to receive(:respond_to?).and_call_original
        allow(Phlex::Reactive).to receive(:respond_to?).with(:authorization_methods).and_return(true)
        allow(Phlex::Reactive).to receive(:authorization_methods).and_return(nil)

        names = described_class.authorization_method_names
        expect(names).to include(:authorize!, :mark_authorized!)
      end

      it "coerces a single-symbol authorization_methods without raising" do
        allow(Phlex::Reactive).to receive(:respond_to?).and_call_original
        allow(Phlex::Reactive).to receive(:respond_to?).with(:authorization_methods).and_return(true)
        allow(Phlex::Reactive).to receive(:authorization_methods).and_return(:can?)

        expect { described_class.authorization_method_names }.not_to raise_error
        expect(described_class.authorization_method_names).to include(:can?, :mark_authorized!)
      end
    end
  end

  # Issue #278: the inventory tells a deliberate opt-out from a forgotten check.
  # authorization_state is :detected (a call was found), :skipped (declared with
  # skip_verify_authorized) or :none; authorization_skip says which form.
  describe "authorization state (detected / skipped / none)" do
    # component_info directly: it reads one class's authorization state without
    # going through the whole-registry scan.
    def action_for(klass, name)
      described_class.send(:component_info, klass).actions.find { it.name == name }
    end

    it "is :detected for an action that calls an authorization method" do
      action = action_for(AuthorizedTodoComponent, :rename)
      expect(action.authorization_state).to eq(:detected)
      expect(action.authorization_skip).to be_nil
    end

    it "is :skipped with skip :action for an action named in skip_verify_authorized" do
      action = action_for(AuthorizedTodoComponent, :rename_skipped)
      expect(action.authorization_state).to eq(:skipped)
      expect(action.authorization_skip).to eq(:action)
    end

    it "is :none for an action with neither a call nor a skip" do
      action = action_for(AuthorizedTodoComponent, :rename_unguarded)
      expect(action.authorization_state).to eq(:none)
      expect(action.authorization_skip).to be_nil
    end

    it "is :skipped with skip :class for every action under a bare skip_verify_authorized" do
      action = action_for(PublicCounterComponent, :increment)
      expect(action.authorization_state).to eq(:skipped)
      expect(action.authorization_skip).to eq(:class)
    end

    it "is :detected when a skipped action also calls an authorization method, keeping the skip form" do
      klass = Class.new(AuthorizedTodoComponent) do
        def self.name = "Phlex::Reactive::InspectorSpec::SkippedButAuthorized"
        skip_verify_authorized :rename
      end
      stub_const(klass.name, klass)

      action = action_for(klass, :rename)
      expect(action.authorization_state).to eq(:detected)
      expect(action.authorization_skip).to eq(:action)
    end

    it "inherits a superclass's bare skip as :class" do
      klass = Class.new(PublicCounterComponent) do
        def self.name = "Phlex::Reactive::InspectorSpec::InheritsSkip"
        action :decrement
        def decrement = @count -= 1
      end
      stub_const(klass.name, klass)

      expect(action_for(klass, :decrement).authorization_skip).to eq(:class)
    end

    it "inherits a superclass's per-action skip as :action" do
      klass = Class.new(AuthorizedTodoComponent) do
        def self.name = "Phlex::Reactive::InspectorSpec::InheritsActionSkip"
      end
      stub_const(klass.name, klass)

      expect(action_for(klass, :rename_skipped).authorization_skip).to eq(:action)
      expect(action_for(klass, :rename_unguarded).authorization_skip).to be_nil
    end
  end

  describe ".find (fuzzy match)" do
    it "returns an empty array when nothing matches" do
      expect(described_class.find("zzz_no_such_component_zzz")).to eq([])
    end

    it "finds a component by its demodulized name (case-insensitive)" do
      results = described_class.find("counter")
      expect(results.map(&:name)).to include("CounterComponent")
    end

    it "ranks an exact demodulized match above a mere substring match" do
      # "CounterComponent" (contains "counter") should outrank a component that
      # only contains the query as a subsequence.
      results = described_class.find("CounterComponent")
      expect(results.first.name).to eq("CounterComponent")
    end

    it "ranks a prefix match above a scattered subsequence match" do
      # Query "coun" is a prefix of CounterComponent — it should be the top hit
      # over any component that only contains c…o…u…n scattered.
      results = described_class.find("coun")
      expect(results.first.name).to eq("CounterComponent")
    end

    it "matches on the full namespaced name too" do
      results = described_class.find("TodoItem")
      expect(results.map(&:name)).to include("TodoItemComponent")
    end
  end
end
