# frozen_string_literal: true

module Phlex
  module Reactive
    # Component turns a self-contained Phlex component into a Livewire-style
    # reactive unit: declare actions in Ruby, and the generic `reactive`
    # Stimulus controller wires clicks/inputs to an HTTP round trip that
    # re-renders the component and applies it back into the DOM (a plain replace
    # by default; return reply.morph to morph in place and keep the focused
    # input — issue #28). No per-feature Stimulus controllers, no hand-picked
    # Turbo targets.
    #
    # Including Component pulls in Phlex::Reactive::Streamable automatically
    # (Concern dependency — Streamable lands on the base first, exactly the old
    # manual order), so ONE include is enough. The legacy explicit double
    # include remains a harmless no-op.
    #
    # === Security model (the decisive design choice) ===
    # We do NOT ship component STATE to the browser (no snapshot). The DOM
    # carries a signed IDENTITY:
    #
    #   * Record-backed (the common case): reactive_record :todo signs the
    #     record's GlobalID. The server re-finds it via GlobalID — the client
    #     can neither forge the component class nor swap the record. State =
    #     the database.
    #   * State-backed (record-less, e.g. a counter): reactive_state :count
    #     signs the listed instance variables. Use when there is genuinely no
    #     record to re-find.
    #   * Both (the inline_edit pattern): reactive_record :record plus
    #     reactive_state :attribute, :editing signs the record's GlobalID AND
    #     the transient mode in one token, so "which field / what mode" survives
    #     every action round trip and stays tamper-proof.
    #
    # Actions are DEFAULT-DENY: only methods declared with `action :name` may be
    # invoked. The signature proves the token is ours, NOT that this user may
    # act — your action must still authorize the record. Action params pass
    # through a declared schema; nothing else reaches the method.
    #
    # Usage (record-backed — #id defaults to dom_id(@todo), issue #81):
    #   class Todos::Item < ApplicationComponent
    #     include Phlex::Reactive::Component
    #
    #     reactive_record :todo
    #     action :toggle
    #     action :rename, params: { title: :string }
    #
    #     def initialize(todo:) = @todo = todo
    #
    #     def toggle  = (authorize!(@todo, :update?); @todo.toggle!(:done))
    #     def rename(title:) = (authorize!(@todo, :update?); @todo.update!(title:))
    #
    #     def view_template
    #       li(id:, **reactive_attrs) do
    #         button(**on(:toggle)) { @todo.done? ? "✓" : "○" }
    #         span { @todo.title }
    #       end
    #     end
    #   end
    #
    # Assembled from cohesive concerns (issue #115, restructured in #180) — one
    # include, zero public API change. The include stack, in order:
    #   * Phlex::Reactive::Streamable — the render/broadcast/#id surface (mixed in
    #     first, so its methods sit below the component's own).
    #   * Phlex::Reactive::ClientBindings — the CLIENT-ONLY surface (issue #180),
    #     itself Component::DSL (the declaration registries via Component::Registry
    #     + from_identity) + Component::Helpers (reply/js, reactive_attrs/root,
    #     on/on_client, the field/select/text bindings, reactive_show/filter/
    #     compute, and the nested-attributes helpers). ClientBindings is the ONE
    #     implementation of that surface, shared with the standalone client-only
    #     include; it carries NO token machinery.
    #   * Component::Identity — reactive_token + the hot-path ivar precomputation.
    #     Its presence is what makes the server-action macros (action/
    #     reactive_record/reactive_state) legal here — they raise on a
    #     ClientBindings-only class that lacks it.
    #   * Component::Lazy — reactive_lazy (deferred initial mount, issue #165).
    # So a full, token-bearing reactive component is a SUPERSET of a client-only
    # one, not a fork.
    module Component
      extend ActiveSupport::Concern
      include Phlex::Reactive::Streamable

      # A declared, client-invokable action and its param schema. `params` keeps
      # the RAW declared hash (the readable form callers/specs inspect); `schema`
      # is the compiled Phlex::Reactive::ParamSchema (issue #109) the endpoint
      # coerces through — built ONCE at declaration so a typo'd type symbol
      # raises Phlex::Reactive::UnknownParamType at class load, not at click time.
      #
      # Named ActionDefinition (issue #233), NOT Action: this module sits in
      # every reactive component's ancestry, so a bare `Action` constant
      # shadows a host app's Phlex kit component of the same name under lazy
      # autoloading (Kit's LazyLoader resolves through the calling class's
      # const_get). Keep every constant here suffixed / implausible as a kit
      # component name — and never alias the old name back.
      ActionDefinition = Data.define(:name, :params, :schema)

      # A declared client-side computation (data binding). `inputs`/`outputs` are
      # the action-param names of the fields the reducer reads/writes; `reducer`
      # is the key a JS function is registered under (Reactive.compute(key, fn)).
      # The generic controller runs the reducer on `input` — writing outputs with
      # NO round trip — then the debounced POST reconciles from the server reply.
      #
      # `input_types` (issue #104) is nil for the ARRAY input form (untyped ⇒ the
      # client coerces every input through Number, the shipped behavior) and a
      # { name => type } hash for the typed HASH form (:string reads the field
      # value raw, :number coerces, :boolean reads a checkbox's checked state —
      # issue #262). `inputs` stays the ordered name list either
      # way, so iteration order is preserved and the array-form wire is unchanged.
      #
      # `mirror` (issue #159) is nil when undeclared, else a { name => [id
      # selectors] } map — DECLARED cross-root text mirrors, validated to id
      # selectors only at declare time (the server half of the two-sided
      # default-deny; the client interpreter re-checks the shape).
      ComputeDefinition = Data.define(:name, :inputs, :outputs, :reducer, :input_types, :mirror)

      # A declared completion binding (issue #226): `conditions` are the
      # pre-compiled ShowConditions DNF groups (the ONE conditions language,
      # including the #226 length: form); `ops` is the validated [[op, args],…]
      # client-op chain. The generic controller evaluates the conditions over
      # the owned fields on input/change and runs the ops on the RISING EDGE —
      # the conditions' first flip to true — through the same frozen CLIENT_OPS
      # whitelist as on_client. The connect/morph pass arms without firing.
      OnCompleteDefinition = Data.define(:name, :conditions, :ops)

      # A declared add/remove-row collection (issue #35): the list contract tied
      # into one unit — the per-row item component, the container DOM id rows
      # live in, an optional companion count id, an optional empty-state
      # component, and a size resolver (a proc evaluated against the container
      # instance) used to re-render the count and toggle the empty-state at the
      # 0<->1 boundary. count/empty/size are nil when not declared, and the
      # corresponding stream is simply omitted — so a list with just rows still
      # works.
      CollectionDefinition = Data.define(:name, :item, :container, :count, :empty, :size) do
        # The collection's current size, evaluated against the bound container
        # instance (instance_exec so the proc reads the component's ivars /
        # association). nil when no resolver was declared — callers skip the
        # count/empty streams that need a number.
        def size_for(component)
          size && component.instance_exec(&size)
        end
      end

      # ClientBindings (issue #180) is the client-only surface (DSL + Helpers),
      # tokenless and Streamable-free. Component includes it as the ONE
      # implementation, then layers Identity + Lazy (and Streamable, above) on
      # top — a token-bearing root is a superset of the client-only one.
      include ClientBindings
      include Identity
      include Lazy
    end
  end
end
