# frozen_string_literal: true

module Phlex
  module Reactive
    module Component
      # The class-level declaration DSL (issue #115): the five registries a
      # component declares itself through — reactive_record, reactive_state,
      # action, reactive_collection, reactive_compute — their public readers,
      # and from_identity (rebuilding an instance from a verified identity
      # payload). Every registry resolves through Component::Registry, so all
      # five share ONE inheritance semantic: resolve through the superclass at
      # read time, memoized per class against the registry generation.
      #
      # The readers are PUBLIC API — the action endpoint (reactive_action/
      # reactive_action?/reactive_actions), Response (reactive_collection_def),
      # Streamable's default #id (reactive_record_key), doctor, and the test
      # helpers all dispatch through them. They keep their exact signatures
      # forever; new reader forms (reactive_compute_def) are added alongside,
      # never instead.
      module DSL
        extend ActiveSupport::Concern

        # A cross-root mirror target must be a single ID selector (issue #159)
        # — "#" + a CSS identifier, nothing else. Not a class, not an attribute
        # selector, not `*`, not a compound/descendant/list selector: a
        # compromised reducer must not be able to scribble text across the
        # page. The client interpreter enforces the SAME shape (two-sided
        # default-deny, mirroring the attr allowlist posture).
        MIRROR_ID_SELECTOR = /\A#[A-Za-z_][\w-]*\z/

        class_methods do
          # Guard the three SERVER-ACTION macros (issue #180). ClientBindings
          # includes this DSL for its client-only macros (reactive_scope,
          # reactive_compute) but does NOT include Identity/Streamable — so a
          # signed token is never minted and no action endpoint dispatches to
          # this class. Declaring action/reactive_record/reactive_state there
          # would silently no-op (an action that can never fire, a record that
          # signs nothing). Fail LOUDLY at class-definition time instead — the
          # default-deny posture. Keyed on Identity presence: a full
          # Phlex::Reactive::Component includes it (passes); a ClientBindings-only
          # class does not (raises).
          def require_server_actions!(macro)
            return if include?(Phlex::Reactive::Component::Identity)

            raise ArgumentError,
              "#{self}: `#{macro}` needs the full Phlex::Reactive::Component — it signs a token / " \
              "dispatches a server action, which Phlex::Reactive::ClientBindings deliberately omits " \
              "(client-only: no token, no endpoint). Include Phlex::Reactive::Component for actions, " \
              "or drop `#{macro}` and use the client-only helpers (reactive_show/filter/compute, on_client)."
          end

          # Declare the ActiveRecord (GlobalID-able) record this component is
          # rebuilt from. The signed token carries its GlobalID; the server
          # re-finds it on each action. State lives in the DB.
          def reactive_record(name)
            require_server_actions!(:reactive_record)
            Registry.write_scalar(self, :record_key, name.to_sym)
          end

          # The nearest declared record key up the ancestry, or nil. Resolved
          # through Registry (issue #115) — the same always-fresh semantics the
          # pre-#115 live superclass walk had, now memoized against the registry
          # generation like every other registry.
          def reactive_record_key
            Registry.resolve_scalar(self, :record_key, :reactive_record_key)
          end

          # Declare (with a name) OR read (bare) a form-field NAMESPACE for this
          # component's bindings (issue #180). With `reactive_scope :form`,
          # reactive_show / reactive_values use bare symbols (`:director`) and the
          # client resolves the owned field as `[name="form[director]"]`; the root
          # emits `data-reactive-scope="form"`. Bare `reactive_scope` reads the
          # nearest declared scope up the ancestry (nil when none) — the
          # dual-purpose form matching reactive_compute's getter/setter. A
          # per-binding raw string field name still passes through unscoped.
          def reactive_scope(name = nil)
            return Registry.resolve_scalar(self, :scope, :reactive_scope) if name.nil?

            scope = name.to_sym
            # Issue #184: catch an action already declared with a schema nested under
            # THIS scope key (the action-first declaration order) — the endpoint
            # unwraps ONE scope level, so a schema pre-nested under it would be dead.
            reactive_actions.each_value { assert_no_scope_double_nesting!(scope, it.params, it.name) }
            Registry.write_scalar(self, :scope, scope)
          end

          # Raise a guided ArgumentError when a param schema is ALREADY nested under
          # the scope key (issue #184): the endpoint peels one scope level, so
          # params: { <scope>: { … } } would double-unwrap to nothing. Shared by both
          # macros so neither declaration order can dodge the guard. A nested key that
          # is NOT the scope (a real nested_attributes param) is fine.
          def assert_no_scope_double_nesting!(scope, params, action_name)
            return unless params.is_a?(Hash) && params[scope].is_a?(Hash)

            raise ArgumentError,
              "#{self}: action #{action_name.inspect} nests its schema under the reactive_scope " \
              "key #{scope.inspect} (params: { #{scope}: { … } }). The endpoint unwraps one scope " \
              "level already — declare the schema FLAT: params: { #{params[scope].keys.first || :field}: … }."
          end

          # Issue #184: ONE dirty-tracking declaration, class-level. Replaces
          # reactive_root(track_dirty:, warn_unsaved:) + reactive_field(dirty:).
          #
          #   reactive_dirty                       # track every field via the root
          #   reactive_dirty warn_unsaved: true    # + warn before navigating away
          #   reactive_dirty only: %i[title]       # track only these fields (per-field)
          #
          # Stored as a frozen config the render helpers read; the emitted DOM is
          # byte-identical to the old kwargs, so the client is unchanged. `only:`
          # switches to per-field descriptors (no root-level input delegation);
          # otherwise the root delegates for the whole subtree.
          def reactive_dirty(warn_unsaved: false, only: nil)
            Registry.write_scalar(self, :dirty, {
              warn_unsaved: warn_unsaved ? true : false,
              only: only && Array(only).map(&:to_sym).freeze
            }.freeze)
          end

          # The resolved dirty config (or nil when reactive_dirty was never
          # declared), inherited through the Registry like every other scalar.
          def reactive_dirty_config
            Registry.resolve_scalar(self, :dirty, :reactive_dirty_config)
          end

          # Effects (issue #215): declare how THIS component animates when a
          # stream renders it — enter (append/prepend), exit (remove), update
          # (replace/update, plain or morph). Refines the global
          # Phlex::Reactive.effects set per hook (most specific wins); works
          # standalone too — declaring on a component IS that component's
          # opt-in, no global switch required.
          #
          #   reactive_effects enter: :slide, exit: :fade   # built-ins (shipped CSS)
          #   reactive_effects update: false                # disable one hook
          #   reactive_effects false                        # opt out entirely
          #   reactive_effects enter: :random               # random built-in per application
          #   reactive_effects enter: { during: %w[transition-all], from: %w[opacity-0],
          #                             to: %w[opacity-100] }  # custom #186 legs
          #
          # Validated HERE (class load), not at render time — a typo'd effect
          # name raises immediately. Stored as pre-compiled wire strings.
          def reactive_effects(opt_out = nil, **hooks)
            if opt_out == false
              unless hooks.empty?
                raise ArgumentError,
                  "reactive_effects false opts the component out entirely — it takes no hooks " \
                  "(got #{hooks.keys.inspect}); use per-hook false to disable one: update: false"
              end
              return Registry.write_scalar(self, :effects, false)
            end
            unless opt_out.nil?
              raise ArgumentError,
                "reactive_effects takes hook keywords (enter:/exit:/update:) or false — got #{opt_out.inspect}"
            end
            if hooks.empty?
              raise ArgumentError,
                "reactive_effects needs at least one hook (enter:/exit:/update:) or false to opt out"
            end

            Registry.write_scalar(self, :effects, Phlex::Reactive::Effects.normalize!(hooks))
          end

          # The raw declaration ({ hook => wire | false }, false for a full
          # opt-out, or nil when undeclared), inherited through the Registry
          # like every other scalar.
          def reactive_effects_config
            Registry.resolve_scalar(self, :effects, :reactive_effects_config)
          end

          # The RESOLVED root effect attrs (global ⊕ component, false hooks
          # dropped): a frozen { reactive_effect_enter: "fade", … } fragment
          # reactive_attrs merges into the root's data:, or nil when off.
          # Memoized per class against BOTH inputs that can change the answer
          # — the effects config generation (a Phlex::Reactive.effects= write)
          # and the registry generation (any declaration) — as two integer
          # compares, because reactive_attrs is the token-signing hot path.
          # The race on a concurrent first call is benign (idempotent rebuild).
          def reactive_effect_attrs
            effects_gen = Phlex::Reactive.effects_generation
            registry_gen = Registry.generation
            if @reactive_effect_attrs_effects_gen == effects_gen &&
               @reactive_effect_attrs_registry_gen == registry_gen
              return @reactive_effect_attrs
            end

            @reactive_effect_attrs = Phlex::Reactive::Effects.root_attrs_for(self)
            @reactive_effect_attrs_effects_gen = effects_gen
            @reactive_effect_attrs_registry_gen = registry_gen
            @reactive_effect_attrs
          end

          # Opt into signed STATE for record-less components only.
          #   reactive_state :count, :open
          def reactive_state(*names)
            require_server_actions!(:reactive_state)
            Registry.append(self, :state_keys, names.map(&:to_sym))
          end

          # Ancestors' keys first, own appended — declaration order. Resolved
          # through Registry at read time (issue #115), so a parent's later
          # reactive_state is visible here and in the identity fast path (the
          # write sweeps the memoized ivar pairs family-wide).
          def reactive_state_keys
            Registry.resolve_list(self, :state_keys, :reactive_state_keys)
          end

          # Lazy initial mount (issue #165): the FIRST (page-embedded) render
          # emits the placeholder shell + a defer token on the root; the client
          # fetches the real content on connect. Reactive machinery renders
          # (replies, broadcasts, the defer endpoint/job) stay REAL. Inherited
          # by subclasses. See Component::Lazy.
          #
          # `tag:` sets the shell element (default :div). Set it to the real
          # root's element for content that can't legally hold a <div> — a
          # `reactive_lazy tag: :tr` component rooting at <tr> inside <tbody>
          # ships a <tr> shell, not a <div> the HTML parser would hoist away.
          #
          # `on:` (issue #276) defers the REQUEST itself, not just server time:
          #   reactive_lazy on: "panel:opened"        # a DOM event on (or bubbling into) the shell
          #   reactive_lazy on: :visible              # the shell first scrolls into view
          #   reactive_lazy on: { visible: "200px" }  # …with an IntersectionObserver rootMargin
          # The shell then carries the identity token (no TTL) and materializes
          # once through the action endpoint. See Component::Lazy.
          #
          # `cache:` (issue #277) makes the real render a privately cacheable GET:
          #   reactive_lazy cache: { max_age: 10.minutes }   # combine with on:/tag: freely
          # The shell carries a stable signed URL instead of a per-render token,
          # and the endpoint answers `Cache-Control: private, max-age=…`, so the
          # browser reuses the fragment across page views. Define
          # `reactive_cache_version` to bust the URL when the content changes,
          # and `reactive_cache_viewer` (e.g. Current.user&.id) to key the URL
          # on the viewer instead of `Vary: Cookie` — needed for reuse ACROSS
          # page views when the session cookie changes on every response
          # (Rails' cookie store does).
          def reactive_lazy(tag: :div, on: nil, cache: nil)
            declaration = { tag: tag.to_sym }
            declaration[:trigger] = Lazy.normalize_trigger(on) unless on.nil?
            declaration[:cache] = Lazy.normalize_cache(cache) unless cache.nil?
            Registry.write_scalar(self, :lazy, declaration)
          end

          # The RAW resolved lazy declaration ({ tag: } or nil) — the reader the
          # Registry walks up the ancestry. It MUST return the stored value, not
          # a boolean: resolve_scalar inherits whatever the superclass reader
          # returns, so a boolean false would be inherited as the value and read
          # back as "declared" (`!false.nil?` == true) — a subclass of any
          # component would spuriously render the lazy shell.
          def reactive_lazy_declaration
            Registry.resolve_scalar(self, :lazy, :reactive_lazy_declaration)
          end

          def reactive_lazy?
            !reactive_lazy_declaration.nil?
          end

          # The shell element tag for a lazy component (:div default), resolved
          # through the registry so a subclass inherits the parent's choice.
          def reactive_lazy_tag
            value = reactive_lazy_declaration
            value.is_a?(::Hash) ? value.fetch(:tag, :div) : :div
          end

          # The normalized `on:` trigger of a lazy component — `{ event: "x" }`
          # or `{ visible: "<rootMargin>" }` — or nil (plain reactive_lazy, or
          # not lazy at all). The endpoint's `__materialize` gate reads it.
          def reactive_lazy_trigger
            value = reactive_lazy_declaration
            value[:trigger] if value.is_a?(::Hash)
          end

          # The normalized `cache:` of a lazy component — `{ max_age: <seconds> }`
          # — or nil. The fragment endpoint's opt-in gate reads it: only a
          # component that declared `cache:` is reachable over GET.
          def reactive_lazy_cache
            value = reactive_lazy_declaration
            value[:cache] if value.is_a?(::Hash)
          end

          # Declare a client-invokable action with an optional param schema.
          #   action :increment
          #   action :rename, params: { title: :string }
          #
          # Param types are coerced server-side; anything not in the schema is
          # dropped before reaching your method (no mass assignment):
          #   * Scalars — :string (default), :integer, :float, :boolean
          #   * Array of scalar — wrap the type in an array: [:integer]
          #   * Array of hash (Rails nested attributes) — wrap a hash schema:
          #       action :save, params: {
          #         date: :string,
          #         bank_account_ids: [:integer],
          #         invoice_items_attributes: [
          #           { id: :integer, quantity: :float, price: :float, _destroy: :boolean }
          #         ]
          #       }
          # Array params accept BOTH a JSON array and a Rails-style index hash
          # ({ "0" => ..., "1" => ... }), so a fields_for collection works either way.
          def action(name, params: {})
            require_server_actions!(:action)
            # Issue #276: the endpoint routes `__materialize` to the lazy render
            # before the action registry is consulted — a declared one would be
            # dead code that looks invokable.
            if name.to_sym == Lazy::MATERIALIZE_ACTION
              raise ArgumentError, "action #{name.inspect} is reserved for reactive_lazy(on:)"
            end

            # Issue #184: params: :symbol resolves a registered named schema.
            params = Phlex::Reactive.param_schema(params) if params.is_a?(Symbol)
            # If a scope is already declared, reject a schema nested under the scope
            # key here (the scope-first declaration order). The action-first order is
            # caught in reactive_scope.
            scope = reactive_scope
            assert_no_scope_double_nesting!(scope, params, name.to_sym) if scope
            Registry.write_entry(
              self, :actions, name.to_sym,
              ActionDefinition.new(name: name.to_sym, params: params, schema: Phlex::Reactive::ParamSchema.compile(params))
            )
          end

          # The full declared-action registry, ancestors included — the
          # default-deny source of truth the endpoint dispatches against.
          # Resolved through Registry at read time (issue #115): a parent action
          # declared after a subclass was first read is no longer silently
          # invisible to the subclass (the pre-#115 snapshot-dup divergence).
          def reactive_actions
            Registry.resolve_hash(self, :actions, :reactive_actions)
          end

          # Issue #186: the fetch-one readers are removed — the plural
          # reactive_actions hash IS the fetch-one. Guided errors name the rewrite.
          def reactive_action(name)
            raise NoMethodError,
              "reactive_action(#{name.inspect}) was removed in issue #186 — use reactive_actions[#{name.inspect}]"
          end

          def reactive_action?(name)
            raise NoMethodError,
              "reactive_action?(#{name.inspect}) was removed in issue #186 — " \
              "use reactive_actions.key?(#{name.inspect})"
          end

          # Dormant root (issue #274): every root of this component renders
          # data-reactive-dormant="reactive" instead of data-controller=
          # "reactive", so the client is neither mounted nor (when loaded
          # lazily) fetched until one of the root's triggers fires — for a root
          # that only matters after a gesture (a closed dialog, a menu that
          # loads on open). The app must import "phlex/reactive/early", which
          # wakes the root. Inherited; `reactive_dormant false` turns it off
          # again in a subclass, and reactive_root(dormant:) overrides per
          # render. See Phlex::Reactive::Dormant.
          #
          # Not with reactive_lazy(on: :visible): that shell has no trigger to
          # wake on (refused here, or at render for the other declaration order).
          # A plain reactive_lazy shell ignores it: it fetches on connect, so it
          # always mounts. reactive_lazy(on: "event") shells do go dormant.
          def reactive_dormant(dormant = true) # rubocop:disable Style/OptionalBooleanParameter
            unless [true, false].include?(dormant)
              raise ArgumentError, "#{self}: reactive_dormant takes true or false, got #{dormant.inspect}"
            end

            Phlex::Reactive::Dormant.reject_visible_lazy!(self) if dormant

            Registry.write_scalar(self, :dormant, dormant)
          end

          def reactive_dormant?
            Registry.resolve_scalar(self, :dormant, :reactive_dormant?) == true
          end

          # Opt out of the default-ON verify_authorized guard (issue #168).
          # Bare skips the WHOLE component (a public counter, a client-only
          # filter); with names skips just those actions:
          #
          #   skip_verify_authorized                 # every action
          #   skip_verify_authorized :filter, :page  # only these
          #
          # Registry #6 — resolves through the superclass at read time like the
          # other five, so a child inherits a parent's skips (and a child's bare
          # skip covers everything). Marks nothing else; a non-skipped action
          # still needs a real authorization call or mark_authorized!.
          def skip_verify_authorized(*names)
            if names.empty?
              Registry.write_scalar(self, :skip_all, true)
            else
              Registry.append(self, :skip_actions, names.map(&:to_sym))
            end
          end

          def reactive_skip_all_authorization?
            Registry.resolve_scalar(self, :skip_all, :reactive_skip_all_authorization?) == true
          end

          def reactive_skip_authorization_actions
            Registry.resolve_list(self, :skip_actions, :reactive_skip_authorization_actions)
          end

          # Is verify_authorized skipped for `action_name`? True under a bare
          # component skip OR when the action is in the named list — resolved
          # through Registry so inheritance matches every other declaration.
          def skip_verify_authorized?(action_name)
            reactive_skip_all_authorization? ||
              reactive_skip_authorization_actions.include?(action_name.to_sym)
          end

          # Declare an add/remove-row collection (issue #35) — the list contract
          # in one place, so actions append/prepend/remove a row WITHOUT
          # re-deriving the container id, count, and empty-state in every action:
          #
          #   reactive_collection :items,
          #     item: ItemRowComponent,    # the per-row Streamable component
          #     container: "items-list",   # the DOM id rows live in
          #     count: "items-count",      # optional companion id (the size badge)
          #     empty: ItemsEmptyComponent, # optional empty-state component
          #     size: -> { @record.items.size } # resolves the live size
          #
          # An action then governs the reply with one call (the collection is
          # named by the to:/from: keyword, issue #182):
          #   reply.append(item, to: :items)   # row append + count + clear empty-state
          #   reply.remove(id, from: :items)   # row remove + count + restore empty-state
          #
          # count/empty/size are optional: a list with just rows omits them and the
          # corresponding stream isn't emitted. See Phlex::Reactive::Reply and the
          # README "Reactive collections" section.
          def reactive_collection(name, item:, container:, count: nil, empty: nil, size: nil)
            Registry.write_entry(
              self, :collections, name.to_sym,
              CollectionDefinition.new(name: name.to_sym, item:, container:, count:, empty:, size:)
            )
          end

          def reactive_collections
            Registry.resolve_hash(self, :collections, :reactive_collections)
          end

          # Issue #186: use the plural reactive_collections hash directly.
          def reactive_collection_def(name)
            raise NoMethodError,
              "reactive_collection_def(#{name.inspect}) was removed in issue #186 — " \
              "use reactive_collections[#{name.inspect}]"
          end

          def reactive_collection?(name)
            raise NoMethodError,
              "reactive_collection?(#{name.inspect}) was removed in issue #186 — " \
              "use reactive_collections.key?(#{name.inspect})"
          end

          # Declare a client-side computation, OR (called with just a name) read
          # one back. Dual-purpose so a component reads `reactive_compute :split,
          # inputs: …, outputs: …` and the endpoint/helpers read
          # `reactive_compute(:split)` — mirroring how `on`/`reactive_field` keep a
          # tight surface. `reducer:` defaults to the compute name.
          #
          #   reactive_compute :payment_split,
          #     inputs: %i[allowance cash leasing total],  # fields the JS reducer reads
          #     outputs: %i[allowance cash leasing]        # fields it writes (no round trip)
          #
          # `inputs:` also takes a HASH to TYPE each input (issue #104): a :number is
          # coerced through Number on the client (the array-form default), a :string
          # is read raw — so a live text preview reads real text, not NaN→0:
          #
          #   reactive_compute :preview,
          #     inputs: { title: :string, qty: :number },
          #     outputs: %i[title_preview char_count]
          #
          # A CHECKBOX contributes its checked state, never its constant .value
          # (issue #262): 1/0 as a :number, "true"/"false" as a :string, and a
          # real boolean as a :boolean. It wins over the hidden companion Rails
          # renders before it. A radio group contributes its checked radio's value.
          #
          #   reactive_compute :total, inputs: [:price, { gift_wrap: :boolean }], outputs: %i[total]
          #
          # An output with no matching form field writes to its reactive_text(:name)
          # node (textContent); a declared input also mirrors into its own text node
          # with no reducer. The array form's wire stays byte-identical.
          #
          # Register the matching JS once at boot. The reducer's signature is
          # (values, meta) — values is { inputName: Number } over the declared
          # inputs; meta is { changed }, the name of the declared input the
          # triggering event edited (null on a direct call or an unowned/
          # undeclared target). A one-argument reducer keeps working (it just
          # ignores meta); `changed` is what lets ONE reducer express a
          # multi-way/mutual rebalance (issue #75) — branch on the edited field.
          # Because an output write dispatches a real `input` event (issue #76),
          # a branching reducer must be CONVERGENT — the re-entrant pass must
          # recompute the values already written so the change guard settles it
          # (see the header of app/javascript/phlex/reactive/compute.js).
          #
          #   import { setComputeReducer } from "phlex/reactive/compute"
          #   setComputeReducer("payment_split", ({ allowance, cash, leasing, total }, { changed }) => ({ … }))
          #
          # `mirror:` (issue #159) declares CROSS-ROOT text mirrors — the opt-in
          # escape from root isolation (issue #15) for a derived value shown in a
          # recap OUTSIDE the computing root (another tab pane, a sticky footer):
          #
          #   reactive_compute :split,
          #     inputs:  %i[a b total],
          #     outputs: %i[a b],
          #     mirror:  { sum_a: "#sum_a", sum_total: ["#sum_total", "#footer-total"] }
          #
          # Each key is a compute name — a declared input (its identity mirror
          # also paints cross-root) or a reducer-result key (an extra text-only
          # output). Each value is one or more DOCUMENT-WIDE id selectors the
          # value is painted into via textContent (XSS-safe, change-guarded,
          # never innerHTML, never a field write). Id selectors ONLY — a class/
          # attribute/compound selector raises here (declared, not arbitrary;
          # the client interpreter re-checks the same shape).
          def reactive_compute(name, inputs: nil, outputs: nil, reducer: nil, mirror: nil)
            if inputs.nil? && outputs.nil?
              # Issue #186: the bare getter form is removed — reactive_compute is
              # the SETTER now; read one compute via the plural hash. (Raising here
              # keeps the getter/setter overload from silently misfiring.)
              raise ArgumentError,
                "reactive_compute(#{name.inspect}) getter was removed in issue #186 — " \
                "use reactive_computes[#{name.inspect}]. reactive_compute is the declarative " \
                "SETTER now: reactive_compute(:name, inputs:, outputs:)."
            end

            input_names, input_types = normalize_compute_inputs(inputs)
            Registry.write_entry(
              self, :computes, name.to_sym,
              ComputeDefinition.new(
                name: name.to_sym, inputs: input_names, input_types:,
                outputs: Array(outputs).map(&:to_sym), reducer: (reducer || name).to_s,
                mirror: normalize_compute_mirror(mirror)
              )
            )
          end

          def reactive_computes
            Registry.resolve_hash(self, :computes, :reactive_computes)
          end

          # A fresh client-op chain at CLASS level (issue #226), so a
          # reactive_on_complete declaration reads like its on_client sibling:
          #
          #   reactive_on_complete if: { code: { length: 6 } },
          #     run: js.dispatch("code:complete")
          #
          # The instance helper (Component::Helpers#js) is unchanged.
          def js
            Phlex::Reactive::JS.new
          end

          # Declarative completion binding (issue #226): when the declared
          # conditions FIRST become true — evaluated client-side over the owned
          # fields on input/change — run a chain of client DOM ops. The
          # conditions are the SAME if:/if_any:/unless: kwargs reactive_show
          # takes (the ONE ShowConditions language, including the length: form);
          # `run:` is a js chain or a raw [[op, args], …] list (allowlist
          # re-checked, like every raw-ops escape hatch).
          #
          #   reactive_on_complete if: { code: { length: 6 } },
          #     run: js.dispatch("code:complete")
          #   reactive_on_complete :commit, if: { code: { length: 6 } }, run: js.submit
          #
          # RISING-EDGE, actor-gesture semantics on the client: ops fire once on
          # the flip to true, re-arm when the conditions go false, and the
          # connect/morph pass arms WITHOUT firing (a re-render with already-
          # satisfied conditions never self-fires). The optional NAME (default
          # :default) keys the registry so a component can declare several
          # independent bindings; redeclaring a name overrides it (inheritance
          # follows the Registry rules, like reactive_compute).
          def reactive_on_complete(name = :default, run:, **conditions)
            groups = Phlex::Reactive::ShowConditions.normalize(**conditions)
            Registry.write_entry(
              self, :on_completes, name.to_sym,
              OnCompleteDefinition.new(
                name: name.to_sym, conditions: groups,
                ops: normalize_on_complete_ops(name, run)
              )
            )
          end

          def reactive_on_completes
            Registry.resolve_hash(self, :on_completes, :reactive_on_completes)
          end

          # The wire JSON for the root's data-reactive-on-complete attr — a
          # frozen array of { any:, ops: } bindings, or nil when undeclared
          # (byte-stable wire). Memoized per class against the registry
          # generation (one integer compare) because reactive_attrs is the
          # token-signing hot path — the reactive_effect_attrs precedent.
          def reactive_on_complete_attr
            registry_gen = Registry.generation
            return @reactive_on_complete_attr if @reactive_on_complete_attr_gen == registry_gen

            bindings = reactive_on_completes
            @reactive_on_complete_attr =
              if bindings.empty?
                nil
              else
                bindings.values.map { { "any" => it.conditions, "ops" => it.ops } }.to_json.freeze
              end
            @reactive_on_complete_attr_gen = registry_gen
            @reactive_on_complete_attr
          end

          # Fetch one compute definition — the reader form matching
          # reactive_collection_def (issue #115). The bare reactive_compute(name)
          # getter above is a PERMANENT documented alias (it shipped in the same
          # minor series, #73); both stay, no deprecation.
          # Issue #186: use the plural reactive_computes hash directly.
          def reactive_compute_def(name)
            raise NoMethodError,
              "reactive_compute_def(#{name.inspect}) was removed in issue #186 — " \
              "use reactive_computes[#{name.inspect}]"
          end

          def reactive_compute?(name)
            raise NoMethodError,
              "reactive_compute?(#{name.inspect}) was removed in issue #186 — " \
              "use reactive_computes.key?(#{name.inspect})"
          end

          # Split the `inputs:` argument into [ordered names, types-or-nil].
          # THREE shapes, all degenerate cases of the issue-#183 PERMIT form
          # (bare symbols default to :number; a trailing Hash types the exceptions):
          #
          #   * a pure Hash ({ title: :string, qty: :number }) — the issue-#104 typed
          #     form. Ordered keys + a name→type map.
          #   * a permit Array with a trailing Hash ([:qty, { title: :string }]) —
          #     bare symbols typed :number, the Hash keys typed as declared. This is
          #     the one form the issue-#183 docs show.
          #   * a bare Array/symbol ([:price, :qty]) — the issue-#73 UNTYPED form.
          #     nil types, so the array-form wire stays byte-identical and the client
          #     keeps its numeric coercion.
          #
          # Validate + normalize a reactive_on_complete run: chain (issue #226)
          # to the raw [[op, args], …] pairs. A js chain is already validated at
          # build time; a raw list re-runs the attr allowlist — the same
          # defense-in-depth every raw-ops escape hatch gets (js([...]) /
          # broadcast_to(js: [...])). Loud on anything else — a dead or hostile
          # binding must fail at class load, never no-op in the browser.
          def normalize_on_complete_ops(name, run)
            pairs = run.is_a?(Phlex::Reactive::JS) ? run.ops : run
            unless pairs.is_a?(Array)
              raise ArgumentError,
                "reactive_on_complete #{name.inspect} run: takes a js chain " \
                "(js.dispatch(\"code:complete\")) or a raw [[op, args], ...] list, got #{run.class}"
            end
            raise ArgumentError, "reactive_on_complete #{name.inspect} got no ops — a dead binding" if pairs.empty?

            Phlex::Reactive::JS.assert_ops_allowed!(pairs) unless run.is_a?(Phlex::Reactive::JS)
            pairs
          end

          # Named after the shape it normalizes.
          def normalize_compute_inputs(inputs)
            return normalize_typed_compute_inputs(inputs) if inputs.is_a?(Hash)

            # dup before popping: Array(inputs) returns the SAME object for an array
            # arg, so an unguarded pop would mutate (or FrozenError on) a shared or
            # frozen inputs array the caller still holds.
            list = Array(inputs).dup
            trailing = list.last.is_a?(Hash) ? list.pop : nil
            names = list.map(&:to_sym)

            # No trailing type Hash → the untyped array form (nil types).
            return [names, nil] if trailing.nil?

            # Permit form: bare names default to :number; the trailing Hash types
            # the exceptions. Declaration order is bare names, then the Hash keys.
            typed = trailing.transform_keys(&:to_sym).transform_values(&:to_sym)
            ordered = names + typed.keys
            types = names.to_h { [it, :number] }.merge(typed)
            [ordered, types]
          end

          # A pure Hash of name => type (issue #104): ordered keys + the type map.
          def normalize_typed_compute_inputs(inputs)
            names = inputs.keys.map(&:to_sym)
            types = inputs.transform_keys(&:to_sym).transform_values(&:to_sym)
            [names, types]
          end

          # Normalize `mirror:` to { name => [id selectors] } (nil passes
          # through — no mirror declared). Each value may be one selector or a
          # list; every selector is validated LOUDLY at declare time against
          # MIRROR_ID_SELECTOR (id selectors only).
          def normalize_compute_mirror(mirror)
            return nil if mirror.nil?

            mirror.to_h do |name, selectors|
              list = Array(selectors).map(&:to_s)
              list.each do
                next if it.match?(MIRROR_ID_SELECTOR)

                raise ArgumentError,
                  "#{self}: mirror target #{it.inspect} for #{name.inspect} must be a single " \
                  "id selector (\"#some-id\") — cross-root text mirrors are declared, allowlisted " \
                  "targets, never arbitrary selectors"
              end
              [name.to_sym, list.freeze]
            end.freeze
          end

          # Rebuild a component instance from a verified identity payload. Called
          # by the action endpoint after the token signature is verified.
          #
          # A component may carry a record (re-found via GlobalID), signed state
          # (instance vars listed in reactive_state), or BOTH (the inline_edit
          # pattern: a record plus "which field / what mode"). We assemble the
          # init kwargs from whichever identity pieces are declared.
          def from_identity(payload)
            kwargs = {}

            if reactive_record_key
              if (gid = payload["gid"])
                record = GlobalID::Locator.locate(gid)
                raise(ActiveRecord::RecordNotFound, "reactive record missing") unless record

                kwargs[reactive_record_key] = record
              else
                # A DRAFT token (issue #208): Component::Identity signs no gid
                # for an unsaved (or nil) record. Omit the kwarg — the
                # component's initialize default seeds a fresh draft, mirroring
                # first render — so a draft parent can run real server actions
                # (its transient identity rides in the signed state instead).
                ensure_draft_default!
              end
            end

            if reactive_state_keys.any?
              state = payload.fetch("s", {})
              reactive_state_keys.each do
                # Use key presence, not the value: a signed `nil` (nullable state)
                # must round-trip distinctly. Only a genuinely absent key falls
                # back to the component's initialize default; `false` and `nil`
                # both survive.
                next unless state.key?(it.to_s)

                kwargs[it] = state[it.to_s]
              end
            end

            new(**kwargs)
          end

          # A draft token can only rebuild through the record kwarg's initialize
          # default (issue #208). A component whose initialize REQUIRES the
          # record can't render drafts — teach the fix instead of exploding
          # with a bare missing-keyword ArgumentError deep in new(**kwargs).
          def ensure_draft_default!
            return unless instance_method(:initialize).parameters.include?([:keyreq, reactive_record_key])

            raise Phlex::Reactive::Error,
              "#{self}: the action token carries no record gid (the #{reactive_record_key} was unsaved " \
              "when rendered — a draft), but initialize requires `#{reactive_record_key}:`. Give the " \
              "kwarg a default (e.g. `#{reactive_record_key}: nil` or a fresh record) so the draft " \
              "can rebuild through it."
          end
        end
      end
    end
  end
end
