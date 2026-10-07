# frozen_string_literal: true

require "spec_helper"
require "phlex" # for the render-context-free `mix` helper used by reactive_root (issue #48)

RSpec.describe Phlex::Reactive::Component do
  # A minimal state-backed component (no Rails/Phlex render needed for these).
  # It declares every action the #on specs exercise: on() now consults the
  # actions registry under verbose_errors (issue #105 — undeclared names raise at
  # render), which is ON whenever Rails is loaded (the combined fast suite), so a
  # trigger for an undeclared name would raise here. Declaring them keeps every
  # #on wire-format example green regardless of the flag's default.
  let(:state_klass) do
    Class.new do
      include Phlex::Reactive::Component

      def self.name = "StateThing"

      reactive_state :count
      action :increment
      action :set, params: { count: :integer }
      # Action names the #on option specs (debounce/listnav/confirm/keyboard/
      # modifiers/optimistic/loading) build triggers for — declared so the
      # render-time undeclared-action guard (issue #105) passes them through.
      %i[search destroy add cancel switch toggle track dismiss close_menu save].each { action(it) }

      def initialize(count: 0) = @count = count
      attr_reader :count

      def increment = @count += 1
      def set(count:) = @count = count
    end
  end

  describe "action declarations (default-deny)" do
    it "registers declared actions" do
      expect(state_klass.reactive_actions.key?(:increment)).to be(true)
      expect(state_klass.reactive_actions[:set].params).to eq({ count: :integer })
    end

    it "does not register undeclared methods" do
      expect(state_klass.reactive_actions.key?(:wat)).to be(false)
      expect(state_klass.reactive_actions[:wat]).to be_nil
    end

    it "compiles the param schema at declaration (issue #109)" do
      expect(state_klass.reactive_actions[:set].schema).to be_a(Phlex::Reactive::ParamSchema)
    end

    it "raises UnknownParamType at CLASS LOAD for a typo'd type symbol (issue #109)" do
      expect do
        Class.new do
          include Phlex::Reactive::Component

          action :set, params: { count: :interger }
        end
      end.to raise_error(Phlex::Reactive::UnknownParamType, /interger/)
    end
  end

  describe "state-backed identity" do
    it "signs state into a verifiable token and rebuilds it" do
      token = state_klass.new(count: 5).send(:reactive_token)
      payload = Phlex::Reactive.verify(token)

      expect(payload["c"]).to eq("StateThing")
      expect(payload["s"]).to eq({ "count" => 5 })

      rebuilt = state_klass.from_identity(payload)
      expect(rebuilt.count).to eq(5)
    end

    it "round-trips a mutation through rebuild + action" do
      token = state_klass.new(count: 1).send(:reactive_token)
      rebuilt = state_klass.from_identity(Phlex::Reactive.verify(token))
      rebuilt.increment
      expect(rebuilt.count).to eq(2)
    end

    it "ignores the token version key (#111) — the leftover \"v\" is harmless" do
      # verify leaves "v" in the payload; from_identity assembles kwargs only from
      # the declared record/state keys, so the version marker never reaches new(**).
      payload = Phlex::Reactive.verify(state_klass.new(count: 9).send(:reactive_token))
      expect(payload).to have_key("v")

      rebuilt = state_klass.from_identity(payload)
      expect(rebuilt.count).to eq(9) # rebuilt cleanly despite the extra "v"
    end
  end

  describe "record + state identity (issue #6)" do
    # A record-backed component that ALSO carries transient state (which field,
    # what mode) — exactly the documented inline_edit pattern. Before the fix,
    # the state branch was dead whenever a record was present: `attribute`/
    # `editing` were never signed and never restored, so the mode reset to its
    # initialize default on every action.
    let(:record_state_klass) do
      Class.new do
        include Phlex::Reactive::Streamable
        include Phlex::Reactive::Component

        def self.name = "InlineThing"

        reactive_record :record
        reactive_state :attribute, :editing

        def initialize(record:, attribute:, editing: false)
          @record = record
          @attribute = attribute.to_sym
          @editing = editing
        end

        attr_reader :record, :attribute, :editing

        def id = "inline-#{@record.object_id}"
      end
    end

    # A stand-in record that round-trips through GlobalID without a DB.
    let(:record) { Struct.new(:gid_string).new("gid://app/Article/1") }

    before do
      allow(record).to receive(:to_gid).and_return(
        instance_double(GlobalID, to_s: record.gid_string)
      )
      allow(GlobalID::Locator).to receive(:locate).with(record.gid_string).and_return(record)
    end

    it "signs BOTH the record gid and the declared state into one token" do
      component = record_state_klass.new(record:, attribute: :name, editing: true)
      payload = Phlex::Reactive.verify(component.send(:reactive_token))

      expect(payload["c"]).to eq("InlineThing")
      expect(payload["gid"]).to eq(record.gid_string)
      expect(payload["s"]).to eq({ "attribute" => "name", "editing" => true })
    end

    it "restores the record AND the state on rebuild (round trip)" do
      token = record_state_klass.new(record:, attribute: :name, editing: true).send(:reactive_token)
      rebuilt = record_state_klass.from_identity(Phlex::Reactive.verify(token))

      expect(rebuilt.record).to be(record)
      expect(rebuilt.attribute).to eq(:name) # not nil — survives the round trip
      expect(rebuilt.editing).to be(true)    # not the initialize default (false)
    end

    it "preserves a false state value rather than dropping to the default" do
      token = record_state_klass.new(record:, attribute: :name, editing: false).send(:reactive_token)
      rebuilt = record_state_klass.from_identity(Phlex::Reactive.verify(token))

      expect(rebuilt.editing).to be(false)
    end

    it "round-trips a signed nil distinctly from an absent key" do
      # A nullable state key: its initialize default is a non-nil sentinel, so a
      # signed `nil` must override it (key presence, not value, decides restore).
      nullable_klass = Class.new do
        include Phlex::Reactive::Streamable
        include Phlex::Reactive::Component

        def self.name = "NullableThing"

        reactive_record :record
        reactive_state :filter

        def initialize(record:, filter: :unset)
          @record = record
          @filter = filter
        end

        attr_reader :filter

        def id = "nullable-#{@record.object_id}"
      end

      token = nullable_klass.new(record:, filter: nil).send(:reactive_token)
      rebuilt = nullable_klass.from_identity(Phlex::Reactive.verify(token))

      expect(rebuilt.filter).to be_nil # the signed nil wins, not the :unset default
    end

    it "the state cannot be tampered without breaking the signature" do
      token = record_state_klass.new(record:, attribute: :name, editing: false).send(:reactive_token)
      # Mutate the signed DATA segment (left of the `--`) while keeping the
      # ORIGINAL signature — the HMAC over the data no longer matches, so verify
      # fails. Flipping a byte in the encoded payload is serializer-agnostic: it
      # works whether the verifier Marshals (the plain MessageVerifier in
      # spec_helper) or JSON-serializes (the app verifier under rails_helper),
      # unlike decoding+re-encoding a known payload shape.
      data, sig = token.split("--", 2)
      mutated = data.dup
      i = data.length / 2
      mutated[i] = (data[i] == "A" ? "B" : "A")
      forged = "#{mutated}--#{sig}"

      expect(forged).not_to eq(token) # sanity: we actually changed the data
      expect(Phlex::Reactive.verify(forged)).to be_nil
    end
  end

  describe "model_param_name unification (issue #4)" do
    # A record-backed component whose demodulized class name (`bar`) differs
    # from its reactive_record name (`baz`). The action endpoint builds it with
    # `reactive_record_key` (:baz); the broadcast path builds it via
    # `model_param_name`. Both MUST agree, or one path raises
    # `ArgumentError: missing keyword`.
    let(:record_klass) do
      Class.new do
        include Phlex::Reactive::Streamable
        include Phlex::Reactive::Component

        def self.name = "Foo::Bar"

        reactive_record :baz

        def initialize(baz:) = @baz = baz
        attr_reader :baz

        def id = "foo-bar-#{@baz.object_id}"
      end
    end

    it "broadcasts and clicks build with the same init keyword" do
      expect(record_klass.model_param_name).to eq(:baz)
    end

    it "build(model) constructs with reactive_record_key, not the class name" do
      record = Object.new
      built = record_klass.send(:build, record, {})
      expect(built.baz).to be(record)
    end

    it "falls back to the demodulized class name when no reactive_record is set" do
      state_backed = Class.new do
        include Phlex::Reactive::Streamable
        include Phlex::Reactive::Component

        def self.name = "Foo::Widget"

        reactive_state :count
        def initialize(count: 0) = @count = count
      end

      expect(state_backed.model_param_name).to eq(:widget)
    end

    it "falls back to the demodulized class name for Streamable-only components" do
      streamable_only = Class.new do
        include Phlex::Reactive::Streamable

        def self.name = "Foo::Row"

        def initialize(row:) = @row = row
      end

      expect(streamable_only.model_param_name).to eq(:row)
    end

    it "honors an explicit model_param_name override" do
      overridden = Class.new do
        include Phlex::Reactive::Streamable
        include Phlex::Reactive::Component

        def self.name = "Foo::Bar"
        def self.model_param_name = :explicit

        reactive_record :baz

        def initialize(explicit:) = @explicit = explicit
      end

      expect(overridden.model_param_name).to eq(:explicit)
    end
  end

  describe "inheritance" do
    it "inherits actions and state keys from a parent" do
      child = Class.new(state_klass) do
        def self.name = "ChildThing"
        action :decrement
        def decrement = @count -= 1
      end

      expect(child.reactive_actions.key?(:increment)).to be(true) # inherited
      expect(child.reactive_actions.key?(:decrement)).to be(true) # own
      expect(child.reactive_state_keys).to include(:count)
      # parent unaffected
      expect(state_klass.reactive_actions.key?(:decrement)).to be(false)
    end
  end

  describe "#reactive_field param binding (issue #23)" do
    subject(:instance) { state_klass.new }

    it "binds the field name to the action param (drops the magic name: string)" do
      attrs = instance.send(:reactive_field, :count)
      expect(attrs[:name]).to eq("count")
    end

    it "merges extra attributes over the bound name" do
      attrs = instance.send(:reactive_field, :count, value: 7, data: { testid: "f" })
      expect(attrs[:name]).to eq("count")
      expect(attrs[:value]).to eq(7)
      expect(attrs[:data]).to eq({ testid: "f" })
    end

    it "lets an explicit name: override the param binding (escape hatch)" do
      attrs = instance.send(:reactive_field, :count, name: "other")
      expect(attrs[:name]).to eq("other")
    end
  end

  # Issue #184: under reactive_scope, reactive_field emits the SCOPED wire name
  # (name="invoice[date]"), so the POST arrives bracketed and the endpoint unwraps
  # one level to match a flat schema. This also aligns the field with the client
  # show/compute resolvers, which already query [name="scope[x]"].
  describe "#reactive_field under reactive_scope (issue #184)" do
    subject(:instance) { scoped_klass.new }

    let(:scoped_klass) do
      Class.new(Phlex::HTML) do
        include Phlex::Reactive::Streamable
        include Phlex::Reactive::Component

        def self.name = "ScopedFieldThing"

        reactive_state :count
        reactive_scope :invoice
        def initialize(count: 0) = @count = count
        def id = "scoped"
      end
    end

    it "emits the scope-prefixed wire name for a bare param" do
      attrs = instance.send(:reactive_field, :date)
      expect(attrs[:name]).to eq("invoice[date]")
    end

    it "does NOT double-scope an explicit name: that already carries a bracket" do
      attrs = instance.send(:reactive_field, :date, name: "other[thing]")
      expect(attrs[:name]).to eq("other[thing]")
    end

    it "keeps an unscoped component's field name bare (additive)" do
      unscoped = Class.new(Phlex::HTML) do
        include Phlex::Reactive::Streamable
        include Phlex::Reactive::Component

        def self.name = "UnscopedFieldThing"
        reactive_state :count
        def initialize(count: 0) = @count = count
        def id = "unscoped"
      end
      expect(unscoped.new.send(:reactive_field, :date)[:name]).to eq("date")
    end
  end

  # Issue #184: per-field dirty tracking is declared class-level via
  # `reactive_dirty only: %i[...]`; a named field then carries the trackDirty
  # descriptor. (The old reactive_field(dirty:) kwarg is removed — see the guided
  # error block below.)
  describe "#reactive_field dirty tracking via reactive_dirty only: (issue #184)" do
    subject(:instance) { field_klass.new }

    let(:field_klass) do
      Class.new(Phlex::HTML) do
        include Phlex::Reactive::Streamable
        include Phlex::Reactive::Component

        def self.name = "DirtyOnlyFieldThing"

        reactive_state :count
        reactive_dirty only: %i[title]
        def initialize(count: 0) = @count = count
      end
    end

    it "wires the trackDirty action on a field named in only:" do
      attrs = instance.send(:reactive_field, :title)
      expect(attrs[:name]).to eq("title")
      expect(attrs[:data][:action]).to eq("input->reactive#trackDirty")
    end

    it "omits the trackDirty wiring on a field NOT in only:" do
      expect(instance.send(:reactive_field, :body)).not_to have_key(:data)
    end

    it "token-joins trackDirty onto a caller's own data-action instead of clobbering it" do
      attrs = instance.send(:reactive_field, :title, data: { action: "blur->reactive#dispatch" })
      expect(attrs[:data][:action]).to eq("blur->reactive#dispatch input->reactive#trackDirty")
    end
  end

  describe "#reactive_root (issue #48 — id on the root, not a child)" do
    subject(:instance) { root_klass.new }

    # A real Phlex component (so the render-context-free `mix` helper is present,
    # exactly as in production) with a custom #id. reactive_root must emit that id
    # ON the reactive-controller element, so this.element.id can never be empty and
    # #extractToken's first-token-wins fallback is unreachable.
    let(:root_klass) do
      Class.new(Phlex::HTML) do
        include Phlex::Reactive::Streamable
        include Phlex::Reactive::Component

        def self.name = "RootThing"

        reactive_state :count
        def initialize(count: 0) = @count = count

        def id = "root-thing"
      end
    end

    it "spreads the component id ALONGSIDE reactive_attrs on one element" do
      attrs = instance.send(:reactive_root)
      expect(attrs[:id]).to eq("root-thing")
      expect(attrs[:data][:controller]).to eq("reactive")
      expect(attrs[:data][:reactive_token_value]).to be_a(String)
    end

    it "carries the SAME token reactive_attrs would (no second signing path)" do
      attrs = instance.send(:reactive_root)
      payload = Phlex::Reactive.verify(attrs[:data][:reactive_token_value])
      expect(payload["c"]).to eq("RootThing")
    end

    it "deep-merges overrides without clobbering the controller/token data:" do
      attrs = instance.send(:reactive_root, class: "card", data: { testid: "root" })
      expect(attrs[:class]).to eq("card")
      # the override's data: must NOT wipe out controller/reactive_token_value
      expect(attrs[:data][:controller]).to eq("reactive")
      expect(attrs[:data][:reactive_token_value]).to be_a(String)
      expect(attrs[:data][:testid]).to eq("root")
    end

    it "lets an explicit id: override win (escape hatch)" do
      attrs = instance.send(:reactive_root, id: "explicit")
      expect(attrs[:id]).to eq("explicit")
    end

    it "renders id and data-controller onto the SAME element (the whole point)" do
      render_klass = Class.new(root_klass) do
        def self.name = "RenderRootThing"
        def view_template = div(**reactive_root(class: "card")) { "hi" }
      end
      html = render_klass.new.call

      # the SAME opening tag carries BOTH the id and the controller — never split
      # across elements (the issue #48 footgun is `id:` on a child). Match the one
      # <div …> tag, then assert both attributes live inside it (order-independent).
      open_tag = html[/<div [^>]*>/]
      expect(open_tag).to include('id="root-thing"')
      expect(open_tag).to include('data-controller="reactive"')
      expect(open_tag).to include('class="card"')
    end
  end

  # Issue #184: ONE dirty-tracking declaration — reactive_dirty (class-level)
  # replaces reactive_root(track_dirty:, warn_unsaved:) + reactive_field(dirty:).
  # The EMITTED DOM is unchanged (zero client change): reactive_root reads the
  # class config and emits the SAME trackDirty descriptor + warn-unsaved marker.
  describe "#reactive_dirty (issue #184)" do
    subject(:instance) { dirty_klass.new }

    let(:dirty_klass) do
      Class.new(Phlex::HTML) do
        include Phlex::Reactive::Streamable
        include Phlex::Reactive::Component

        def self.name = "DirtyMacroThing"

        reactive_state :count
        reactive_dirty warn_unsaved: true
        def initialize(count: 0) = @count = count

        def id = "dirty-root"
      end
    end

    it "mixes the trackDirty descriptor onto the root's data-action" do
      attrs = instance.send(:reactive_root)
      expect(attrs[:data][:action]).to eq("input->reactive#trackDirty")
      expect(attrs[:data][:controller]).to eq("reactive")
      expect(attrs[:id]).to eq("dirty-root")
    end

    it "emits the warn-unsaved marker (STRING true) from warn_unsaved: true" do
      attrs = instance.send(:reactive_root)
      expect(attrs[:data][:reactive_warn_unsaved]).to eq("true")
    end

    it "tracks WITHOUT warn_unsaved when only reactive_dirty (no flag) is declared" do
      klass = Class.new(Phlex::HTML) do
        include Phlex::Reactive::Streamable
        include Phlex::Reactive::Component

        def self.name = "DirtyNoWarn"
        reactive_state :count
        reactive_dirty
        def initialize(count: 0) = @count = count
        def id = "dn"
      end
      attrs = klass.new.send(:reactive_root)
      expect(attrs[:data][:action]).to eq("input->reactive#trackDirty")
      expect(attrs[:data]).not_to have_key(:reactive_warn_unsaved)
    end

    it "emits NO dirty wiring for a component that does not declare reactive_dirty" do
      klass = Class.new(Phlex::HTML) do
        include Phlex::Reactive::Streamable
        include Phlex::Reactive::Component

        def self.name = "NoDirty"
        reactive_state :count
        def initialize(count: 0) = @count = count
        def id = "nd"
      end
      attrs = klass.new.send(:reactive_root)
      expect(attrs[:data][:action]).to be_nil
      expect(attrs[:data]).not_to have_key(:reactive_warn_unsaved)
    end

    it "wires the field-level trackDirty descriptor on a field in only:" do
      klass = Class.new(Phlex::HTML) do
        include Phlex::Reactive::Streamable
        include Phlex::Reactive::Component

        def self.name = "DirtyOnly"
        reactive_state :count
        reactive_dirty only: %i[title]
        def initialize(count: 0) = @count = count
      end
      attrs = klass.new.send(:reactive_field, :title)
      expect(attrs[:data][:action]).to eq("input->reactive#trackDirty")
    end

    it "does NOT wire a field OUTSIDE only:" do
      klass = Class.new(Phlex::HTML) do
        include Phlex::Reactive::Streamable
        include Phlex::Reactive::Component

        def self.name = "DirtyOnlyOther"
        reactive_state :count
        reactive_dirty only: %i[title]
        def initialize(count: 0) = @count = count
      end
      attrs = klass.new.send(:reactive_field, :body)
      expect(attrs[:data]).to be_nil
    end
  end

  # Issue #184: reactive_input/reactive_select collapse into reactive_field (one
  # binding helper; the element is the caller's). The stubs raise a guided error.
  describe "removed reactive_input/reactive_select (issue #184 — guided errors)" do
    subject(:instance) { state_klass.new }

    it "raises for reactive_input naming reactive_field" do
      expect { instance.send(:reactive_input, :value) }
        .to raise_error(ArgumentError, /reactive_field/)
    end

    it "raises for reactive_select naming reactive_field" do
      expect { instance.send(:reactive_select, :status) }
        .to raise_error(ArgumentError, /reactive_field/)
    end
  end

  # Issue #184: the old dirty kwargs are removed → guided errors printing the
  # reactive_dirty line.
  describe "removed dirty kwargs (issue #184 — guided errors)" do
    subject(:instance) { state_klass.new }

    it "raises for reactive_root(track_dirty:)" do
      expect { instance.send(:reactive_root, track_dirty: true) }
        .to raise_error(ArgumentError, /reactive_dirty/)
    end

    it "raises for reactive_root(warn_unsaved:)" do
      expect { instance.send(:reactive_root, warn_unsaved: true) }
        .to raise_error(ArgumentError, /reactive_dirty/)
    end

    it "raises for reactive_field(dirty:)" do
      expect { instance.send(:reactive_field, :title, dirty: true) }
        .to raise_error(ArgumentError, /reactive_dirty/)
    end
  end

  # Issue #183: reactive_root(compute: :name) binds the compute AT THE ROOT — the
  # root carries the data-reactive-compute-* descriptors AND the recompute
  # delegation, so fields need ZERO per-field input->reactive#recompute wiring.
  # A nil compute: emits no binding (the conditional-binding collapse).
  describe "#reactive_root compute binding (issue #183)" do
    subject(:instance) { compute_root_klass.new }

    let(:compute_root_klass) do
      Class.new(Phlex::HTML) do
        include Phlex::Reactive::Streamable
        include Phlex::Reactive::Component

        def self.name = "ComputeRootThing"

        reactive_state :total, :allowance
        reactive_compute :split, inputs: %i[allowance total], outputs: %i[allowance]
        def initialize(total: 0, allowance: 0)
          @total = total
          @allowance = allowance
        end

        def id = "compute-root"
      end
    end

    it "emits the compute descriptors at the root for compute: :name" do
      attrs = instance.send(:reactive_root, compute: :split)
      expect(attrs[:data][:reactive_compute_reducer_param]).to eq("split")
      expect(JSON.parse(attrs[:data][:reactive_compute_inputs_param])).to eq(%w[allowance total])
      expect(JSON.parse(attrs[:data][:reactive_compute_outputs_param])).to eq(%w[allowance])
    end

    it "delegates the input event to recompute at the root" do
      attrs = instance.send(:reactive_root, compute: :split)
      expect(attrs[:data][:action]).to include("input->reactive#recompute")
    end

    # Issue #199: the root carries a seed marker so the client self-seeds the
    # derived fields on connect (a fresh render computes them WITHOUT waiting for
    # the first user input, and with no synthetic seed `input` to race).
    it "emits the connect-time seed marker for a compute binding" do
      attrs = instance.send(:reactive_root, compute: :split)
      expect(attrs[:data][:reactive_compute_seed]).to eq("true")
    end

    it "emits NO seed marker when there is no compute binding" do
      attrs = instance.send(:reactive_root, compute: nil)
      expect(attrs[:data]).not_to have_key(:reactive_compute_seed)
    end

    it "keeps the full reactive root (id + controller + token)" do
      attrs = instance.send(:reactive_root, compute: :split)
      expect(attrs[:data][:controller]).to eq("reactive")
      expect(attrs[:id]).to eq("compute-root")
      expect(attrs[:data][:reactive_token_value]).to be_a(String)
    end

    it "emits NO compute binding for compute: nil (conditional collapse)" do
      attrs = instance.send(:reactive_root, compute: nil)
      expect(attrs[:data]).not_to have_key(:reactive_compute_reducer_param)
      # Unconditional: a recompute delegation leaking onto a compute-nil root is
      # exactly the regression to catch, so never guard it away.
      expect(attrs[:data][:action].to_s).not_to include("recompute")
      expect(attrs).not_to have_key(:compute)
    end

    it "does NOT emit compute: as a literal HTML attribute (kwarg consumed pre-mix)" do
      attrs = instance.send(:reactive_root, compute: :split)
      expect(attrs).not_to have_key(:compute)
    end

    it "composes the recompute descriptor with a caller's own data-action (token-join)" do
      attrs = instance.send(:reactive_root, compute: :split, data: { action: "scroll->reactive#dispatch" })
      expect(attrs[:data][:action]).to include("scroll->reactive#dispatch")
      expect(attrs[:data][:action]).to include("input->reactive#recompute")
    end

    it "raises for an undeclared compute name" do
      expect { instance.send(:reactive_root, compute: :nope) }
        .to raise_error(Phlex::Reactive::Error, /reactive_compute/)
    end
  end

  # Issue #183: reactive_compute_attrs is removed as a public helper — the compute
  # binding lives on reactive_root(compute:). It raises a guided error naming it.
  describe "#reactive_compute_attrs removed (issue #183)" do
    subject(:instance) { compute_root_klass.new }

    let(:compute_root_klass) do
      Class.new(Phlex::HTML) do
        include Phlex::Reactive::Streamable
        include Phlex::Reactive::Component

        def self.name = "ComputeAttrsGone"
        reactive_compute :split, inputs: %i[a], outputs: %i[a]
        def id = "gone"
      end
    end

    it "raises a guided error naming reactive_root(compute:)" do
      expect { instance.send(:reactive_compute_attrs, :split) }
        .to raise_error(ArgumentError, /reactive_root\(compute:/)
    end
  end

  describe "#reactive_attrs debug flag (issue #108)" do
    subject(:instance) { state_klass.new }

    # This unit spec runs WITHOUT Rails, so debug defaults to false. Each example
    # sets it explicitly; restore the lazy default after each by removing the ivar
    # entirely so an explicit value never leaks into the next (the verbose_errors
    # precedent below).
    around do
      it.run
    ensure
      Phlex::Reactive.remove_instance_variable(:@debug) if Phlex::Reactive.instance_variable_defined?(:@debug)
    end

    it "omits data-reactive-debug when debug is off (the default)" do
      Phlex::Reactive.debug = false
      expect(instance.send(:reactive_attrs)[:data]).not_to have_key(:reactive_debug)
    end

    it "emits data-reactive-debug=\"true\" (STRING) when debug is on" do
      Phlex::Reactive.debug = true
      # STRING "true", not boolean: Phlex renders a boolean-true attr VALUELESS,
      # which the client's getAttribute reads as "" → falsy (the on()/warn_unsaved
      # precedent). The explicit ="true" is what the controller matches on.
      expect(instance.send(:reactive_attrs)[:data][:reactive_debug]).to eq("true")
    end

    it "flows the flag through reactive_root too" do
      Phlex::Reactive.debug = true
      attrs = instance.send(:reactive_attrs)
      expect(attrs[:data][:reactive_debug]).to eq("true")
      # still a full reactive root's attrs
      expect(attrs[:data][:controller]).to eq("reactive")
    end

    it "defaults debug to false with no Rails env" do
      Phlex::Reactive.remove_instance_variable(:@debug) if Phlex::Reactive.instance_variable_defined?(:@debug)
      expect(Phlex::Reactive.debug).to be(false)
    end
  end

  # Issue #237: verbose_errors reaches the CLIENT as data-reactive-verbose so the
  # runtime can warn (dev/test only) when a client op resolves zero targets. Same
  # string-"true" convention as the debug stamp above, same ivar-removal restore.
  describe "#reactive_attrs verbose flag (issue #237)" do
    subject(:instance) { state_klass.new }

    around do
      it.run
    ensure
      if Phlex::Reactive.instance_variable_defined?(:@verbose_errors)
        Phlex::Reactive.remove_instance_variable(:@verbose_errors)
      end
    end

    it "omits data-reactive-verbose when verbose_errors is off" do
      Phlex::Reactive.verbose_errors = false
      expect(instance.send(:reactive_attrs)[:data]).not_to have_key(:reactive_verbose)
    end

    it "emits data-reactive-verbose=\"true\" (STRING) when verbose_errors is on" do
      Phlex::Reactive.verbose_errors = true
      expect(instance.send(:reactive_attrs)[:data][:reactive_verbose]).to eq("true")
    end

    it "stamps independently of debug (verbose on, debug off)" do
      Phlex::Reactive.verbose_errors = true
      attrs = instance.send(:reactive_attrs)
      expect(attrs[:data][:reactive_verbose]).to eq("true")
      expect(attrs[:data]).not_to have_key(:reactive_debug)
    end
  end

  describe "#on trigger attributes (issue #17 debounce)" do
    subject(:instance) { state_klass.new }

    it "wires the action + event without a debounce by default" do
      attrs = instance.send(:on, :increment, event: "input")
      expect(attrs[:data][:action]).to eq("input->reactive#dispatch")
      expect(attrs[:data][:reactive_action_param]).to eq("increment")
      expect(attrs[:data]).not_to have_key(:reactive_debounce_param)
    end

    it "emits the debounce as a Stimulus param when given" do
      attrs = instance.send(:on, :set, event: "input", debounce: 300)
      expect(attrs[:data][:reactive_debounce_param]).to eq(300)
    end

    it "keeps debounce out of the explicit params payload" do
      attrs = instance.send(:on, :set, event: "input", debounce: 300, count: 5)
      expect(JSON.parse(attrs[:data][:reactive_params_param])).to eq({ "count" => 5 })
    end

    # Performance: the no-params case (the common on(:increment)) must NOT
    # re-serialize an empty hash to JSON on every render — but the wire format
    # must stay exactly "{}" so the client's #parseParams is unaffected.
    it "emits an empty-object params payload (verbatim) with no explicit params" do
      attrs = instance.send(:on, :increment)
      expect(attrs[:data][:reactive_params_param]).to eq("{}")
    end

    it "still serializes explicit params" do
      attrs = instance.send(:on, :set, count: 9)
      expect(JSON.parse(attrs[:data][:reactive_params_param])).to eq({ "count" => 9 })
    end
  end

  # Issue #105: on(:typo) — an undeclared action name (a typo, or an action you
  # forgot to declare) renders fine today and only surfaces as an unexplained
  # 403 at CLICK time (the endpoint's default-deny). With verbose_errors on
  # (dev + test), on() consults the actions registry and raises at RENDER time,
  # listing the declared actions — the same loud-failure precedent as
  # reactive_compute_attrs. Production (flag off) keeps today's permissive emit
  # so a stale page after a deploy that removed an action doesn't 500 on render.
  describe "#on undeclared-action guard (issue #105)" do
    subject(:instance) { state_klass.new }

    # This unit spec runs WITHOUT Rails (spec_helper), so verbose_errors defaults
    # to false — the raising path is flag-gated, so force it ON here (in a Rails
    # app it defaults ON in dev + test via Rails.env.local?). Restore the lazy
    # default after each example — remove the ivar entirely so the explicit value
    # never leaks into the next one.
    around do
      Phlex::Reactive.verbose_errors = true
      it.run
    ensure
      if Phlex::Reactive.instance_variable_defined?(:@verbose_errors)
        Phlex::Reactive.remove_instance_variable(:@verbose_errors)
      end
    end

    it "passes through for a declared action" do
      expect { instance.send(:on, :increment) }.not_to raise_error
      expect(instance.send(:on, :increment)[:data][:reactive_action_param]).to eq("increment")
    end

    it "raises for an undeclared action (a typo), naming it and listing the declared ones" do
      # (An anonymous test class stringifies as #<Class:0x…>, not its .name, so
      # we assert on the typo + the declared list — the parts a real component's
      # class name is embedded alongside.)
      expect { instance.send(:on, :incremnt) }
        .to raise_error(Phlex::Reactive::Error) {
          expect(it.message).to include("has no declared action :incremnt")
          expect(it.message).to include("declared: [").and include(":increment").and include(":set")
        }
    end

    it "does not raise when verbose_errors is off (production keeps the permissive emit)" do
      Phlex::Reactive.verbose_errors = false
      expect { instance.send(:on, :incremnt) }.not_to raise_error
      expect(instance.send(:on, :incremnt)[:data][:reactive_action_param]).to eq("incremnt")
    end

    it "runs the check BEFORE the debounce/throttle guard (a typo raises the action error first)" do
      # Both a typo AND the mutually-exclusive debounce+throttle are wrong; the
      # undeclared-action check is placed first, so it wins.
      expect { instance.send(:on, :incremnt, debounce: 100, throttle: 100) }
        .to raise_error(Phlex::Reactive::Error, /no declared action :incremnt/)
    end

    # A component that declares NO actions of its own is a cross-component
    # dispatch helper — a child row rendering a trigger for its CONTAINER's
    # action, sending the container's token (e.g. a notification row → the list's
    # :dismiss). It can't self-validate against a registry it doesn't own, so the
    # guard skips the empty case entirely rather than false-positive.
    it "skips the check for a component that declares no actions (cross-component dispatch)" do
      dispatch_helper = Class.new do
        include Phlex::Reactive::Component

        def self.name = "DispatchHelper"
      end
      instance = dispatch_helper.new

      expect { instance.send(:on, :dismiss, id: 7) }.not_to raise_error
      expect(instance.send(:on, :dismiss, id: 7)[:data][:reactive_action_param]).to eq("dismiss")
    end
  end

  # Issue #181: the `on(…, listnav:)` kwarg is removed — it duplicated
  # reactive_listnav exactly (same LISTNAV_ACTIONS, same option param) while
  # SKIPPING its blank-selector validation, a real drift. Combobox keyboard
  # navigation now composes the standalone reactive_listnav via mix, so a single
  # validated code path wires it. The kwarg raises a guided ArgumentError.
  describe "#on listnav kwarg removed (issue #181 — use reactive_listnav)" do
    subject(:instance) { state_klass.new }

    it "raises a guided error pointing at reactive_listnav" do
      expect { instance.send(:on, :search, event: "input", listnav: "[role=option]") }
        .to raise_error(ArgumentError, /reactive_listnav/)
    end
  end

  # reactive_listnav is the ONE keyboard-navigation code path now (issue #181).
  # It defaults its option selector to [role=option] (the near-universal combobox
  # convention) so the common case needs no argument, and still validates a
  # non-blank selector when one is given.
  describe "#reactive_listnav (combobox keyboard navigation)" do
    subject(:instance) { state_klass.new }

    it "wires the arrow/enter/escape actions" do
      attrs = instance.send(:reactive_listnav)
      expect(attrs[:data][:action]).to eq(
        "keydown.down->reactive#listnavNext " \
        "keydown.up->reactive#listnavPrev " \
        "keydown.enter->reactive#listnavPick " \
        "keydown.esc->reactive#listnavClose"
      )
    end

    it "defaults the option selector to [role=option]" do
      attrs = instance.send(:reactive_listnav)
      expect(attrs[:data][:reactive_listnav_option_param]).to eq("[role=option]")
    end

    it "accepts an explicit option selector" do
      attrs = instance.send(:reactive_listnav, "li.opt")
      expect(attrs[:data][:reactive_listnav_option_param]).to eq("li.opt")
    end

    it "rejects a blank selector (a dead binding fails at render)" do
      expect { instance.send(:reactive_listnav, "  ") }
        .to raise_error(ArgumentError, /selector/)
    end

    it "emits no focus param and no home/end in highlight mode (byte-stable wire)" do
      attrs = instance.send(:reactive_listnav)
      expect(attrs[:data]).not_to have_key(:reactive_listnav_focus_param)
      expect(attrs[:data][:action]).not_to include("home")
    end

    # Issue #271: roving focus for a role=menu container.
    describe "focus: true (roving focus among menu items)" do
      it "binds down/up/home/end only, defaults to [role=menuitem], and flags focus mode" do
        attrs = instance.send(:reactive_listnav, focus: true)

        expect(attrs[:data][:action]).to eq(
          "keydown.down->reactive#listnavNext " \
          "keydown.up->reactive#listnavPrev " \
          "keydown.home->reactive#listnavFirst " \
          "keydown.end->reactive#listnavLast"
        )
        expect(attrs[:data][:reactive_listnav_option_param]).to eq("[role=menuitem]")
        expect(attrs[:data][:reactive_listnav_focus_param]).to eq("true")
      end

      it "accepts an explicit item selector" do
        attrs = instance.send(:reactive_listnav, "[data-item]", focus: true)
        expect(attrs[:data][:reactive_listnav_option_param]).to eq("[data-item]")
      end

      it "still rejects a blank selector" do
        expect { instance.send(:reactive_listnav, " ", focus: true) }.to raise_error(ArgumentError, /selector/)
      end

      it "composes with an on_client binding on the same container via mix" do
        attrs = Object.new.extend(Phlex::Helpers).send(:mix,
          instance.send(:reactive_listnav, focus: true),
          instance.send(:on_client, "keydown.esc", instance.js.hide("#menu")))

        expect(attrs[:data][:action]).to end_with("keydown.end->reactive#listnavLast keydown.esc->reactive#runOps")
        expect(attrs[:data][:reactive_listnav_focus_param]).to eq("true")
        expect(JSON.parse(attrs[:data][:reactive_ops_param])["on"]).to eq("keydown.esc")
      end
    end
  end

  describe "#on confirm gate (issue #52)" do
    subject(:instance) { state_klass.new }

    it "omits the confirm param by default" do
      attrs = instance.send(:on, :increment)
      expect(attrs[:data]).not_to have_key(:reactive_confirm_param)
    end

    it "emits the confirm message as a Stimulus param when given" do
      attrs = instance.send(:on, :destroy, confirm: "Really delete this item?")
      expect(attrs[:data][:reactive_confirm_param]).to eq("Really delete this item?")
    end

    it "keeps confirm out of the explicit params payload" do
      attrs = instance.send(:on, :set, confirm: "Sure?", count: 5)
      expect(JSON.parse(attrs[:data][:reactive_params_param])).to eq({ "count" => 5 })
    end

    it "threads confirm alongside debounce without collision" do
      attrs = instance.send(:on, :set, event: "input", debounce: 300, confirm: "Sure?")
      expect(attrs[:data][:reactive_debounce_param]).to eq(300)
      expect(attrs[:data][:reactive_confirm_param]).to eq("Sure?")
    end
  end

  # Issue #179: confirm: overloads to a Hash for CONDITIONAL confirmation — warn
  # only when field values look suspect. The declarative form reuses reactive_show's
  # conditions language via when: (scalar=equals, Range=threshold, Array=set),
  # compiled by ShowConditions and emitted as data-reactive-confirm-when-param JSON.
  # The named-predicate form carries a registered-function name. The static String
  # form is unchanged.
  describe "#on conditional confirm (issue #179)" do
    subject(:instance) { state_klass.new }

    it "compiles when: through the reactive_show conditions language (equals)" do
      attrs = instance.send(:on, :save, confirm: { when: { count: 0 }, message: "Count is 0 — continue?" })

      payload = JSON.parse(attrs[:data][:reactive_confirm_when_param])
      expect(payload["message"]).to eq("Count is 0 — continue?")
      # ShowConditions DNF wire: { any: [[{ field, equals }]] }
      term = payload.dig("groups", "any", 0, 0)
      expect(term["field"]).to eq("count")
      expect(term["equals"]).to eq("0")
      expect(attrs[:data]).not_to have_key(:reactive_confirm_param) # not the static form
    end

    it "compiles a Range value as a threshold (reactive_show semantics)" do
      attrs = instance.send(:on, :save, confirm: { when: { count: 100.. }, message: "Large — sure?" })

      term = JSON.parse(attrs[:data][:reactive_confirm_when_param]).dig("groups", "any", 0, 0)
      expect(term["field"]).to eq("count")
      expect(term["gte"]).to eq(100)
    end

    it "carries a named predicate verbatim" do
      attrs = instance.send(:on, :save, confirm: { predicate: "zero_total", message: "Totals look off — continue?" })

      payload = JSON.parse(attrs[:data][:reactive_confirm_when_param])
      expect(payload["predicate"]).to eq("zero_total")
      expect(payload["message"]).to eq("Totals look off — continue?")
    end

    it "raises when the Hash has neither when: nor predicate:" do
      expect { instance.send(:on, :save, confirm: { message: "?" }) }
        .to raise_error(ArgumentError, /when:.*predicate:|needs (a )?when:/i)
    end

    it "raises when the Hash has BOTH when: and predicate:" do
      expect { instance.send(:on, :save, confirm: { when: { count: 0 }, predicate: "x", message: "?" }) }
        .to raise_error(ArgumentError, /when:.*predicate:|exactly one|not both/i)
    end

    it "raises when the Hash omits message:" do
      expect { instance.send(:on, :save, confirm: { when: { count: 0 } }) }
        .to raise_error(ArgumentError, /message:/)
    end

    it "works identically on on_client (the Hash rides the client-op path too)" do
      attrs = instance.send(:on_client, :click, instance.js.text("#draft", ""),
        confirm: { when: { count: 0 }, message: "Discard?" })

      payload = JSON.parse(attrs[:data][:reactive_ops_param])["confirmWhen"]
      expect(payload["message"]).to eq("Discard?")
      expect(payload.dig("groups", "any", 0, 0)["field"]).to eq("count")
    end
  end

  describe "#on keyboard filters via event: (Enter-to-submit / Escape-to-cancel)" do
    subject(:instance) { state_klass.new }

    it "passes a Stimulus keyboard-filter event through verbatim (Enter)" do
      attrs = instance.send(:on, :add, event: "keydown.enter")
      expect(attrs[:data][:action]).to eq("keydown.enter->reactive#dispatch")
    end

    it "passes an Escape filter through verbatim" do
      attrs = instance.send(:on, :cancel, event: "keydown.esc")
      expect(attrs[:data][:action]).to eq("keydown.esc->reactive#dispatch")
    end

    it "does not force type=button for a keyboard trigger (it's not a click)" do
      attrs = instance.send(:on, :add, event: "keydown.enter")
      expect(attrs).not_to have_key(:type)
    end

    it "threads a keyboard event alongside debounce and explicit params" do
      attrs = instance.send(:on, :add, event: "keydown.enter", debounce: 200, title: "x")
      expect(attrs[:data][:action]).to eq("keydown.enter->reactive#dispatch")
      expect(attrs[:data][:reactive_debounce_param]).to eq(200)
      expect(JSON.parse(attrs[:data][:reactive_params_param])).to eq({ "title" => "x" })
    end

    # Regression: `key` is an ordinary action-param name and MUST stay one (the
    # docs context switcher does on(:switch, key: opt[:key])). It is not a
    # reserved keyword — it rides in the params payload like any other.
    it "treats key: as a normal action param, not a keyboard filter" do
      attrs = instance.send(:on, :switch, key: "pgbus")
      expect(attrs[:data][:action]).to eq("click->reactive#dispatch")
      expect(JSON.parse(attrs[:data][:reactive_params_param])).to eq({ "key" => "pgbus" })
    end

    it "leaves the plain (non-keyboard) event descriptor untouched" do
      attrs = instance.send(:on, :toggle, event: "change")
      expect(attrs[:data][:action]).to eq("change->reactive#dispatch")
    end
  end

  describe "#on event modifiers (issue #80 — window:, once:, outside:, throttle:)" do
    subject(:instance) { state_klass.new }

    # The hot-path pin: a bare on(:x) — the overwhelmingly common trigger — must
    # emit EXACTLY today's hash. New modifiers may not perturb the no-modifier
    # descriptor, params payload, or the forced type="button" by a single byte.
    it "leaves the bare on(:x) emission byte-identical (no-modifier hot path)" do
      expect(instance.send(:on, :increment)).to eq(
        {
          data: {
            action: "click->reactive#dispatch",
            reactive_action_param: "increment",
            reactive_params_param: "{}"
          },
          type: "button"
        }
      )
    end

    it "window: true binds the descriptor to @window and flags the window param" do
      attrs = instance.send(:on, :track, window: true)
      expect(attrs[:data][:action]).to eq("click@window->reactive#dispatch")
      expect(attrs[:data][:reactive_window_param]).to eq("true")
    end

    it "window: true skips type=button (the trigger isn't an in-form button)" do
      attrs = instance.send(:on, :track, window: true)
      expect(attrs).not_to have_key(:type)
    end

    it "once: true appends Stimulus's :once option to the descriptor" do
      attrs = instance.send(:on, :dismiss, once: true)
      expect(attrs[:data][:action]).to eq("click->reactive#dispatch:once")
    end

    it "composes window: and once: in descriptor order (@window before :once)" do
      attrs = instance.send(:on, :dismiss, window: true, once: true)
      expect(attrs[:data][:action]).to eq("click@window->reactive#dispatch:once")
    end

    it "outside: true implies the window binding" do
      attrs = instance.send(:on, :close_menu, outside: true)
      expect(attrs[:data][:action]).to eq("click@window->reactive#dispatch")
      expect(attrs).not_to have_key(:type)
    end

    it "outside: true emits BOTH the outside and window Stimulus params" do
      attrs = instance.send(:on, :close_menu, outside: true)
      # The client decides preventDefault behavior from event.params (the window
      # flag), never by sniffing the descriptor — so outside must set both.
      expect(attrs[:data][:reactive_outside_param]).to eq("true")
      expect(attrs[:data][:reactive_window_param]).to eq("true")
    end

    it "throttle: emits the throttle window as a Stimulus param" do
      attrs = instance.send(:on, :track, event: "scroll", window: true, throttle: 250)
      expect(attrs[:data][:reactive_throttle_param]).to eq(250)
    end

    it "raises ArgumentError when both debounce: and throttle: are given" do
      expect { instance.send(:on, :track, debounce: 300, throttle: 250) }
        .to raise_error(ArgumentError, /debounce.*throttle/m)
    end

    it "keeps the modifiers out of the explicit params payload" do
      attrs = instance.send(:on, :close_menu, outside: true, once: true, throttle: 100, reason: "esc")
      expect(JSON.parse(attrs[:data][:reactive_params_param])).to eq({ "reason" => "esc" })
    end

    it "omits every modifier param by default" do
      attrs = instance.send(:on, :increment)
      expect(attrs[:data]).not_to have_key(:reactive_window_param)
      expect(attrs[:data]).not_to have_key(:reactive_outside_param)
      expect(attrs[:data]).not_to have_key(:reactive_throttle_param)
    end
  end

  describe "#on optimistic hints (issue #98 — declared, reversible visual hints)" do
    subject(:instance) { state_klass.new }

    it "omits the optimistic param by default (bare on() hot path untouched)" do
      attrs = instance.send(:on, :increment)
      expect(attrs[:data]).not_to have_key(:reactive_optimistic_param)
    end

    it "emits the optimistic hint hash as a JSON Stimulus param" do
      attrs = instance.send(:on, :toggle, optimistic: { checked: :keep })
      expect(JSON.parse(attrs[:data][:reactive_optimistic_param])).to eq({ "checked" => "keep" })
    end

    it "serializes a class op with a single class string" do
      attrs = instance.send(:on, :toggle, optimistic: { toggle_class: "done" })
      expect(JSON.parse(attrs[:data][:reactive_optimistic_param])).to eq({ "toggle_class" => ["done"] })
    end

    it "serializes a class op with an array of classes" do
      attrs = instance.send(:on, :toggle, optimistic: { add_class: %w[busy dim] })
      expect(JSON.parse(attrs[:data][:reactive_optimistic_param])).to eq({ "add_class" => %w[busy dim] })
    end

    it "serializes remove_class" do
      attrs = instance.send(:on, :toggle, optimistic: { remove_class: "active" })
      expect(JSON.parse(attrs[:data][:reactive_optimistic_param])).to eq({ "remove_class" => ["active"] })
    end

    it "serializes hide: true" do
      attrs = instance.send(:on, :destroy, optimistic: { hide: true })
      expect(JSON.parse(attrs[:data][:reactive_optimistic_param])).to eq({ "hide" => true })
    end

    it "normalizes to: :root to the @root sentinel" do
      attrs = instance.send(:on, :destroy, optimistic: { hide: true, to: :root })
      expect(JSON.parse(attrs[:data][:reactive_optimistic_param])).to eq({ "hide" => true, "to" => "@root" })
    end

    it "passes a to: CSS selector string through verbatim" do
      attrs = instance.send(:on, :toggle, optimistic: { add_class: "on", to: ".badge" })
      expect(JSON.parse(attrs[:data][:reactive_optimistic_param])).to eq({ "add_class" => ["on"], "to" => ".badge" })
    end

    it "combines several hint ops in one hash (checked + class)" do
      attrs = instance.send(:on, :toggle, event: "change", optimistic: { checked: :keep, toggle_class: "done" })
      expect(JSON.parse(attrs[:data][:reactive_optimistic_param]))
        .to eq({ "checked" => "keep", "toggle_class" => ["done"] })
    end

    it "keeps the optimistic hint out of the explicit params payload" do
      attrs = instance.send(:on, :toggle, optimistic: { hide: true }, reason: "gone")
      expect(JSON.parse(attrs[:data][:reactive_params_param])).to eq({ "reason" => "gone" })
    end

    it "threads optimistic alongside confirm and debounce without collision" do
      attrs = instance.send(:on, :destroy, confirm: "Sure?", debounce: 200, optimistic: { hide: true })
      expect(attrs[:data][:reactive_confirm_param]).to eq("Sure?")
      expect(attrs[:data][:reactive_debounce_param]).to eq(200)
      expect(JSON.parse(attrs[:data][:reactive_optimistic_param])).to eq({ "hide" => true })
    end

    it "rejects an unknown hint op (default-deny — a dead hint must fail at build)" do
      expect { instance.send(:on, :toggle, optimistic: { explode: true }) }
        .to raise_error(ArgumentError, /explode/)
    end

    it "rejects a checked: value other than :keep" do
      expect { instance.send(:on, :toggle, optimistic: { checked: :flip }) }
        .to raise_error(ArgumentError, /checked/)
    end

    it "rejects a non-hash optimistic:" do
      expect { instance.send(:on, :toggle, optimistic: [%w[toggle_class done]]) }
        .to raise_error(ArgumentError, /optimistic/)
    end

    # checked: :keep on a click trigger must NOT force type="button" — the hint's
    # whole point is a native checkbox/radio flip, and a forced button type would
    # destroy the control (issue #98). The caller supplies the real type.
    it "skips the forced type=button for a click trigger with checked: :keep" do
      attrs = instance.send(:on, :toggle, optimistic: { checked: :keep })
      expect(attrs).not_to have_key(:type)
    end

    it "still forces type=button for a click trigger whose hint is NOT checked: :keep" do
      attrs = instance.send(:on, :destroy, optimistic: { hide: true })
      expect(attrs[:type]).to eq("button")
    end

    it "still forces type=button for a bare click trigger (no optimistic hint)" do
      attrs = instance.send(:on, :increment)
      expect(attrs[:type]).to eq("button")
    end
  end

  # Issue #181: busy: is the ONE pending-state vocabulary, replacing loading: and
  # disable_with:. It shares optimistic:'s key set (js.* op names + disable:/to:)
  # and one Ruby normalizer, differing only in lifecycle: busy: reverts on SETTLE
  # (any completion), optimistic: reverts on FAILURE. The String shorthand
  # `busy: "Saving…"` expands to { disable: true, text: … } — the ubiquitous
  # "disable + swap the label" case in one word.
  describe "#on busy states (issue #181 — busy:)" do
    subject(:instance) { state_klass.new }

    it "omits the busy param by default (bare on() hot path untouched)" do
      attrs = instance.send(:on, :increment)
      expect(attrs[:data]).not_to have_key(:reactive_busy_param)
    end

    it "expands the String shorthand to { disable: true, text: … }" do
      attrs = instance.send(:on, :save, busy: "Saving…")
      expect(JSON.parse(attrs[:data][:reactive_busy_param]))
        .to eq({ "disable" => true, "text" => "Saving…" })
    end

    it "emits a full busy: hash (disable + add_class + text)" do
      attrs = instance.send(:on, :save, busy: { disable: true, add_class: "opacity-50", text: "Saving…" })
      expect(JSON.parse(attrs[:data][:reactive_busy_param]))
        .to eq({ "disable" => true, "add_class" => ["opacity-50"], "text" => "Saving…" })
    end

    it "serializes an add_class array" do
      attrs = instance.send(:on, :save, busy: { add_class: %w[opacity-50 pointer-events-none] })
      expect(JSON.parse(attrs[:data][:reactive_busy_param]))
        .to eq({ "add_class" => %w[opacity-50 pointer-events-none] })
    end

    it "supports remove_class and toggle_class (shared optimistic: vocabulary)" do
      attrs = instance.send(:on, :save, busy: { remove_class: "idle", toggle_class: "spin" })
      expect(JSON.parse(attrs[:data][:reactive_busy_param]))
        .to eq({ "remove_class" => ["idle"], "toggle_class" => ["spin"] })
    end

    it "supports hide: and show:" do
      attrs = instance.send(:on, :save, busy: { hide: true, show: true })
      expect(JSON.parse(attrs[:data][:reactive_busy_param])).to eq({ "hide" => true, "show" => true })
    end

    it "normalizes busy disable: to a real boolean" do
      attrs = instance.send(:on, :save, busy: { disable: true })
      expect(JSON.parse(attrs[:data][:reactive_busy_param])).to eq({ "disable" => true })
    end

    it "normalizes to: :root to the @root sentinel" do
      attrs = instance.send(:on, :save, busy: { add_class: "busy", to: :root })
      expect(JSON.parse(attrs[:data][:reactive_busy_param]))
        .to eq({ "add_class" => ["busy"], "to" => "@root" })
    end

    it "passes a to: CSS selector string through verbatim" do
      attrs = instance.send(:on, :save, busy: { add_class: "busy", to: ".spinner" })
      expect(JSON.parse(attrs[:data][:reactive_busy_param]))
        .to eq({ "add_class" => ["busy"], "to" => ".spinner" })
    end

    it "keeps the busy hint out of the explicit params payload" do
      attrs = instance.send(:on, :save, busy: "Saving…", reason: "click")
      expect(JSON.parse(attrs[:data][:reactive_params_param])).to eq({ "reason" => "click" })
    end

    it "threads busy alongside confirm, debounce and optimistic without collision" do
      attrs = instance.send(:on, :save, confirm: "Sure?", debounce: 200,
        optimistic: { add_class: "pending" }, busy: "Saving…")
      expect(attrs[:data][:reactive_confirm_param]).to eq("Sure?")
      expect(attrs[:data][:reactive_debounce_param]).to eq(200)
      expect(JSON.parse(attrs[:data][:reactive_optimistic_param])).to eq({ "add_class" => ["pending"] })
      expect(JSON.parse(attrs[:data][:reactive_busy_param]))
        .to eq({ "disable" => true, "text" => "Saving…" })
    end

    it "rejects an unknown busy key (default-deny — a dead hint fails at build)" do
      expect { instance.send(:on, :save, busy: { spin: true }) }
        .to raise_error(ArgumentError, /spin/)
    end

    it "rejects checked: (native-flip is optimistic-only, not a settle-revert hint)" do
      expect { instance.send(:on, :save, busy: { checked: :keep }) }
        .to raise_error(ArgumentError, /checked/)
    end

    it "rejects a busy: that is neither a String nor a Hash" do
      expect { instance.send(:on, :save, busy: [%w[disable true]]) }
        .to raise_error(ArgumentError, /busy/)
    end

    it "still forces type=button for a click trigger with a busy hint" do
      attrs = instance.send(:on, :save, busy: "Saving…")
      expect(attrs[:type]).to eq("button")
    end
  end

  # Issue #181: loading: and disable_with: are removed in favor of busy:. Each
  # raises a guided ArgumentError showing the busy: rewrite (clean break, pre-1.0
  # — no silent shim that would let a stale call limp along wrong).
  describe "#on removed loading kwargs (issue #181 — guided errors)" do
    subject(:instance) { state_klass.new }

    it "raises a guided error for disable_with: pointing at busy:" do
      expect { instance.send(:on, :save, disable_with: "Saving…") }
        .to raise_error(ArgumentError, /busy:/)
    end

    it "raises a guided error for loading: pointing at busy:" do
      expect { instance.send(:on, :save, loading: { disable: true }) }
        .to raise_error(ArgumentError, /busy:/)
    end
  end

  describe "#busy_on (issue #99 — scoped busy indicators)" do
    subject(:instance) { state_klass.new }

    it "emits data-reactive-busy-on for the named action" do
      expect(instance.send(:busy_on, :save)).to eq({ data: { reactive_busy_on: "save" } })
    end

    it "stringifies a symbol action name" do
      expect(instance.send(:busy_on, :destroy)[:data][:reactive_busy_on]).to eq("destroy")
    end

    it "accepts a string action name" do
      expect(instance.send(:busy_on, "save")[:data][:reactive_busy_on]).to eq("save")
    end
  end

  describe "#on_client (issue #95 — client-only DOM ops, zero round trip)" do
    subject(:instance) { state_klass.new }

    let(:ops) { instance.js.toggle("#menu") }

    it "exposes the js builder as an instance helper" do
      expect(instance.js).to be_a(Phlex::Reactive::JS)
    end

    # Issue #271: every on_client call emits ONE self-describing binding record
    # ({on, ops, window?, outside?, confirm?, confirmWhen?}) in
    # data-reactive-ops-param, so several bindings on one element compose
    # through mix (the records space-join) and the client runs the record whose
    # descriptor matches the firing event.
    def binding_record(attrs) = JSON.parse(attrs[:data][:reactive_ops_param])

    it "binds the event to runOps and carries ONLY a binding record (no token, no action, no params)" do
      attrs = instance.send(:on_client, :click, ops)

      expect(attrs[:data][:action]).to eq("click->reactive#runOps")
      expect(attrs[:data][:reactive_ops_param]).to eq('{"on":"click","ops":[["toggle",{"to":"#menu"}]]}')
      expect(attrs[:data]).not_to have_key(:reactive_action_param)
      expect(attrs[:data]).not_to have_key(:reactive_params_param)
      expect(attrs[:data]).not_to have_key(:reactive_token_value)
    end

    it "no longer writes the element-wide outside/window/confirm params (they would leak across bindings)" do
      attrs = instance.send(:on_client, :click, ops, outside: true, confirm: "Sure?")

      expect(attrs[:data].keys).to contain_exactly(:action, :reactive_ops_param)
    end

    it "forces type=button for click triggers (a bare button in a form must not submit)" do
      expect(instance.send(:on_client, :click, ops)[:type]).to eq("button")
    end

    it "composes window:/once: into the descriptor, window into the record, and skips type=button" do
      attrs = instance.send(:on_client, :click, ops, window: true, once: true)

      expect(attrs[:data][:action]).to eq("click@window->reactive#runOps:once")
      expect(binding_record(attrs))
        .to eq("on" => "click", "window" => true, "once" => true, "ops" => [["toggle", { "to" => "#menu" }]])
      expect(attrs).not_to have_key(:type)
    end

    it "outside: implies the window binding and records BOTH flags" do
      attrs = instance.send(:on_client, :click, ops, outside: true)

      expect(attrs[:data][:action]).to eq("click@window->reactive#runOps")
      expect(binding_record(attrs)).to include("on" => "click", "window" => true, "outside" => true)
    end

    it "keeps a keyboard filter in the record's on (it is what the client matches)" do
      attrs = instance.send(:on_client, "keydown.esc", ops)

      expect(attrs[:data][:action]).to eq("keydown.esc->reactive#runOps")
      expect(binding_record(attrs)["on"]).to eq("keydown.esc")
    end

    it "encodes spaces as \\u0020 so the record survives mix's space-join" do
      attrs = instance.send(:on_client, :click, instance.js.hide("#menu .item").text("#status", "Hello world"))

      expect(attrs[:data][:reactive_ops_param]).not_to include(" ")
      expect(attrs[:data][:reactive_ops_param]).to include('\u0020')
      expect(binding_record(attrs)["ops"]).to eq([["hide", { "to" => "#menu .item" }],
                                                  ["text", { "to" => "#status", "value" => "Hello world" }]])
    end

    it "composes two bindings on one element through mix (descriptors token-join, records space-join)" do
      attrs = Object.new.extend(Phlex::Helpers).send(:mix,
        instance.send(:on_client, :click, instance.js.hide("#menu"), outside: true),
        instance.send(:on_client, "keydown.esc", instance.js.hide("#menu .x")))

      expect(attrs[:data][:action]).to eq("click@window->reactive#runOps keydown.esc->reactive#runOps")
      records = attrs[:data][:reactive_ops_param].split.map { JSON.parse(it) }
      expect(records.pluck("on")).to eq(%w[click keydown.esc])
      expect(records.first).to include("window" => true, "outside" => true)
      expect(records.last).not_to have_key("outside")
      expect(records.last["ops"]).to eq([["hide", { "to" => "#menu .x" }]])
    end

    it "rejects anything that is not a Phlex::Reactive::JS chain" do
      expect { instance.send(:on_client, :click, [["toggle", { "to" => "#menu" }]]) }
        .to raise_error(ArgumentError, /Phlex::Reactive::JS/)
    end

    it "rejects an empty op chain (a dead trigger must fail loudly at render)" do
      expect { instance.send(:on_client, :click, instance.js) }
        .to raise_error(ArgumentError, /no ops/)
    end

    # Issue #178: confirm: gates the chain behind the same confirmResolver as
    # on(...). Issue #271: the message rides IN the binding record, so a sibling
    # binding on the same element is never gated by it.
    it "records confirm: in the binding when given" do
      attrs = instance.send(:on_client, :click, ops, confirm: "Discard this draft?")

      expect(binding_record(attrs)["confirm"]).to eq("Discard this draft?")
      expect(attrs[:data][:action]).to eq("click->reactive#runOps")
    end

    it "omits confirm from the record when confirm: is absent" do
      expect(binding_record(instance.send(:on_client, :click, ops))).not_to have_key("confirm")
    end

    it "composes confirm: with window:/outside: (the gate rides any binding)" do
      attrs = instance.send(:on_client, :click, ops, outside: true, confirm: "Sure?")

      expect(binding_record(attrs)).to include("confirm" => "Sure?", "outside" => true)
    end

    it "treats confirm: false like no confirm (a conditional option stays usable)" do
      expect(binding_record(instance.send(:on_client, :click, ops, confirm: false))).not_to have_key("confirm")
    end

    it "records once: so a spent one-shot binding is skipped beside a regular sibling" do
      attrs = instance.send(:on_client, :click, ops, once: true)

      expect(attrs[:data][:action]).to eq("click->reactive#runOps:once")
      expect(binding_record(attrs)).to include("once" => true)
      expect(binding_record(instance.send(:on_client, :click, ops))).not_to have_key("once")
    end

    # Issue #346: detail: gates the binding on the event's payload.
    it "records detail: with stringified keys, next to the other flags" do
      attrs = instance.send(:on_client, "turbo:submit-end", ops, detail: { success: true })

      expect(attrs[:data][:action]).to eq("turbo:submit-end->reactive#runOps")
      expect(attrs[:data][:reactive_ops_param])
        .to eq('{"on":"turbo:submit-end","detail":{"success":true},"ops":[["toggle",{"to":"#menu"}]]}')
    end

    it "accepts JSON scalars as detail values" do
      record = binding_record(instance.send(:on_client, "upload:done", ops,
        detail: { "ok" => true, failed: false, status: "done", code: 200, ratio: 0.5, error: nil }))

      expect(record["detail"])
        .to eq("ok" => true, "failed" => false, "status" => "done", "code" => 200, "ratio" => 0.5, "error" => nil)
    end

    it "leaves detail out of the record when it is not given (existing markup unchanged)" do
      expect(binding_record(instance.send(:on_client, :click, ops))).not_to have_key("detail")
    end

    it "keeps each binding's own detail when two compose through mix" do
      attrs = Object.new.extend(Phlex::Helpers).send(:mix,
        instance.send(:on_client, "turbo:submit-end", ops, detail: { success: true }),
        instance.send(:on_client, "turbo:submit-end", instance.js.show("#error"), detail: { success: false }))
      records = attrs[:data][:reactive_ops_param].split.map { JSON.parse(it) }

      expect(records.pluck("detail")).to eq([{ "success" => true }, { "success" => false }])
    end

    { "a Hash" => { a: 1 }, "an Array" => [1], "a Proc" => -> {}, "a Symbol" => :ok,
      "Infinity" => Float::INFINITY }.each do |label, value|
      it "raises at render for #{label} as a detail value" do
        expect { instance.send(:on_client, "turbo:submit-end", ops, detail: { success: value }) }
          .to raise_error(ArgumentError, /detail: values must be JSON scalars/)
      end
    end

    it "raises for a detail: that is not a non-empty Hash" do
      expect { instance.send(:on_client, "turbo:submit-end", ops, detail: {}) }
        .to raise_error(ArgumentError, /detail: takes a non-empty Hash/)
      expect { instance.send(:on_client, "turbo:submit-end", ops, detail: true) }
        .to raise_error(ArgumentError, /detail: takes a non-empty Hash/)
      expect { instance.send(:on_client, "turbo:submit-end", ops, detail: false) }
        .to raise_error(ArgumentError, /detail: takes a non-empty Hash/)
    end

    it "raises for detail: with once: (the :once listener is gone after a first non-matching event)" do
      expect { instance.send(:on_client, "turbo:submit-end", ops, detail: { success: true }, once: true) }
        .to raise_error(ArgumentError, /once:/)
    end

    it "raises the shared guided error for a confirm: that is neither String nor Hash" do
      expect { instance.send(:on_client, :click, ops, confirm: true) }
        .to raise_error(ArgumentError, /confirm: takes a String/)
    end

    # Issue #226: requestSubmit dispatches the very `submit` event an
    # on_client(:submit, ...) trigger is bound to — a submit op there would
    # re-fire itself forever. Loud at render, like every dead/hostile binding.
    it "rejects a submit op bound to the submit event (it would re-fire itself)" do
      expect { instance.send(:on_client, :submit, instance.js.submit) }
        .to raise_error(ArgumentError, /re-fire/)
    end

    it "rejects the self-loop even when submit is buried in a longer chain" do
      chain = instance.js.add_class(:root, "busy").submit
      expect { instance.send(:on_client, :submit, chain) }
        .to raise_error(ArgumentError, /re-fire/)
    end

    it "allows a submit op on any other event (the general autosubmit story)" do
      attrs = instance.send(:on_client, :change, instance.js.submit)

      expect(attrs[:data][:action]).to eq("change->reactive#runOps")
      expect(binding_record(attrs)["ops"]).to eq([["submit", { "to" => "@root" }]])
    end

    it "allows non-submit ops on the submit event (a busy-state chain is fine)" do
      attrs = instance.send(:on_client, :submit, instance.js.add_class(:root, "busy"))

      expect(attrs[:data][:action]).to eq("submit->reactive#runOps")
    end

    # Issue #228: a paste_into trigger is marked so the client can gate its
    # visibility on clipboard availability (hidden wherever the API is missing
    # — a dead paste button must never show).
    it "marks a paste_into trigger with data-reactive-clipboard (string true, never boolean)" do
      attrs = instance.send(:on_client, :click, instance.js.paste_into("#code"))

      expect(attrs[:data][:reactive_clipboard]).to eq("true")
      expect(binding_record(attrs)["ops"]).to eq([["paste_into", { "to" => "#code" }]])
    end

    it "marks the trigger even when paste_into is buried in a longer chain" do
      chain = instance.js.add_class(:root, "busy").paste_into("#code")
      attrs = instance.send(:on_client, :click, chain)

      expect(attrs[:data][:reactive_clipboard]).to eq("true")
    end

    it "does not mark a non-paste trigger (byte-stable wire for existing callers)" do
      attrs = instance.send(:on_client, :click, ops)

      expect(attrs[:data]).not_to have_key(:reactive_clipboard)
    end
  end

  # A record-backed component whose record is UNSAVED (new_record?) has no
  # GlobalID to sign. reactive_token must not crash calling to_gid on it — it
  # signs the declared state instead (the draft seed), so the client controller
  # still mounts and a client-side compute (reactive_compute) can drive the
  # unpersisted record in-browser. This is the "tokenless draft" seam.
  describe "record-backed component holding an UNSAVED record (draft seed)" do
    # A record double that is not persisted and raises on to_gid (mirroring
    # ActiveRecord::Base#to_gid on a new_record — MissingModelIdError).
    let(:unsaved_record) do
      Class.new do
        def persisted? = false
        def to_gid = raise(URI::GID::MissingModelIdError, "no id")
      end.new
    end

    let(:draft_klass) do
      Class.new do
        include Phlex::Reactive::Streamable
        include Phlex::Reactive::Component

        def self.name = "DraftThing"

        reactive_record :order
        reactive_state :total, :allowance

        def initialize(order:, total: 0, allowance: 0)
          @order = order
          @total = total
          @allowance = allowance
        end

        attr_reader :order, :total, :allowance

        def id = "draft-thing"
      end
    end

    it "signs {c, s} WITHOUT a gid when the record is unsaved (no crash)" do
      token = draft_klass.new(order: unsaved_record, total: 500, allowance: 100).send(:reactive_token)
      payload = Phlex::Reactive.verify(token)

      expect(payload["c"]).to eq("DraftThing")
      expect(payload).not_to have_key("gid")
      expect(payload["s"]).to eq({ "total" => 500, "allowance" => 100 })
    end

    it "still signs the gid when the record IS persisted" do
      saved = Struct.new(:gid_string).new("gid://app/Order/7")
      allow(saved).to receive_messages(persisted?: true, to_gid: instance_double(GlobalID, to_s: saved.gid_string))

      token = draft_klass.new(order: saved, total: 500).send(:reactive_token)
      payload = Phlex::Reactive.verify(token)

      expect(payload["gid"]).to eq("gid://app/Order/7")
    end

    it "signs {c, s} WITHOUT a gid when the record ivar is nil (no nil.to_gid crash)" do
      # A record-backed component constructed with no record: the ivar guard
      # must short-circuit before to_gid so the token still signs the state.
      token = draft_klass.new(order: nil, total: 500, allowance: 100).send(:reactive_token)
      payload = Phlex::Reactive.verify(token)

      expect(payload).not_to have_key("gid")
      expect(payload["s"]).to eq({ "total" => 500, "allowance" => 100 })
    end
  end

  # Issue #208: the draft token's REBUILD side. Component::Identity signs a
  # gid-less {c, s} token for an unpersisted (or nil) record — from_identity
  # must accept that token BACK: omit the record kwarg (the initialize default
  # seeds a fresh draft, mirroring first render) instead of crashing on the
  # absent gid. This is what lets a draft parent run real server actions.
  describe ".from_identity with a DRAFT token (no gid, issue #208)" do
    let(:draft_capable_klass) do
      Class.new do
        include Phlex::Reactive::Component

        def self.name = "DraftCapableThing"

        reactive_record :order
        reactive_state :rows

        def initialize(order: nil, rows: [])
          @order = order
          @rows = rows
        end

        attr_reader :order, :rows

        def id = "draft-capable"
      end
    end

    it "rebuilds through the initialize default when the payload carries no gid" do
      component = draft_capable_klass.from_identity({ "c" => "DraftCapableThing" })

      expect(component.order).to be_nil
    end

    it "round-trips structured draft state (array-of-hashes rows) sign → verify → rebuild" do
      rows = [{ "quantity" => 2, "price" => 100 }, { "quantity" => 1, "price" => 50 }]
      token = draft_capable_klass.new(rows: rows).send(:reactive_token)
      component = draft_capable_klass.from_identity(Phlex::Reactive.verify(token))

      expect(component.order).to be_nil
      expect(component.rows).to eq(rows)
    end

    it "raises a guided error when initialize REQUIRES the record kwarg (not draft-capable)" do
      requiring = Class.new do
        include Phlex::Reactive::Component

        def self.name = "RequiresRecordThing"

        reactive_record :order

        def initialize(order:) = @order = order
        def id = "requires-record"
      end

      expect { requiring.from_identity({ "c" => "RequiresRecordThing" }) }
        .to raise_error(Phlex::Reactive::Error, /default/)
    end

    it "still locates the record when the payload HAS a gid (persisted path unchanged)" do
      record = Object.new
      allow(GlobalID::Locator).to receive(:locate).with("gid://app/Order/7").and_return(record)

      component = draft_capable_klass.from_identity({ "c" => "DraftCapableThing", "gid" => "gid://app/Order/7" })

      expect(component.order).to be(record)
    end
  end

  # reactive_compute declares a CLIENT-SIDE reducer: on `input`, the generic
  # controller runs a registered JS function over the named input fields and
  # writes the named output fields WITHOUT a round trip (the "instant" half of
  # the new-record UX), then the debounced POST reconciles from the server reply.
  # The Ruby side is pure hash-building — no view context, no DB — so it lives
  # here alongside on/reactive_field.
  describe "reactive_compute DSL (client-side data bindings)" do
    let(:compute_klass) do
      Class.new do
        include Phlex::Reactive::Component

        def self.name = "ComputeThing"

        reactive_state :total
        reactive_compute :payment_split,
          inputs: %i[allowance cash leasing total],
          outputs: %i[allowance cash leasing]

        def initialize(total: 0) = @total = total
      end
    end

    describe "declaration registry" do
      it "registers a declared compute" do
        expect(compute_klass.reactive_computes.key?(:payment_split)).to be(true)
      end

      it "does not register an undeclared name" do
        expect(compute_klass.reactive_computes.key?(:wat)).to be(false)
        expect(compute_klass.reactive_computes[:wat]).to be_nil
      end

      it "captures the inputs and outputs" do
        definition = compute_klass.reactive_computes[:payment_split]
        expect(definition.inputs).to eq(%i[allowance cash leasing total])
        expect(definition.outputs).to eq(%i[allowance cash leasing])
      end

      it "defaults the reducer key to the compute name" do
        expect(compute_klass.reactive_computes[:payment_split].reducer).to eq("payment_split")
      end

      it "honors an explicit reducer key" do
        klass = Class.new do
          include Phlex::Reactive::Component

          def self.name = "CustomReducer"
          reactive_compute :split, inputs: %i[a], outputs: %i[b], reducer: "shared_split"
        end
        expect(klass.reactive_computes[:split].reducer).to eq("shared_split")
      end
    end

    describe "inheritance" do
      it "inherits computes from a parent and adds its own without mutating the parent" do
        child = Class.new(compute_klass) do
          def self.name = "ComputeChild"
          reactive_compute :totals, inputs: %i[price qty], outputs: %i[total]
        end

        expect(child.reactive_computes.key?(:payment_split)).to be(true) # inherited
        expect(child.reactive_computes.key?(:totals)).to be(true)        # own
        expect(compute_klass.reactive_computes.key?(:totals)).to be(false) # parent unaffected
      end
    end

    # Issue #226: reactive_on_complete — the declarative completion binding.
    # Conditions reuse the ONE ShowConditions language (including the #226
    # length: form); run: is a js chain (or a raw op list, allowlist-checked)
    # the client applies on the RISING EDGE of the conditions, through the
    # same frozen CLIENT_OPS whitelist as on_client.
    describe "reactive_on_complete (issue #226 — declarative completion binding)" do
      let(:complete_klass) do
        Class.new do
          include Phlex::Reactive::Component

          def self.name = "OtpForm"

          reactive_state :count
          reactive_on_complete if: { code: { length: 6 } },
            run: Phlex::Reactive::JS.new.dispatch("code:complete")

          def initialize(count: 0) = @count = count
        end
      end

      describe "declaration registry" do
        it "registers under :default when unnamed" do
          expect(complete_klass.reactive_on_completes.key?(:default)).to be(true)
        end

        it "compiles the conditions through the ShowConditions language" do
          expect(complete_klass.reactive_on_completes[:default].conditions)
            .to eq([[{ "field" => "code", "len_eq" => 6 }]])
        end

        it "captures the op chain pairs" do
          expect(complete_klass.reactive_on_completes[:default].ops)
            .to eq([["dispatch", { "name" => "code:complete", "to" => "@root", "detail" => {} }]])
        end

        it "supports multiple NAMED bindings" do
          klass = Class.new do
            include Phlex::Reactive::Component

            def self.name = "TwoBindings"
            reactive_on_complete :ready, if: { code: { length: 6 } },
              run: Phlex::Reactive::JS.new.submit
            reactive_on_complete :too_long, if: { code: { length: 10.. } },
              run: Phlex::Reactive::JS.new.add_class(:root, "overflow")
          end
          expect(klass.reactive_on_completes.keys).to eq(%i[ready too_long])
        end

        it "is inherited without mutating the parent" do
          child = Class.new(complete_klass) do
            def self.name = "OtpChild"
            reactive_on_complete :extra, if: { kind: "sms" }, run: Phlex::Reactive::JS.new.submit
          end

          expect(child.reactive_on_completes.keys).to contain_exactly(:default, :extra)
          expect(complete_klass.reactive_on_completes.keys).to eq([:default])
        end

        it "exposes js at class level so declarations read naturally" do
          klass = Class.new do
            include Phlex::Reactive::Component

            def self.name = "NaturalJs"
            reactive_on_complete if: { a: "1" }, run: js.dispatch("x")
          end
          expect(klass.reactive_on_completes[:default].ops.first.first).to eq("dispatch")
        end
      end

      describe "loud validation" do
        it "rejects a run: that is neither a JS chain nor an op list" do
          expect do
            Class.new do
              include Phlex::Reactive::Component

              def self.name = "BadRun"
              reactive_on_complete if: { a: "1" }, run: "submit"
            end
          end.to raise_error(ArgumentError, /run:/)
        end

        it "rejects an empty chain (a dead binding)" do
          expect do
            Class.new do
              include Phlex::Reactive::Component

              def self.name = "EmptyRun"
              reactive_on_complete if: { a: "1" }, run: Phlex::Reactive::JS.new
            end
          end.to raise_error(ArgumentError, /no ops/)
        end

        it "re-validates a raw op list through the attr allowlist (escape hatch can't bypass)" do
          expect do
            Class.new do
              include Phlex::Reactive::Component

              def self.name = "HostileRun"
              reactive_on_complete if: { a: "1" },
                run: [["set_attr", { "to" => "#x", "name" => "onclick", "value" => "x" }]]
            end
          end.to raise_error(ArgumentError, /onclick/)
        end

        it "requires conditions (the ShowConditions kwargs)" do
          expect do
            Class.new do
              include Phlex::Reactive::Component

              def self.name = "NoConditions"
              reactive_on_complete run: Phlex::Reactive::JS.new.submit
            end
          end.to raise_error(ArgumentError, /if:, if_any:, or unless:/)
        end
      end

      describe "wire emission (reactive_attrs)" do
        it "rides the root as ONE data-reactive-on-complete JSON attr" do
          attrs = complete_klass.new.send(:reactive_attrs)
          payload = JSON.parse(attrs[:data][:reactive_on_complete])

          expect(payload).to eq([{
            "any" => [[{ "field" => "code", "len_eq" => 6 }]],
            "ops" => [["dispatch", { "name" => "code:complete", "to" => "@root", "detail" => {} }]]
          }])
        end

        it "emits nothing when undeclared (byte-stable wire)" do
          attrs = state_klass.new.send(:reactive_attrs)
          expect(attrs[:data]).not_to have_key(:reactive_on_complete)
        end
      end
    end

    # The wire emission the root's compute binding produces (issue #183 moved it
    # from reactive_compute_attrs into the private compute_binding helper that
    # reactive_root(compute:) calls).
    describe "#compute_binding (root compute descriptors)" do
      subject(:instance) { compute_klass.new }

      it "emits the reducer key and the input/output field names as data attrs" do
        attrs = instance.send(:compute_binding, :payment_split)
        expect(attrs[:data][:reactive_compute_reducer_param]).to eq("payment_split")
        expect(JSON.parse(attrs[:data][:reactive_compute_inputs_param])).to eq(%w[allowance cash leasing total])
        expect(JSON.parse(attrs[:data][:reactive_compute_outputs_param])).to eq(%w[allowance cash leasing])
      end

      it "carries the recompute action descriptor" do
        attrs = instance.send(:compute_binding, :payment_split)
        expect(attrs[:data][:action]).to eq("input->reactive#recompute")
      end

      it "raises for an undeclared compute (fail fast, not a silent no-op)" do
        expect { instance.send(:compute_binding, :nope) }
          .to raise_error(Phlex::Reactive::Error, /reactive_compute/)
      end
    end

    # Issue #104: typed inputs. The ARRAY form must stay byte-identical on the
    # wire (a JSON ARRAY, numeric coercion on the client). The HASH form declares
    # a per-input type and emits a JSON OBJECT ({"title":"string","qty":"number"})
    # so the client reads a :string input raw and coerces a :number through Number.
    describe "typed inputs (issue #104)" do
      let(:typed_klass) do
        Class.new do
          include Phlex::Reactive::Component

          def self.name = "TypedCompute"

          reactive_compute :preview,
            inputs: { title: :string, qty: :number },
            outputs: %i[title_preview char_count]
        end
      end

      it "keeps the ARRAY form's inputs param a byte-identical JSON array" do
        # The exact serialized string the client parses — pinned so the typed-
        # inputs change can never silently alter the shipped array-form wire.
        attrs = compute_klass.new.send(:compute_binding, :payment_split)
        expect(attrs[:data][:reactive_compute_inputs_param])
          .to eq('["allowance","cash","leasing","total"]')
      end

      it "captures the input names in declaration order" do
        expect(typed_klass.reactive_computes[:preview].inputs).to eq(%i[title qty])
      end

      it "captures the per-input types keyed by name" do
        expect(typed_klass.reactive_computes[:preview].input_types)
          .to eq(title: :string, qty: :number)
      end

      it "reports nil input_types for the array form (untyped, numeric)" do
        expect(compute_klass.reactive_computes[:payment_split].input_types).to be_nil
      end

      it "emits the HASH form's inputs param as a JSON object of name→type" do
        attrs = typed_klass.new.send(:compute_binding, :preview)
        expect(JSON.parse(attrs[:data][:reactive_compute_inputs_param]))
          .to eq("title" => "string", "qty" => "number")
      end

      it "still emits the outputs param as a JSON array for the hash form" do
        attrs = typed_klass.new.send(:compute_binding, :preview)
        expect(JSON.parse(attrs[:data][:reactive_compute_outputs_param]))
          .to eq(%w[title_preview char_count])
      end
    end

    # Issue #262: :boolean is a CLIENT-side coercion (a checkbox's checked state as
    # a real boolean), so the server's whole job is to carry the type onto the wire
    # under the name the client branches on.
    describe "a :boolean input (issue #262)" do
      let(:boolean_klass) do
        Class.new do
          include Phlex::Reactive::Component

          def self.name = "BooleanCompute"

          reactive_compute :total, inputs: [:price, { gift: :boolean }], outputs: %i[total]
        end
      end

      it "captures the type keyed by name" do
        expect(boolean_klass.reactive_computes[:total].input_types).to eq(price: :number, gift: :boolean)
      end

      it "emits it on the inputs param wire" do
        attrs = boolean_klass.new.send(:compute_binding, :total)
        expect(JSON.parse(attrs[:data][:reactive_compute_inputs_param]))
          .to eq("price" => "number", "gift" => "boolean")
      end
    end

    # Issue #183: the PERMIT shape unifies the array and hash dialects. Bare
    # symbols default to :number; a trailing Hash types the exceptions. Both old
    # dialects are degenerate cases of this one form (a pure array = all bare; a
    # pure hash arrives as one trailing Hash with no bare names).
    describe "permit-style inputs (issue #183)" do
      let(:permit_klass) do
        Class.new do
          include Phlex::Reactive::Component

          def self.name = "PermitCompute"

          reactive_compute :preview, inputs: [:qty, { title: :string }], outputs: %i[char_count]
        end
      end

      it "types a bare symbol as :number (the default)" do
        expect(permit_klass.reactive_computes[:preview].input_types[:qty]).to eq(:number)
      end

      it "types a trailing-hash exception as declared" do
        expect(permit_klass.reactive_computes[:preview].input_types[:title]).to eq(:string)
      end

      it "captures the input names in declaration order (bare first, then hash keys)" do
        expect(permit_klass.reactive_computes[:preview].inputs).to eq(%i[qty title])
      end

      it "emits the mixed inputs as a JSON object of name→type" do
        attrs = permit_klass.new.send(:compute_binding, :preview)
        expect(JSON.parse(attrs[:data][:reactive_compute_inputs_param]))
          .to eq("qty" => "number", "title" => "string")
      end

      it "keeps a pure bare-symbol array untyped (byte-identical array wire)" do
        klass = Class.new do
          include Phlex::Reactive::Component

          def self.name = "BareArrayCompute"
          reactive_compute :t, inputs: %i[price qty], outputs: %i[total]
        end
        attrs = klass.new.send(:compute_binding, :t)
        expect(attrs[:data][:reactive_compute_inputs_param]).to eq('["price","qty"]')
      end

      it "does NOT mutate or raise on a frozen/shared inputs array (dup before pop)" do
        frozen_inputs = [:qty, { title: :string }].freeze
        expect do
          Class.new do
            include Phlex::Reactive::Component

            def self.name = "FrozenInputsCompute"
          end.reactive_compute(:preview, inputs: frozen_inputs, outputs: %i[char_count])
        end.not_to raise_error
        # The caller's array is untouched (the trailing Hash is still there).
        expect(frozen_inputs).to eq([:qty, { title: :string }])
      end
    end

    # Issue #159: cross-root text mirrors. `mirror:` declares an ALLOWLISTED map
    # from a compute name to document-wide id selector(s) painted via textContent
    # — the declared escape from root isolation (issue #15) for a derived value
    # shown in a recap OUTSIDE the computing root. Id selectors only (two-sided
    # default-deny with the client interpreter); the wire is byte-identical when
    # no mirror is declared.
    describe "cross-root mirrors (mirror:, issue #159)" do
      let(:mirror_klass) do
        Class.new do
          include Phlex::Reactive::Component

          def self.name = "MirrorCompute"

          reactive_compute :split,
            inputs: %i[a b total],
            outputs: %i[a b],
            mirror: { sum_a: "#sum_a", sum_total: ["#sum_total", "#footer-total"] }
        end
      end

      it "captures the mirror map normalized to name → array of id selectors" do
        expect(mirror_klass.reactive_computes[:split].mirror)
          .to eq(sum_a: ["#sum_a"], sum_total: ["#sum_total", "#footer-total"])
      end

      it "reports nil mirror when undeclared" do
        expect(compute_klass.reactive_computes[:payment_split].mirror).to be_nil
      end

      # Issue #186: reactive_compute with no inputs:/outputs: now always hits the
      # removed-bare-getter guard first (that overload collision predates mirror:
      # validation), so mirror: alone can never reach normalize_compute_mirror —
      # the call still fails loudly, just via the getter-removed message.
      it "rejects mirror: on the bare GETTER form LOUDLY (never silently drops it)" do
        expect do
          Class.new do
            include Phlex::Reactive::Component

            def self.name = "MirrorOnly"
            reactive_compute :split, mirror: { sum: "#sum" }
          end
        end.to raise_error(ArgumentError, /reactive_compute\(:split\).*removed in issue #186/m)
      end

      it "rejects a non-id selector LOUDLY at declare time (class, attribute, *, compound)" do
        # rubocop:disable-next Style/ItBlockParameter -- `bad` is read inside the nested Class.new block, where `it` would rebind
        [".totals", "[data-x]", "*", "div#x", "#x .y", "#x,#y"].each do |bad|
          expect do
            Class.new do
              include Phlex::Reactive::Component

              def self.name = "BadMirror"
              reactive_compute :split, inputs: %i[a], outputs: %i[b], mirror: { sum: bad }
            end
          end.to raise_error(ArgumentError, /id selector/i), "expected #{bad.inspect} to be refused"
        end
      end

      it "emits the mirror map as a JSON object of name → [ids] on the root attrs" do
        attrs = mirror_klass.new.send(:compute_binding, :split)
        expect(JSON.parse(attrs[:data][:reactive_compute_mirror_param]))
          .to eq("sum_a" => ["#sum_a"], "sum_total" => ["#sum_total", "#footer-total"])
      end

      it "emits NO mirror param when undeclared (the wire stays byte-identical)" do
        attrs = compute_klass.new.send(:compute_binding, :payment_split)
        expect(attrs[:data]).not_to have_key(:reactive_compute_mirror_param)
      end
    end
  end

  # Issue #104: reactive_text mirrors a field into a TEXT NODE (live preview,
  # char counter, "Hello, {name}") — the text sibling of reactive_field. It
  # carries NO `name` attribute, so #collectFields never sweeps it into params.
  describe "#reactive_text (text-node mirror, issue #104)" do
    let(:text_klass) do
      Class.new(Phlex::HTML) do
        include Phlex::Reactive::Component

        def self.name = "TextMirror"

        def view_template
          reactive_text(:title_preview, "Hello")
        end
      end
    end

    let(:empty_klass) do
      Class.new(Phlex::HTML) do
        include Phlex::Reactive::Component

        def self.name = "EmptyTextMirror"

        def view_template
          reactive_text(:char_count)
        end
      end
    end

    it "renders a span carrying data-reactive-text=<name> with the initial content" do
      html = text_klass.new.call
      expect(html).to include('data-reactive-text="title_preview"')
      expect(html).to include(">Hello</span>")
    end

    it "renders an empty span when no initial value is given" do
      html = empty_klass.new.call
      expect(html).to include('data-reactive-text="char_count"')
      expect(html).to match(%r{<span[^>]*data-reactive-text="char_count"[^>]*></span>})
    end

    it "carries NO name attribute (so it is never collected/POSTed as a param)" do
      expect(text_klass.new.call).not_to include("name=")
    end

    # Issue #183: reactive_text(:name) with NO explicit initial seeds its first
    # paint from reactive_values (Phase A) when that key is covered — so the server
    # render matches what the reducer would paint, with no hand-passed seed.
    describe "first-paint seeding from reactive_values (issue #183)" do
      let(:seeded_klass) do
        Class.new(Phlex::HTML) do
          include Phlex::Reactive::Component

          def self.name = "SeededTextMirror"

          def reactive_values = { char_count: 42, greeting: "Hi Ada" }

          def view_template
            reactive_text(:char_count)
            reactive_text(:greeting)
          end
        end
      end

      it "seeds the span from reactive_values when no explicit initial is given" do
        html = seeded_klass.new.call
        expect(html).to include('data-reactive-text="char_count"')
        expect(html).to include(">42</span>")
        expect(html).to include(">Hi Ada</span>")
      end

      it "an explicit initial still wins over reactive_values" do
        klass = Class.new(Phlex::HTML) do
          include Phlex::Reactive::Component

          def self.name = "ExplicitWins"
          def reactive_values = { char_count: 42 }
          def view_template = reactive_text(:char_count, 7)
        end
        expect(klass.new.call).to include(">7</span>")
      end

      it "renders empty for a name reactive_values does not cover" do
        klass = Class.new(Phlex::HTML) do
          include Phlex::Reactive::Component

          def self.name = "PartialValues"
          def reactive_values = { other: 1 }
          def view_template = reactive_text(:char_count)
        end
        expect(klass.new.call).to match(%r{<span[^>]*data-reactive-text="char_count"[^>]*></span>})
      end
    end
  end

  # Issue #180 Phase A: reactive_scope — a class-level form namespace so bindings
  # and reactive_values use bare symbols. The root emits data-reactive-scope so
  # the client resolves [name="form[field]"]. Inherited through the Registry.
  describe "#reactive_scope (issue #180)" do
    it "emits data-reactive-scope on the reactive root when declared" do
      klass = Class.new(Phlex::HTML) do
        include Phlex::Reactive::Component

        def self.name = "ScopedThing"
        reactive_scope :form
        reactive_state :count
        def initialize(count: 0) = @count = count
        def id = "scoped-thing"
      end
      attrs = klass.new.send(:reactive_root)
      expect(attrs[:data][:reactive_scope]).to eq("form")
    end

    it "omits the attr entirely when no scope is declared (byte-stable wire)" do
      klass = Class.new(Phlex::HTML) do
        include Phlex::Reactive::Component

        def self.name = "UnscopedThing"
        reactive_state :count
        def initialize(count: 0) = @count = count
        def id = "unscoped-thing"
      end
      expect(klass.new.send(:reactive_root)[:data]).not_to have_key(:reactive_scope)
    end

    it "is inherited by subclasses" do
      parent = Class.new(Phlex::HTML) do
        include Phlex::Reactive::Component

        def self.name = "ScopedParent"
        reactive_scope :order
      end
      child = Class.new(parent) { def self.name = "ScopedChild" }
      expect(child.reactive_scope).to eq(:order)
    end

    # Issue #184: the scope unwraps ONE level at the endpoint, so a schema ALREADY
    # nested under the scope key would be double-unwrapped (dead). Raise a guided
    # error from whichever macro completes the pair — regardless of declaration
    # order, so it can't be dodged by declaring the action before the scope.
    describe "double-nesting guard (issue #184)" do
      it "raises when the action declares a schema nested under the scope key (scope first)" do
        expect do
          Class.new(Phlex::HTML) do
            include Phlex::Reactive::Component

            def self.name = "NestedSchemaScopeFirst"
            reactive_scope :invoice
            action :save, params: { invoice: { date: :string } }
          end
        end.to raise_error(ArgumentError, /reactive_scope|nested|invoice/)
      end

      it "raises when the scope is declared AFTER the nested action (action first)" do
        expect do
          Class.new(Phlex::HTML) do
            include Phlex::Reactive::Component

            def self.name = "NestedSchemaActionFirst"
            action :save, params: { invoice: { date: :string } }
            reactive_scope :invoice
          end
        end.to raise_error(ArgumentError, /reactive_scope|nested|invoice/)
      end

      it "allows a nested schema whose key is NOT the scope (a real nested param)" do
        expect do
          Class.new(Phlex::HTML) do
            include Phlex::Reactive::Component

            def self.name = "RealNestedUnderScope"
            reactive_scope :invoice
            action :save, params: { address: { street: :string } } # nested_attributes, not the scope
          end
        end.not_to raise_error
      end
    end
  end

  # Issue #180 Phase A: reactive_show — value-conditional visibility, now driven
  # by ONE Ruby-native conditions language (if:/if_any:/unless:) that compiles to
  # a DNF wire attr (data-reactive-show). A Hash is an AND; an Array is
  # membership; a Range is a threshold; unless: negates. reactive_values computes
  # the first-paint hidden: server-side; reactive_scope resolves bare field names
  # to form[field]; disable: also disables owned controls when hidden. The old
  # positional/predicate-kwarg surface (equals:/not:/in:/gte:/all:/any:) is
  # removed — each raises a guided ArgumentError printing the new syntax.
  describe "#reactive_show (conditions language, issue #180)" do
    subject(:instance) { show_klass.new }

    let(:show_klass) do
      Class.new(Phlex::HTML) do
        include Phlex::Reactive::Component

        def self.name = "ShowThing"

        reactive_state :count
        def initialize(count: 0) = @count = count
      end
    end

    # The compiled DNF groups off the emitted attr.
    def dnf(attrs)
      JSON.parse(attrs[:data][:reactive_show]).fetch("any")
    end

    it "emits an if: hash as one DNF group of equals terms" do
      attrs = instance.send(:reactive_show, if: { type: "individual" })
      expect(dnf(attrs)).to eq([[{ "field" => "type", "equals" => "individual" }]])
    end

    it "ANDs multiple fields within one if: group" do
      attrs = instance.send(:reactive_show, if: { type: "individual", country: "domestic" })
      expect(dnf(attrs)).to eq([[
        { "field" => "type", "equals" => "individual" },
        { "field" => "country", "equals" => "domestic" }
      ]])
    end

    it "emits if_any: as OR-of-AND groups (the distributive-law killer)" do
      attrs = instance.send(:reactive_show, if_any: [
        { director: true },
        { shareholder: true, role: "individual" }
      ])
      expect(dnf(attrs)).to eq([
        [{ "field" => "director", "equals" => "true" }],
        [{ "field" => "shareholder", "equals" => "true" }, { "field" => "role", "equals" => "individual" }]
      ])
    end

    it "maps Array to membership and Range to threshold terms" do
      attrs = instance.send(:reactive_show, if: { size: %w[l xl], quantity: 10.. })
      expect(dnf(attrs)).to eq([[
        { "field" => "size", "in" => %w[l xl] },
        { "field" => "quantity", "gte" => 10 }
      ]])
    end

    it "composes unless: as negated terms ANDed into the group" do
      attrs = instance.send(:reactive_show, if: { shareholder: true }, unless: { director: true })
      expect(dnf(attrs)).to eq([[
        { "field" => "shareholder", "equals" => "true" },
        { "field" => "director", "not" => "true" }
      ]])
    end

    it "deep-merges extra HTML attrs (conditions live in if:, so no ambiguity)" do
      attrs = instance.send(:reactive_show, if: { size: %w[l xl] }, class: "note", data: { testid: "s" })
      expect(attrs[:class]).to eq("note")
      expect(attrs[:data][:testid]).to eq("s")
      expect(dnf(attrs)).to eq([[{ "field" => "size", "in" => %w[l xl] }]])
    end

    describe "first-paint hidden: from reactive_values" do
      let(:show_klass) do
        Class.new(Phlex::HTML) do
          include Phlex::Reactive::Component

          def self.name = "ValuesThing"

          def initialize(director: false, role: "company")
            @director = director
            @role = role
          end

          def reactive_values = { director: @director, role: @role }
        end
      end

      it "computes hidden: true server-side when the predicate is false" do
        attrs = show_klass.new(director: false, role: "company")
          .send(:reactive_show, if: { director: true })
        expect(attrs[:hidden]).to be(true)
      end

      it "computes hidden: false (absent) when the predicate is true" do
        attrs = show_klass.new(director: true)
          .send(:reactive_show, if: { director: true })
        expect(attrs[:hidden]).to be(false)
      end

      it "evaluates an OR-of-AND against reactive_values" do
        # role individual but not director → second group matches → visible
        attrs = show_klass.new(director: false, role: "individual")
          .send(:reactive_show, if_any: [{ director: true }, { role: "individual" }])
        expect(attrs[:hidden]).to be(false)
      end

      it "does not compute hidden: when a referenced field is not in reactive_values" do
        attrs = show_klass.new.send(:reactive_show, if: { unknown_field: "x" })
        expect(attrs).not_to have_key(:hidden)
      end

      it "lets an explicit hidden: win over the computed value" do
        attrs = show_klass.new(director: true)
          .send(:reactive_show, if: { director: true }, hidden: true)
        expect(attrs[:hidden]).to be(true)
      end

      it "merges a per-call values: override with reactive_values" do
        attrs = show_klass.new(director: false)
          .send(:reactive_show, if: { director: true }, values: { director: true })
        expect(attrs[:hidden]).to be(false)
      end
    end

    describe "disable: — hidden controls stop submitting" do
      it "stamps the disable flag so the client toggles disabled with hidden" do
        attrs = instance.send(:reactive_show, if: { role: "individual" }, disable: true)
        expect(attrs[:data][:reactive_show_disable]).to eq("true")
      end

      it "omits the flag by default (byte-stable wire)" do
        attrs = instance.send(:reactive_show, if: { role: "individual" })
        expect(attrs[:data]).not_to have_key(:reactive_show_disable)
      end
    end

    describe "loud validation" do
      it "raises with no condition" do
        expect { instance.send(:reactive_show, class: "x") }
          .to raise_error(ArgumentError, /needs if:, if_any:, or unless:/)
      end

      it "raises on if: and if_any: together" do
        expect { instance.send(:reactive_show, if: { a: 1 }, if_any: [{ b: 2 }]) }
          .to raise_error(ArgumentError, %r{exactly one of if:/if_any:})
      end

      it "raises on an empty Array value" do
        expect { instance.send(:reactive_show, if: { size: [] }) }
          .to raise_error(ArgumentError, /needs at least one value/)
      end
    end

    describe "guided errors for the removed 0.9.5 surface" do
      it "guides a positional field + predicate to the keyword conditions form" do
        # A positional field is caught first (it's the most visible legacy shape).
        expect { instance.send(:reactive_show, :mode, equals: "off") }
          .to raise_error(ArgumentError, /no longer takes a positional field.*if: \{ mode:/m)
      end

      it "guides bare predicate kwargs (no positional) to if:/unless:/Array/Range" do
        expect { instance.send(:reactive_show, equals: "off") }
          .to raise_error(ArgumentError, /equals: .* was removed.*if: \{ field: value \}/m)
        expect { instance.send(:reactive_show, in: %w[l xl]) }
          .to raise_error(ArgumentError, /in: → an Array value/m)
        expect { instance.send(:reactive_show, gte: 10) }
          .to raise_error(ArgumentError, /gte:.*Range value/m)
      end

      it "guides all:/any: to if:/if_any:" do
        expect { instance.send(:reactive_show, all: [{ field: :a, equals: "x" }]) }
          .to raise_error(ArgumentError, /if:|removed/m)
        expect { instance.send(:reactive_show, any: [{ field: :a, equals: "x" }]) }
          .to raise_error(ArgumentError, /if_any:|removed/m)
      end
    end

    it "renders the wire attribute onto the element" do
      klass = Class.new(Phlex::HTML) do
        include Phlex::Reactive::Component

        def self.name = "ShowRender"

        def view_template
          div(**reactive_show(if: { mode: "on" }), id: "details") { "d" }
        end
      end

      html = klass.new.call
      expect(html).to include("data-reactive-show=")
      expect(html).to include("&quot;mode&quot;")
    end
  end

  # Issue #163: reactive_filter — client-side option filtering for the
  # searchable combobox. The ROOT declares which input drives the filter and
  # which elements are the options (plus optional group/empty selectors); the
  # client shows/hides options by their data-reactive-filter-text haystack on
  # every input — no round trip, no bespoke per-feature controller. Validation
  # is loud at render time: blank selectors are dead bindings.
  # Issue #186: reactive_filter names the FIELD that drives the filter, not four
  # selectors. `reactive_filter(:q)` compiles `:q` to [name="q"] (scope-aware) for
  # the input, defaults option to the [role=option] convention, and leaves
  # group/empty opt-in. The client wire (selectors) is unchanged — a server-only
  # compile. Issue #224 re-blesses input: as the ESCAPE HATCH (a raw CSS
  # selector) for the one case the field form can't express: a deliberately
  # name-less query input inside a real POST form, targeted by id.
  describe "#reactive_filter (field-driven, issue #186)" do
    subject(:instance) { filter_klass.new }

    let(:filter_klass) do
      Class.new(Phlex::HTML) do
        include Phlex::Reactive::Streamable
        include Phlex::Reactive::Component

        def self.name = "FilterThing"
      end
    end

    it "compiles the field name to a [name=…] input selector + the option convention" do
      attrs = instance.send(:reactive_filter, :q)
      expect(attrs[:data][:reactive_filter_input]).to eq('[name="q"]')
      expect(attrs[:data][:reactive_filter_option]).to eq("[role=option]")
    end

    it "scope-prefixes the field name under reactive_scope" do
      scoped = Class.new(Phlex::HTML) do
        include Phlex::Reactive::Streamable
        include Phlex::Reactive::Component

        def self.name = "ScopedFilter"
        reactive_scope :form
      end
      attrs = scoped.new.send(:reactive_filter, :q)
      expect(attrs[:data][:reactive_filter_input]).to eq('[name="form[q]"]')
    end

    it "leaves group/empty opt-in (byte-stable wire — omitted by default)" do
      attrs = instance.send(:reactive_filter, :q)
      expect(attrs[:data]).not_to have_key(:reactive_filter_group)
      expect(attrs[:data]).not_to have_key(:reactive_filter_empty)
    end

    it "accepts kwarg overrides for option/group/empty" do
      attrs = instance.send(:reactive_filter, :q,
        option: ".opt", group: "[data-filter-group]", empty: "#no-matches")
      expect(attrs[:data][:reactive_filter_option]).to eq(".opt")
      expect(attrs[:data][:reactive_filter_group]).to eq("[data-filter-group]")
      expect(attrs[:data][:reactive_filter_empty]).to eq("#no-matches")
    end

    # Issue #224: input: returns as the ESCAPE HATCH — a raw CSS selector for
    # an instance-dynamic driving input the field form can't express: a form
    # builder's NAME-LESS query input (a named input inside a real POST form
    # would submit a stray param), targeted by id. The field form stays the
    # blessed default; exactly one of the two forms per call.
    context "with the input: escape hatch (issue #224)" do
      it "emits the selector verbatim (+ the option convention)" do
        attrs = instance.send(:reactive_filter, input: "#tags_query")
        expect(attrs[:data][:reactive_filter_input]).to eq("#tags_query")
        expect(attrs[:data][:reactive_filter_option]).to eq("[role=option]")
      end

      it "never re-scopes the selector under reactive_scope" do
        scoped = Class.new(Phlex::HTML) do
          include Phlex::Reactive::Streamable
          include Phlex::Reactive::Component

          def self.name = "ScopedFilterEscape"
          reactive_scope :form
        end
        attrs = scoped.new.send(:reactive_filter, input: "#tags_query")
        expect(attrs[:data][:reactive_filter_input]).to eq("#tags_query")
      end

      it "composes with the option/group/empty kwargs" do
        attrs = instance.send(:reactive_filter, input: "#q", option: ".opt", empty: "#none")
        expect(attrs[:data][:reactive_filter_option]).to eq(".opt")
        expect(attrs[:data][:reactive_filter_empty]).to eq("#none")
      end

      it "raises on a blank selector (a dead binding must fail at render)" do
        expect { instance.send(:reactive_filter, input: " ") }
          .to raise_error(ArgumentError, /input:/)
      end

      it "raises on a boolean selector (the input: cond && \"#sel\" idiom must fail loudly)" do
        expect { instance.send(:reactive_filter, input: false) }
          .to raise_error(ArgumentError, /CSS selector/)
      end

      it "raises when BOTH a field and input: are given (one driving-input form per call)" do
        expect { instance.send(:reactive_filter, :q, input: "#q") }
          .to raise_error(ArgumentError, /not both/)
      end

      it "raises when NEITHER a field nor input: is given" do
        expect { instance.send(:reactive_filter) }
          .to raise_error(ArgumentError, /field name|input:/)
      end
    end

    it "raises on a blank option override" do
      expect { instance.send(:reactive_filter, :q, option: " ") }
        .to raise_error(ArgumentError, /option:/)
    end

    it "renders the compiled wire attributes onto the root element" do
      klass = Class.new(Phlex::HTML) do
        include Phlex::Reactive::Component

        def self.name = "FilterRender"

        def view_template
          div(**reactive_filter(:q, empty: "#none"), id: "combo") { "c" }
        end
      end

      html = klass.new.call
      expect(html).to include('data-reactive-filter-input="[name=&quot;q&quot;]"')
      expect(html).to include('data-reactive-filter-option="[role=option]"')
      expect(html).to include('data-reactive-filter-empty="#none"')
    end
  end

  # Issue #163 (the compose half): reactive_listnav — the STANDALONE keyboard-nav
  # wiring for an input that fires no action. on(..., listnav:) requires a
  # declared action (a POST per keystroke); a preload-and-filter combobox input
  # is pure client, so it needs the same Arrow/Enter/Escape wiring without the
  # dispatch descriptor.
  describe "#reactive_listnav (standalone keyboard nav, issue #163)" do
    subject(:instance) { state_klass.new }

    it "emits ONLY the listnav keyboard actions (no dispatch — no POST)" do
      attrs = instance.send(:reactive_listnav, "[role=option]")
      expect(attrs[:data][:action]).to eq(
        "keydown.down->reactive#listnavNext " \
        "keydown.up->reactive#listnavPrev " \
        "keydown.enter->reactive#listnavPick " \
        "keydown.esc->reactive#listnavClose"
      )
      expect(attrs[:data][:action]).not_to include("reactive#dispatch")
    end

    it "emits the option selector as the same Stimulus param on() uses" do
      attrs = instance.send(:reactive_listnav, "[role=option]")
      expect(attrs[:data][:reactive_listnav_option_param]).to eq("[role=option]")
    end

    it "raises on a blank selector (a dead binding must fail at render)" do
      expect { instance.send(:reactive_listnav, "") }.to raise_error(ArgumentError, /selector/)
    end

    it "deep-merges with extra attrs via mix (data-action survives)" do
      # mix is Phlex::HTML's (render-context-free) helper, so this example needs
      # a Phlex-based component — state_klass is a plain class.
      phlex_instance = Class.new(Phlex::HTML) do
        include Phlex::Reactive::Component

        def self.name = "ListnavMix"
      end.new

      attrs = phlex_instance.instance_eval do
        mix(reactive_listnav("[role=option]"), data: { testid: "q" })
      end
      expect(attrs[:data][:action]).to include("reactive#listnavNext")
      expect(attrs[:data][:testid]).to eq("q")
    end
  end

  # Issue #203: reactive_tags — the tag-chip input primitive. The ROOT names the
  # hidden field that stores the comma-joined value (scope-aware, like
  # reactive_filter's field compile); the query input carries the Enter-to-add
  # trigger; each option/remove button is a CLIENT-ONLY trigger (tagsPick/
  # tagsRemove — form state, no POST). Validation is loud at render: a blank
  # field is a dead binding, and a declared tag containing a comma would corrupt
  # the comma-joined value.
  describe "#reactive_tags (tag-chip input, issue #203)" do
    subject(:instance) { tags_klass.new }

    let(:tags_klass) do
      Class.new(Phlex::HTML) do
        include Phlex::Reactive::Streamable
        include Phlex::Reactive::Component

        def self.name = "TagsThing"
      end
    end

    it "compiles the field name to a [name=…] selector for the hidden value store" do
      attrs = instance.send(:reactive_tags, :tags)
      expect(attrs[:data][:reactive_tags_field]).to eq('[name="tags"]')
    end

    it "scope-prefixes the field name under reactive_scope" do
      scoped = Class.new(Phlex::HTML) do
        include Phlex::Reactive::Streamable
        include Phlex::Reactive::Component

        def self.name = "ScopedTags"
        reactive_scope :post
      end
      attrs = scoped.new.send(:reactive_tags, :tags)
      expect(attrs[:data][:reactive_tags_field]).to eq('[name="post[tags]"]')
    end

    it "raises on a missing field name (a dead binding must fail at render)" do
      expect { instance.send(:reactive_tags) }
        .to raise_error(ArgumentError, /field name/)
    end

    it "is available to a ClientBindings (token-less) component" do
      client_only = Class.new(Phlex::HTML) do
        include Phlex::Reactive::ClientBindings

        def self.name = "ClientOnlyTags"
      end
      attrs = client_only.new.send(:reactive_tags, :tags)
      expect(attrs[:data][:reactive_tags_field]).to eq('[name="tags"]')
    end

    # Issue #224: name: is the ESCAPE HATCH for an instance-dynamic wire name —
    # a form builder computes "user[tags]" per instance, which the class-level
    # reactive_scope compile can't express. Verbatim, never re-scoped; the same
    # fail-at-render posture as the field form (reactive_field's explicit-name
    # precedent).
    context "with the name: escape hatch (issue #224)" do
      it "compiles the verbatim wire name to a [name=…] selector" do
        attrs = instance.send(:reactive_tags, name: "user[tags]")
        expect(attrs[:data][:reactive_tags_field]).to eq('[name="user[tags]"]')
      end

      it "never re-scopes the name under reactive_scope" do
        scoped = Class.new(Phlex::HTML) do
          include Phlex::Reactive::Streamable
          include Phlex::Reactive::Component

          def self.name = "ScopedTagsEscape"
          reactive_scope :post
        end
        attrs = scoped.new.send(:reactive_tags, name: "user[tags]")
        expect(attrs[:data][:reactive_tags_field]).to eq('[name="user[tags]"]')
      end

      it "raises on a blank name: (a dead binding must fail at render)" do
        expect { instance.send(:reactive_tags, name: " ") }
          .to raise_error(ArgumentError, /name:/)
      end

      it "raises on a name containing a double quote (would corrupt the compiled selector)" do
        expect { instance.send(:reactive_tags, name: 'user["tags"]') }
          .to raise_error(ArgumentError, /double quote/)
      end

      it "raises on a backslash (CSS-escapes through querySelectorAll — the selector would mismatch)" do
        expect { instance.send(:reactive_tags, name: "user[tags]\\") }
          .to raise_error(ArgumentError, /backslash/)
      end

      it "raises on a control character (querySelectorAll THROWS on a raw newline in a CSS string)" do
        expect { instance.send(:reactive_tags, name: "user\n[tags]") }
          .to raise_error(ArgumentError, /control/)
      end

      it "raises on a boolean name: (the name: cond && \"user[tags]\" idiom must fail loudly)" do
        expect { instance.send(:reactive_tags, name: false) }
          .to raise_error(ArgumentError, /name:/)
      end

      it "raises when BOTH a field and name: are given (one field form per call)" do
        expect { instance.send(:reactive_tags, :tags, name: "user[tags]") }
          .to raise_error(ArgumentError, /not both/)
      end
    end

    describe "#reactive_tags_add (the Enter-to-add trigger)" do
      it "emits ONLY the tagsAdd keyboard action (no dispatch — no POST)" do
        attrs = instance.send(:reactive_tags_add)
        expect(attrs[:data][:action]).to eq("keydown.enter->reactive#tagsAdd")
      end

      it "composes AFTER reactive_listnav via mix so Enter prefers the highlighted option" do
        attrs = instance.instance_eval do
          mix(reactive_listnav, reactive_tags_add)
        end
        expect(attrs[:data][:action]).to eq(
          "keydown.down->reactive#listnavNext " \
          "keydown.up->reactive#listnavPrev " \
          "keydown.enter->reactive#listnavPick " \
          "keydown.esc->reactive#listnavClose " \
          "keydown.enter->reactive#tagsAdd"
        )
      end
    end

    describe "#reactive_tags_option (a click-to-add option row)" do
      it "emits the option convention + the client-only pick trigger + the tag value" do
        attrs = instance.send(:reactive_tags_option, "Ruby")
        expect(attrs[:role]).to eq("option")
        expect(attrs[:type]).to eq("button")
        expect(attrs[:data][:action]).to eq("click->reactive#tagsPick")
        expect(attrs[:data][:reactive_tag_param]).to eq("Ruby")
      end

      it "raises on a blank tag" do
        expect { instance.send(:reactive_tags_option, " ") }
          .to raise_error(ArgumentError, /non-blank/)
      end

      it "raises on a tag containing a comma (would corrupt the comma-joined value)" do
        expect { instance.send(:reactive_tags_option, "a,b") }
          .to raise_error(ArgumentError, /comma/)
      end
    end

    describe "#reactive_tags_remove (a chip's remove button)" do
      it "emits the client-only remove trigger with the tag for a server-rendered chip" do
        attrs = instance.send(:reactive_tags_remove, "Ruby")
        expect(attrs[:type]).to eq("button")
        expect(attrs[:data][:action]).to eq("click->reactive#tagsRemove")
        expect(attrs[:data][:reactive_tag_param]).to eq("Ruby")
      end

      it "omits the tag param for the template form (the client fills it per chip)" do
        attrs = instance.send(:reactive_tags_remove)
        expect(attrs[:data][:action]).to eq("click->reactive#tagsRemove")
        expect(attrs[:data]).not_to have_key(:reactive_tag_param)
      end

      it "raises on a tag containing a comma" do
        expect { instance.send(:reactive_tags_remove, "a,b") }
          .to raise_error(ArgumentError, /comma/)
      end
    end

    it "renders the compiled wire attributes onto the root element" do
      klass = Class.new(Phlex::HTML) do
        include Phlex::Reactive::Component

        def self.name = "TagsRender"

        def view_template
          div(**reactive_tags(:tags), id: "tags-root") { "t" }
        end
      end

      html = klass.new.call
      expect(html).to include('data-reactive-tags-field="[name=&quot;tags&quot;]"')
    end
  end

  # Issue #208: reactive_nested_* — the draft nested-attributes row primitive.
  # A "new parent + child rows" form builds its rows CLIENT-SIDE (template
  # clone, no POST, no persisted parent needed); the surrounding REAL form
  # submit carries Rails' accepts_nested_attributes_for names and the server
  # reconciles in one create. The row markup is authored ONCE (the template)
  # and reused for server-rendered rows via nested_field_name(index:).
  describe "#reactive_nested_* (draft nested-attribute rows, issue #208)" do
    subject(:instance) { nested_klass.new }

    let(:nested_klass) do
      Class.new(Phlex::HTML) do
        include Phlex::Reactive::Component

        def self.name = "NestedThing"
      end
    end

    describe "#nested_field_name (the Rails nested-attributes wire name)" do
      it "builds the placeholder name for the template row by default" do
        expect(instance.send(:nested_field_name, :line_items, :quantity))
          .to eq("line_items_attributes[NEW_ROW][quantity]")
      end

      it "builds the indexed name for a server-rendered row" do
        expect(instance.send(:nested_field_name, :line_items, :quantity, index: 0))
          .to eq("line_items_attributes[0][quantity]")
      end

      it "scope-prefixes under reactive_scope (the parent form's param root)" do
        scoped = Class.new(Phlex::HTML) do
          include Phlex::Reactive::Component

          def self.name = "ScopedNested"
          reactive_scope :order
        end

        expect(scoped.new.send(:nested_field_name, :line_items, :quantity, index: 3))
          .to eq("order[line_items_attributes][3][quantity]")
      end

      it "raises on an index that is neither an integer nor the placeholder (would corrupt the wire name)" do
        expect { instance.send(:nested_field_name, :line_items, :quantity, index: "x[y]") }
          .to raise_error(ArgumentError, /index/)
      end

      # Issue #224: scope: is the per-call ESCAPE HATCH — a form builder's
      # object name is per-instance ("order", or itself bracketed for a nested
      # fieldset), which the class-level reactive_scope can't express.
      # Verbatim; wins over reactive_scope.
      context "with the scope: escape hatch (issue #224)" do
        it "wraps the name in the per-call scope verbatim" do
          expect(instance.send(:nested_field_name, :line_items, :quantity, scope: "order"))
            .to eq("order[line_items_attributes][NEW_ROW][quantity]")
        end

        it "wins over the class-level reactive_scope" do
          scoped = Class.new(Phlex::HTML) do
            include Phlex::Reactive::Component

            def self.name = "ScopedNestedEscape"
            reactive_scope :invoice
          end

          expect(scoped.new.send(:nested_field_name, :line_items, :quantity, index: 3, scope: "order"))
            .to eq("order[line_items_attributes][3][quantity]")
        end

        it "accepts a bracketed scope (a nested fieldset's object name)" do
          expect(instance.send(:nested_field_name, :line_items, :quantity, scope: "user[profile]"))
            .to eq("user[profile][line_items_attributes][NEW_ROW][quantity]")
        end

        it "raises on a blank scope: (a dead prefix must fail at render)" do
          expect { instance.send(:nested_field_name, :line_items, :quantity, scope: " ") }
            .to raise_error(ArgumentError, /scope:/)
        end

        it "raises on a non-String/Symbol scope: (scope: cond && \"order\" must fail loudly, never \"false[…]\")" do
          expect { instance.send(:nested_field_name, :line_items, :quantity, scope: false) }
            .to raise_error(ArgumentError, /String or Symbol/)
        end
      end
    end

    it "emits the association-keyed list marker" do
      attrs = instance.send(:reactive_nested_list, :line_items)
      expect(attrs[:data][:reactive_nested_list]).to eq("line_items")
    end

    describe "as: :json (serialize the rows into ONE hidden JSON field, issue #208)" do
      it "keeps the plain list marker AND adds the json-mode marker" do
        attrs = instance.send(:reactive_nested_list, :todos, as: :json)
        # The container is still the add/remove target — nestedAdd/Remove key on it.
        expect(attrs[:data][:reactive_nested_list]).to eq("todos")
        # Plus the json-mode marker the client branches on.
        expect(attrs[:data][:reactive_nested_json]).to eq("todos")
      end

      it "names the hidden JSON field as an UNSCOPED [name=…] selector by default" do
        attrs = instance.send(:reactive_nested_list, :todos, as: :json)
        expect(attrs[:data][:reactive_nested_json_field]).to eq(%([name="todos"]))
      end

      it "scope-prefixes the hidden JSON field selector under reactive_scope" do
        scoped = Class.new(Phlex::HTML) do
          include Phlex::Reactive::Component

          def self.name = "ScopedJsonNested"
          reactive_scope :order
        end

        attrs = scoped.new.send(:reactive_nested_list, :todos, as: :json)
        expect(attrs[:data][:reactive_nested_json_field]).to eq(%([name="order[todos]"]))
      end

      it "leaves the plain (accepts_nested_attributes_for) mode markerless by default" do
        attrs = instance.send(:reactive_nested_list, :line_items)
        expect(attrs[:data]).not_to have_key(:reactive_nested_json)
        expect(attrs[:data]).not_to have_key(:reactive_nested_json_field)
      end

      it "raises on an unknown as: mode (a typo is a dead binding, fail at render)" do
        expect { instance.send(:reactive_nested_list, :todos, as: :xml) }
          .to raise_error(ArgumentError, /as:/)
      end

      # Issue #224: name: is the verbatim ESCAPE HATCH for the hidden JSON
      # sync field — a form builder's wire name ("order[todos]") the
      # class-level reactive_scope compile can't express. JSON-mode only:
      # the :attributes mode has no field to name.
      context "with the name: escape hatch (issue #224)" do
        it "names the hidden JSON field verbatim" do
          attrs = instance.send(:reactive_nested_list, :todos, as: :json, name: "order[todos]")
          expect(attrs[:data][:reactive_nested_json_field]).to eq(%([name="order[todos]"]))
        end

        it "never re-scopes a verbatim name: under reactive_scope" do
          scoped = Class.new(Phlex::HTML) do
            include Phlex::Reactive::Component

            def self.name = "ScopedJsonNestedEscape"
            reactive_scope :invoice
          end

          attrs = scoped.new.send(:reactive_nested_list, :todos, as: :json, name: "order[todos]")
          expect(attrs[:data][:reactive_nested_json_field]).to eq(%([name="order[todos]"]))
        end

        it "raises on name: without as: :json (there is no field to name in :attributes mode)" do
          expect { instance.send(:reactive_nested_list, :todos, name: "order[todos]") }
            .to raise_error(ArgumentError, /as: :json/)
        end

        it "raises on a blank name:" do
          expect { instance.send(:reactive_nested_list, :todos, as: :json, name: " ") }
            .to raise_error(ArgumentError, /name:/)
        end

        it "raises on a boolean name: (the name: cond && \"…\" idiom must fail loudly)" do
          expect { instance.send(:reactive_nested_list, :todos, as: :json, name: false) }
            .to raise_error(ArgumentError, /name:/)
        end
      end
    end

    it "emits the association-keyed template marker" do
      attrs = instance.send(:reactive_nested_template, :line_items)
      expect(attrs[:data][:reactive_nested_template]).to eq("line_items")
    end

    it "emits the row wrapper marker" do
      attrs = instance.send(:reactive_nested_row)
      expect(attrs[:data][:reactive_nested_row]).to be(true)
    end

    it "emits the client-only add trigger (no dispatch — no POST)" do
      attrs = instance.send(:reactive_nested_add, :line_items)
      expect(attrs[:type]).to eq("button")
      expect(attrs[:data][:action]).to eq("click->reactive#nestedAdd")
      expect(attrs[:data][:reactive_association_param]).to eq("line_items")
    end

    describe "fill-then-add (from:/clear:, issue #208 Scenario A)" do
      it "emits the from: map (row field => source selector) as a JSON param" do
        attrs = instance.send(:reactive_nested_add, :line_items,
          from: { quantity: "#item-qty", price: "#item-price" })
        expect(JSON.parse(attrs[:data][:reactive_nested_from_param]))
          .to eq("quantity" => "#item-qty", "price" => "#item-price")
      end

      it "emits the clear: flag as the STRING \"true\" (never a valueless boolean attr)" do
        attrs = instance.send(:reactive_nested_add, :line_items, from: { quantity: "#q" }, clear: true)
        expect(attrs[:data][:reactive_nested_clear_param]).to eq("true")
      end

      it "omits both params by default (byte-identical to the inline-edit add)" do
        attrs = instance.send(:reactive_nested_add, :line_items)
        expect(attrs[:data]).not_to have_key(:reactive_nested_from_param)
        expect(attrs[:data]).not_to have_key(:reactive_nested_clear_param)
      end

      it "raises on an empty from: map (a dead binding — fail at render)" do
        expect { instance.send(:reactive_nested_add, :line_items, from: {}, clear: true) }
          .to raise_error(ArgumentError, /from:/)
      end

      it "raises on a blank source selector" do
        expect { instance.send(:reactive_nested_add, :line_items, from: { quantity: "  " }) }
          .to raise_error(ArgumentError)
      end

      it "raises on a row field key that isn't a plain identifier" do
        expect { instance.send(:reactive_nested_add, :line_items, from: { "bad key" => "#x" }) }
          .to raise_error(ArgumentError, /field/)
      end
    end

    it "emits the client-only remove trigger" do
      attrs = instance.send(:reactive_nested_remove)
      expect(attrs[:type]).to eq("button")
      expect(attrs[:data][:action]).to eq("click->reactive#nestedRemove")
    end

    # Issue #218: reactive_nested_remove gains the SAME confirm: the other
    # triggers (on/on_client) accept — routed through the shared apply_confirm!,
    # so the static String, conditional when:, and named predicate: forms all
    # work for parity. No confirm → the plain fast-path trigger, unchanged.
    describe "confirm: (issue #218)" do
      it "emits a static confirm message (data-reactive-confirm-param)" do
        attrs = instance.send(:reactive_nested_remove, confirm: "Really delete this row?")
        expect(attrs[:data][:reactive_confirm_param]).to eq("Really delete this row?")
      end

      it "omits the confirm wire entirely when no confirm: is given" do
        attrs = instance.send(:reactive_nested_remove)
        expect(attrs[:data]).not_to have_key(:reactive_confirm_param)
        expect(attrs[:data]).not_to have_key(:reactive_confirm_when_param)
      end

      it "compiles a conditional when: Hash through the shared apply_confirm! (parity with on)" do
        attrs = instance.send(:reactive_nested_remove,
          confirm: { when: { amount: 0 }, message: "Remove empty row?" })

        payload = JSON.parse(attrs[:data][:reactive_confirm_when_param])
        expect(payload["message"]).to eq("Remove empty row?")
        expect(payload.dig("groups", "any", 0, 0)["field"]).to eq("amount")
        expect(attrs[:data]).not_to have_key(:reactive_confirm_param)
      end

      it "carries a named predicate: verbatim" do
        attrs = instance.send(:reactive_nested_remove,
          confirm: { predicate: "row_has_value", message: "This row has data — remove?" })

        payload = JSON.parse(attrs[:data][:reactive_confirm_when_param])
        expect(payload["predicate"]).to eq("row_has_value")
      end

      it "raises on a non-String/Hash confirm: (the shared apply_confirm! guard)" do
        expect { instance.send(:reactive_nested_remove, confirm: 42) }
          .to raise_error(ArgumentError)
      end
    end

    it "raises on an association name that isn't a plain identifier" do
      expect { instance.send(:reactive_nested_add, "line items") }
        .to raise_error(ArgumentError, /association/)
    end

    it "is available to a ClientBindings (token-less) component" do
      client_only = Class.new(Phlex::HTML) do
        include Phlex::Reactive::ClientBindings

        def self.name = "ClientOnlyNested"
      end

      attrs = client_only.new.send(:reactive_nested_add, :line_items)
      expect(attrs[:data][:reactive_association_param]).to eq("line_items")
    end
  end

  # Issue #180 Phase A: reactive_show_targets — CROSS-ROOT visibility, now using
  # the SAME conditions value language. Each target id maps to a where-style
  # value (scalar/Array/Range) instead of a { equals: } predicate hash; the value
  # compiles to ONE DNF group (terms ANDed) per id. Id selectors only (raise at
  # declare time, warn-and-skip client-side — two-sided default-deny).
  describe "#reactive_show_targets (cross-root visibility, issue #180)" do
    subject(:instance) { targets_klass.new }

    let(:targets_klass) do
      Class.new(Phlex::HTML) do
        include Phlex::Reactive::Component

        def self.name = "ShowTargetsThing"

        reactive_state :count
        def initialize(count: 0) = @count = count
        def id = "show-targets-thing"
      end
    end

    def targets_json(attrs)
      JSON.parse(attrs[:data][:reactive_show_targets])
    end

    it "emits each target's value as a DNF group keyed by id" do
      attrs = instance.send(:reactive_show_targets, :mode,
        "#advanced-tab" => "advanced",
        "#basic-note" => nil)

      expect(targets_json(attrs)).to eq(
        "mode" => {
          "#advanced-tab" => [{ "field" => "mode", "equals" => "advanced" }],
          "#basic-note" => [{ "field" => "mode", "equals" => "" }]
        }
      )
    end

    it "maps Array to membership and Range to threshold in a target value" do
      attrs = instance.send(:reactive_show_targets, :amount,
        "#surcharge" => 5000..,
        "#sizes" => %w[l xl])

      expect(targets_json(attrs)["amount"]).to eq(
        "#surcharge" => [{ "field" => "amount", "gte" => 5000 }],
        "#sizes" => [{ "field" => "amount", "in" => %w[l xl] }]
      )
    end

    it "maps a bounded Range to TWO ANDed terms in the target group" do
      attrs = instance.send(:reactive_show_targets, :score, "#band" => 10..20)
      expect(targets_json(attrs)["score"]).to eq(
        "#band" => [{ "field" => "score", "gte" => 10 }, { "field" => "score", "lte" => 20 }]
      )
    end

    it "raises for a non-id selector (declare-time default-deny)" do
      # rubocop:disable-next Style/ItBlockParameter
      [".panel", "#a b", "div#a", "*"].each do |selector|
        expect do
          instance.send(:reactive_show_targets, :mode, selector => "x")
        end.to raise_error(ArgumentError, /must be a single ID selector/)
      end
    end

    it "raises for an empty target map" do
      expect { instance.send(:reactive_show_targets, :mode, {}) }
        .to raise_error(ArgumentError, /at least one target/)
    end

    it "accepts the multi-field hash form in ONE call (mix-collision-proof)" do
      attrs = instance.send(:reactive_show_targets,
        mode: { "#advanced-tab" => "advanced" },
        kind: { "#premium-note" => %w[gold platinum] })

      expect(targets_json(attrs)).to eq(
        "mode" => { "#advanced-tab" => [{ "field" => "mode", "equals" => "advanced" }] },
        "kind" => { "#premium-note" => [{ "field" => "kind", "in" => %w[gold platinum] }] }
      )
    end

    it "raises helpfully when a target key carries a bare value (neither call form)" do
      expect { instance.send(:reactive_show_targets, "#advanced-tab" => "x") }
        .to raise_error(ArgumentError, /"#advanced-tab".*conditions Hash|conditions Hash.*"#advanced-tab"/m)
    end

    it "raises on an empty Array value (same rule as reactive_show)" do
      expect { instance.send(:reactive_show_targets, :mode, "#a" => []) }
        .to raise_error(ArgumentError, /needs at least one value/)
    end

    it "deep-merges with reactive_root via mix (no data: clobber)" do
      attrs = instance.send(:mix,
        instance.send(:reactive_root),
        instance.send(:reactive_show_targets, :mode, "#a" => "x"))
      expect(attrs[:data][:controller]).to eq("reactive")
      expect(attrs[:data][:reactive_show_targets]).to be_a(String)
    end

    it "guides the removed { equals: } predicate-hash form to a bare value" do
      expect { instance.send(:reactive_show_targets, :mode, "#a" => { equals: "x" }) }
        .to raise_error(ArgumentError, /bare value|"#a" => "x"|use a value/m)
    end

    # Issue #209: TARGET-KEYED conditions — a "#id" key whose value is a full
    # if:/if_any:/unless: conditions Hash. The multi-field cross-root case: the
    # target's DNF payload is the SAME { any: [[term,…],…] } shape reactive_show
    # emits, folded by the client with the same per-term field reads.
    describe "target-keyed conditions (issue #209 — multi-field cross-root)" do
      it "compiles a multi-field if: into the target's DNF payload" do
        attrs = instance.send(:reactive_show_targets,
          "#trade-warning" => { if: { type: "trade", price: ..0 } })

        expect(targets_json(attrs)).to eq(
          "#trade-warning" => { "any" => [[
            { "field" => "type", "equals" => "trade" },
            { "field" => "price", "lte" => 0 }
          ]] }
        )
      end

      it "speaks the FULL conditions language (if_any: + unless:)" do
        attrs = instance.send(:reactive_show_targets,
          "#warn" => { if_any: [{ director: true }, { shareholder: true }], unless: { role: "company" } })

        expect(targets_json(attrs)["#warn"]).to eq(
          "any" => [
            [{ "field" => "director", "equals" => "true" }, { "field" => "role", "not" => "company" }],
            [{ "field" => "shareholder", "equals" => "true" }, { "field" => "role", "not" => "company" }]
          ]
        )
      end

      it "mixes field-keyed and target-keyed entries in ONE call (byte-stable legacy wire)" do
        attrs = instance.send(:reactive_show_targets,
          mode: { "#advanced-tab" => "advanced" },
          "#trade-warning" => { if: { type: "trade", price: ..0 } })

        expect(targets_json(attrs)).to eq(
          "mode" => { "#advanced-tab" => [{ "field" => "mode", "equals" => "advanced" }] },
          "#trade-warning" => { "any" => [[
            { "field" => "type", "equals" => "trade" },
            { "field" => "price", "lte" => 0 }
          ]] }
        )
      end

      it "raises for a non-id selector key (declare-time default-deny, same as field-keyed)" do
        expect { instance.send(:reactive_show_targets, "#a b" => { if: { mode: "x" } }) }
          .to raise_error(ArgumentError, /must be a single ID selector/)
      end

      it "raises for unknown keys in the conditions Hash" do
        expect { instance.send(:reactive_show_targets, "#warn" => { if: { mode: "x" }, bogus: 1 }) }
          .to raise_error(ArgumentError, /bogus/)
      end

      it "names the unknown key even when NO condition key is present (specific beats generic)" do
        expect { instance.send(:reactive_show_targets, "#warn" => { bogus: 1 }) }
          .to raise_error(ArgumentError, /unknown conditions key\(s\) :bogus/)
      end

      it "raises for an empty conditions Hash" do
        expect { instance.send(:reactive_show_targets, "#warn" => {}) }
          .to raise_error(ArgumentError, /conditions Hash/)
      end

      it "raises through ShowConditions for an empty if: (a dead binding fails at render)" do
        expect { instance.send(:reactive_show_targets, "#warn" => { if: {} }) }
          .to raise_error(ArgumentError, /at least one field/)
      end
    end
  end

  # Performance: reactive_token runs on EVERY render. It must produce a byte-
  # identical payload before/after caching the ivar symbols + class name. These
  # pin the payload SHAPE (decoded) so an allocation optimization can't silently
  # change what's signed.
  describe "#reactive_token payload (perf invariants)" do
    it "signs {c, s} for a state-backed component, with string keys (+ version marker #111)" do
      token = state_klass.new(count: 5).send(:reactive_token)
      expect(Phlex::Reactive.verify(token))
        .to eq("c" => "StateThing", "s" => { "count" => 5 }, "v" => Phlex::Reactive::TOKEN_VERSION)
    end

    it "is stable across repeated renders of equal state" do
      a = Phlex::Reactive.verify(state_klass.new(count: 3).send(:reactive_token))
      b = Phlex::Reactive.verify(state_klass.new(count: 3).send(:reactive_token))
      expect(a).to eq(b)
    end
  end
end
