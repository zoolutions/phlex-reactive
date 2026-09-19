# frozen_string_literal: true

module Phlex
  module Reactive
    module Component
      # The view-side helper surface of Component (issue #115): the reply/js
      # builders, the root-element attribute helpers (reactive_attrs/
      # reactive_root), the trigger builders (on/on_client) with their hint
      # vocabularies, the form-binding helpers (reactive_field/input/select/
      # text/busy_on/reactive_compute_attrs), and the nested-attributes
      # helpers. Everything a view_template spreads or calls — no registries,
      # no signing (those live in DSL and Identity).
      module Helpers
        extend ActiveSupport::Concern

        # The acting client's SSE connection id during the current action (nil
        # outside an action, or when the client isn't subscribed to a stream).
        # Pass it as `exclude:` when broadcasting from an action so the actor
        # doesn't receive the echo of its own change — it already gets the
        # action's HTTP response:
        #
        #   def send_message(body:)
        #     msg = ChatMessage.create!(room: @room, body:)
        #     ChatMessage::Item.broadcast_append_to("chat", @room,
        #       target: "messages", model: msg, exclude: reactive_connection_id)
        #   end
        def reactive_connection_id
          Phlex::Reactive.current_connection_id
        end

        # Manually satisfy the verify_authorized guard (issue #168) for a bespoke
        # authorization check the interceptor can't see — a hand-rolled policy, a
        # feature flag, an ownership comparison that doesn't go through one of
        # Phlex::Reactive.authorization_methods:
        #
        #   def publish
        #     raise NotAllowed unless @post.author == Current.user
        #     mark_authorized!
        #     @post.update!(published: true)
        #   end
        #
        # Call it only AFTER your check passes — it asserts "I have authorized
        # this action." A no-op when verify_authorized is off.
        def mark_authorized!
          Phlex::Reactive::Authorization.mark!
        end

        # Subject-bound reply builder — the preferred way to control an action's
        # reply. `reply.replace.flash(:error, msg)` reads cleaner than
        # `reply.replace.flash(:error, msg)`: the
        # component is the implicit subject (no `self` to thread) and there's no
        # constant to qualify (reply is a method, so a namespaced component needs
        # no `Response = …` alias). It returns the same immutable Response the
        # endpoint reads, so chaining and the legacy return-value contract are
        # unchanged. See Phlex::Reactive::Reply.
        #
        #   def archive       = reply.remove
        #   def go_home       = reply.redirect("/todos")
        #   def update(name:) = (@account.update!(name:); reply.morph)
        def reply
          Phlex::Reactive::Reply.new(self)
        end

        # An empty client-side op chain (issue #95) — the starting point for
        # on_client's DOM commands, mirroring how `reply` starts a Response chain:
        #   button(**on_client(:click, js.toggle("#menu"))) { "Menu" }
        # Immutable: each verb returns a new chain, so reuse never leaks ops.
        def js
          Phlex::Reactive::JS.new
        end

        # Root-element attributes: marks the element reactive and carries the
        # signed identity token. Spread onto the root:
        #   div(id:, **reactive_attrs) { ... }
        def reactive_attrs
          data = { controller: "reactive" }
          # A CLIENT-ONLY component (Phlex::Reactive::ClientBindings, issue #180)
          # has no Identity, so no token — the root is tokenless (show/filter/
          # compute need no signed round trip). reactive_token is private, so the
          # include-private `respond_to?` mirrors to_stream_token's guard.
          data[:reactive_token_value] = reactive_token if respond_to?(:reactive_token, true)
          # Client debug mode (issue #108): stamp the flag so the generic controller
          # console.groups every dispatch. STRING "true", not boolean — Phlex renders
          # a boolean-true attr VALUELESS, which getAttribute reads as "" (falsy in
          # JS), so the client's attr check would never fire (the on()/warn_unsaved
          # precedent). Off by default → no key, no string, zero client surface.
          data[:reactive_debug] = "true" if Phlex::Reactive.debug
          # Issue #237: the verbose gate for the client's zero-target op warning.
          # ON by default in dev/test (Rails.env.local?), so the papercut warning
          # works out of the box; production renders no attr and stays silent.
          data[:reactive_verbose] = "true" if Phlex::Reactive.verbose_errors
          # Field-name scope (issue #180): the client prefixes bare binding field
          # names with `scope[...]`. Omitted entirely when undeclared — byte-stable
          # wire for unscoped components.
          if self.class.respond_to?(:reactive_scope) && (scope = self.class.reactive_scope)
            data[:reactive_scope] = scope.to_s
          end
          # Effects (issue #215): the resolved global ⊕ component hooks ride the
          # root as data-reactive-effect-<hook> so the client's stream interceptor
          # knows how to animate this component. nil when off — no keys, byte-
          # stable wire. The fragment is a per-class memo (two integer compares).
          if self.class.respond_to?(:reactive_effect_attrs) && (effects = self.class.reactive_effect_attrs)
            data.merge!(effects)
          end
          # Completion bindings (issue #226): the declared reactive_on_complete
          # bindings ride the root as ONE JSON attr the client evaluates over
          # the owned fields (rising edge → run the ops). nil when undeclared —
          # no key, byte-stable wire. Per-class memo (one integer compare).
          if self.class.respond_to?(:reactive_on_complete_attr) &&
             (on_complete = self.class.reactive_on_complete_attr)
            data[:reactive_on_complete] = on_complete
          end
          { data: }
        end

        # The WHOLE reactive root in one spread (issue #48). reactive_attrs alone
        # doesn't emit `id:`, so `id:` and `data-controller="reactive"` can land on
        # DIFFERENT elements — putting `id:` on a child leaves the controller root's
        # `id` empty, which silently breaks token threading (the client self-matches
        # its next token by `this.element.id`) and 403s on the next action.
        #
        # reactive_root binds the id to the SAME element as reactive_attrs, so the
        # footgun is unbuildable:
        #   div(**reactive_root) { ... }                       # id + controller + token
        #   div(**reactive_root(class: "card")) { ... }        # add your own attrs
        #
        # mix deep-merges, so overrides add `class:`/`data:` without clobbering the
        # controller/token data: (a bare data: would). The id is resolved separately
        # (an explicit override wins as a clean replace, not a `mix` string-concat —
        # mix would join two String ids into "default override").
        #
        # Dirty tracking (issue #103, #184) is now a CLASS-LEVEL reactive_dirty
        # declaration, not a reactive_root kwarg. reactive_root reads
        # self.class.reactive_dirty_config and emits the SAME DOM as before: the
        # trackDirty descriptor on the root's data-action (mix token-joins, so a
        # caller's own data-action survives) UNLESS `only:` scoped tracking to named
        # fields, and — for warn_unsaved: true — the navigate-away marker (STRING
        # "true", since a boolean-true attr renders valueless → "" → falsy client-
        # side). The removed track_dirty:/warn_unsaved: kwargs raise a guided error.
        def reactive_root(**overrides)
          # A CLIENT-ONLY component (ClientBindings, issue #180) needs no #id —
          # there's no token to self-match by id. Use an explicit override, else
          # #id when the component defines one, else nothing (no id attr).
          reject_removed_dirty_kwargs!(overrides)
          root_id = overrides.delete(:id)
          root_id = id if root_id.nil? && respond_to?(:id)
          # Issue #183: bind a client-side compute AT THE ROOT — the descriptors +
          # the recompute delegation ride here so no field needs per-field wiring.
          # nil (the conditional-binding collapse) emits nothing.
          compute = overrides.delete(:compute)
          # Issue #184: dirty tracking is a class-level reactive_dirty declaration.
          dirty = self.class.reactive_dirty_config if self.class.respond_to?(:reactive_dirty_config)

          attrs = mix({ **reactive_attrs }, overrides)
          attrs = mix(attrs, { id: root_id }) unless root_id.nil?
          # Root-level delegation tracks the whole subtree UNLESS only: scoped it to
          # named fields (those carry their own descriptor via reactive_field).
          attrs = mix(attrs, { data: { action: "input->reactive#trackDirty" } }) if dirty && dirty[:only].nil?
          attrs = mix(attrs, { data: { reactive_warn_unsaved: "true" } }) if dirty&.dig(:warn_unsaved)
          attrs = mix(attrs, compute_binding(compute)) if compute
          attrs
        end

        # Issue #184: track_dirty:/warn_unsaved: on reactive_root are removed in
        # favor of the class-level reactive_dirty macro. Guided error naming it.
        def reject_removed_dirty_kwargs!(overrides)
          removed = overrides.keys & %i[track_dirty warn_unsaved]
          return if removed.empty?

          raise ArgumentError,
            "reactive_root(#{removed.first}:) was removed in issue #184 — declare " \
            "`reactive_dirty warn_unsaved: true` (class-level) instead."
        end

        # Attributes for an element that triggers an action.
        #   button(**on(:toggle)) { "○" }
        #   form(**on(:save, event: "submit")) { ... }
        #   input(**on(:update, event: "input", debounce: 300))  # live-as-you-type
        #
        # Extra keyword args become explicit params merged over collected form
        # fields. For click triggers we force type="button" so a bare button
        # inside a <form> can't submit it and cause a full-page navigation.
        #
        # `debounce:` (milliseconds) coalesces rapid events (e.g. keystrokes on an
        # "input" trigger) into ONE round trip fired after the quiet period — so
        # live-update-as-you-type doesn't POST per keystroke. A blur flushes a
        # pending dispatch so the last edit is never dropped. Omit it for the
        # immediate-dispatch default.
        #
        # `confirm:` (a message string) gates the action behind a confirmation
        # prompt (issue #52). Destructive reactive triggers can't use Hotwire's
        # `data-turbo-confirm` — the reactive controller calls preventDefault and
        # enqueues the POST itself, so Turbo's confirm handling never runs. The
        # client shows window.confirm(message) FIRST and bails before any
        # enqueue/debounce if the user declines (and prevents the native default so
        # a `submit` trigger can't navigate on cancel). Omit it for no prompt.
        #   button(**on(:destroy, confirm: "Really delete this item?")) { "Delete" }
        #
        # `event:` is interpolated verbatim into the Stimulus action descriptor
        # (`#{event}->reactive#dispatch`), so any Stimulus event string works —
        # including its native KEYBOARD FILTERS. Pass `event: "keydown.enter"` for
        # Enter-to-submit or `event: "keydown.esc"` for Escape-to-cancel, and the
        # action fires only on that key — no separate option, no client code, and
        # `key` stays free as an ordinary action-param name (on(:switch, key: …)):
        #   input(**on(:add, event: "keydown.enter"))      # Enter submits
        #   button(**on(:cancel, event: "keydown.esc"))     # Escape cancels
        #
        # Combobox keyboard navigation is the standalone reactive_listnav (issue
        # #181 removed the `on(…, listnav:)` kwarg — it duplicated reactive_listnav
        # while skipping its blank-selector validation). Compose it via mix:
        #   input(**mix(on(:search, event: "input", debounce: 300), reactive_listnav))
        # The verbatim JSON for an empty explicit-params payload. The common
        # trigger (on(:increment), no params) hits this on EVERY render — skipping
        # params.to_json (which re-serializes {} to the same "{}" each time) avoids
        # a per-render allocation while keeping the wire format byte-identical.
        EMPTY_PARAMS_JSON = "{}"

        # The keyboard filters appended to a listnav trigger's data-action. Each is
        # a client-only handler (no POST) except Enter, which clicks the highlighted
        # option's own reactive trigger. Stimulus binds these natively.
        LISTNAV_ACTIONS = [
          "keydown.down->reactive#listnavNext",
          "keydown.up->reactive#listnavPrev",
          "keydown.enter->reactive#listnavPick",
          "keydown.esc->reactive#listnavClose"
        ].freeze

        # Event modifiers (issue #80) — window:, once:, outside:, throttle: are
        # RESERVED keyword names on on() (no longer usable as free action params):
        #
        # `window: true` binds the trigger to the window (Stimulus's native
        # `@window` descriptor suffix) — for page-level events like scroll/resize.
        # `once: true` appends Stimulus's `:once` option, so the trigger fires at
        # most one round trip and then unbinds. Both are pure descriptor
        # composition. A window-bound trigger is NOT preventDefault-ed by the
        # client (it would kill every native click/submit on the page), and it
        # skips the forced type="button" (it isn't an in-form button trigger).
        #
        # `outside: true` fires the action only for events OUTSIDE this
        # component's ROOT (containment against the reactive root element) — the
        # close-a-dropdown-on-outside-click pattern. It implies `window: true`;
        # an event inside the root is a complete client-side no-op:
        #   div(**mix(reactive_root, on(:close_menu, outside: true))) { ... }
        #
        # `throttle:` (milliseconds) rate-limits a hot trigger LEADING-EDGE: the
        # first event fires immediately, further events are suppressed until the
        # window elapses (scroll/mousemove). Mutually exclusive with `debounce:`
        # (trailing-edge) — passing both raises ArgumentError.
        #   div(**mix(reactive_root, on(:track, event: "scroll", window: true, throttle: 250)))
        #
        # `optimistic:` (issue #98) — a small, ALWAYS-REVERSIBLE vocabulary of
        # COSMETIC hints the client applies the instant the trigger fires and
        # REVERTS if the round trip fails, so a click/toggle gives instant feedback
        # instead of waiting a full round trip. Hints are visual only — never data,
        # never computed values (that would be client state). Supported ops in the
        # hint hash:
        #   * toggle_class:/add_class:/remove_class: — a class string or array,
        #     applied to the TRIGGER (default) or to a `to:` selector scoped to the
        #     root (`to: :root` targets the root element itself).
        #   * checked: :keep — for a click-bound checkbox/radio, the client SKIPS
        #     its unconditional preventDefault so the native flip happens now
        #     (today the morph never even lets it flip). On failure, the flip is
        #     reverted.
        #   * hide: true — hides the target immediately (the `hide: true` + a
        #     `reply.remove` action is the instant delete-a-row recipe: the hint
        #     hides it, the reply removes it; a failure snaps it back).
        # Success does NO cleanup: a reply that re-renders the root overwrites the
        # hint with server truth; a reply that does NOT re-render the root
        # (reply.remove / streams-only) LEAVES the hint standing — that's the
        # instant-delete working as intended.
        #   input(type: "checkbox", checked: @todo.done,
        #     **mix(on(:toggle, event: "change", optimistic: { checked: :keep }), name: "done"))
        #   button(**on(:destroy, confirm: "Delete?", optimistic: { hide: true, to: :root })) { "Delete" }
        # `busy:` (issue #181) — declarative per-trigger pending states, Livewire's
        # wire:loading + phx-disable-with without a Stimulus controller. It shares
        # optimistic:'s key vocabulary and normalizer; the ONLY difference is the
        # lifecycle: a busy: hint applies the moment the request is ENQUEUED
        # (covering the queue wait, not just the fetch) and reverts on SETTLE (any
        # completion), where optimistic: reverts only on FAILURE. `busy:` is a
        # String or a Hash:
        #   * "Saving…"             — String shorthand for { disable: true, text: … }
        #   * disable: true         — disable the trigger while pending
        #   * add_class:/remove_class:/toggle_class: "…" / [ … ] — class op on the
        #                             trigger (or a `to:` selector scoped to the root)
        #   * hide:/show: true      — hide/show the target while pending
        #   * text: "Saving…"       — swap the trigger's innerHTML while pending
        #   * to: :root / "sel"     — target the ops at the root or a selector
        # checked: :keep is optimistic-ONLY (a native flip has no settle-revert
        # meaning). The trigger/root also always carry `data-reactive-busy` for the
        # whole pending window regardless of these hints, so an app styles a spinner
        # with `[data-reactive-busy] .spinner { display: block }` and zero Ruby; see
        # busy_on for scoped indicators.
        #   button(**on(:save, busy: "Saving…")) { "Save" }
        #   button(**on(:destroy, confirm: "Sure?", busy: { add_class: "opacity-50" })) { "Delete" }
        def on(action_name, event: "click", debounce: nil, throttle: nil, confirm: nil,
               window: false, once: false, outside: false, optimistic: nil, busy: nil,
               **params)
          reject_removed_on_kwargs!(action_name, params)
          # A typo'd or forgotten action renders fine and only surfaces as an
          # opaque 403 at CLICK time (the endpoint's default-deny). Under
          # verbose_errors (dev + test), fail loudly at RENDER time instead —
          # listing the declared actions — the same courtesy reactive_compute_attrs
          # gives an undeclared compute (issue #105). Placed FIRST, before any attr
          # building. Production (flag off) keeps the permissive emit: a stale page
          # after a deploy that removed an action must not 500 on render. This is a
          # dev-time aid, NOT the security boundary — default-deny stays the
          # SERVER's enforcement. on_client triggers are not declared actions (no
          # registry), so they are never checked here.
          #
          # The check applies ONLY to a component that declares actions of its own.
          # A component with an EMPTY registry is a cross-component dispatch helper
          # — a child row that renders a trigger for its CONTAINER's action and
          # sends the container's token (e.g. NotificationRowComponent → the list's
          # :dismiss). It can't self-validate against a registry it doesn't own, so
          # the guard would false-positive; skipping the empty case keeps the
          # pattern working while still catching a typo in a component that DOES
          # declare actions (the issue's target — on(:togle) where :toggle exists).
          # verbose_errors is checked FIRST so production (flag off) short-circuits
          # before touching the registry — zero added cost on the hot path.
          if Phlex::Reactive.verbose_errors &&
             (actions = self.class.reactive_actions).any? && !actions.key?(action_name.to_sym)
            raise Phlex::Reactive::Error,
              "#{self.class} has no declared action #{action_name.to_sym.inspect} " \
              "(declared: #{actions.keys.inspect})"
          end

          if debounce && throttle
            raise ArgumentError,
              "on(#{action_name.inspect}) got both debounce: and throttle: — they are mutually " \
              "exclusive (debounce is trailing-edge, throttle is leading-edge); pick one"
          end

          window_bound = window || outside
          action = "#{event}#{"@window" if window_bound}->reactive#dispatch#{":once" if once}"
          attrs = {
            data: {
              action:,
              reactive_action_param: action_name.to_s,
              reactive_params_param: params.empty? ? EMPTY_PARAMS_JSON : params.to_json
            }
          }
          attrs[:data][:reactive_debounce_param] = debounce if debounce
          attrs[:data][:reactive_throttle_param] = throttle if throttle
          apply_confirm!(attrs[:data], confirm) if confirm
          attrs[:data][:reactive_optimistic_param] = pending_hint_json(optimistic, action_name, :optimistic) if optimistic
          attrs[:data][:reactive_busy_param] = pending_hint_json(busy, action_name, :busy) if busy
          # STRING "true", not boolean: Phlex renders a `true` attribute VALUELESS
          # (data-reactive-outside-param), which Stimulus's param reader sees as ""
          # — falsy in JS, so the guard silently never fires. The explicit ="true"
          # typecasts to a real boolean on the client.
          attrs[:data][:reactive_outside_param] = "true" if outside
          # The client decides preventDefault behavior from event.params (never by
          # sniffing the descriptor), so EVERY window binding flags the param.
          attrs[:data][:reactive_window_param] = "true" if window_bound
          # Force type="button" for click triggers so a bare button inside a <form>
          # can't submit it — EXCEPT when checked: :keep is declared: that hint's
          # whole point is to let a click-bound checkbox/radio flip natively, and a
          # forced type="button" would destroy the very control being toggled
          # (issue #98). The caller supplies the real type="checkbox"/"radio".
          attrs[:type] = "button" if event == "click" && !window_bound && !optimistic_keeps_native?(optimistic)
          attrs
        end

        # Attributes for a CLIENT-ONLY trigger (issue #95): binds a DOM event to a
        # chain of declarative DOM ops (Phlex::Reactive::JS) that the generic
        # controller's runOps action applies in the browser — NO token, NO params,
        # NO POST, ever. The zero-round-trip sibling of on():
        #
        #   button(**on_client(:click, js.toggle("#menu"))) { "Menu" }
        #   # tabs, one line per tab, no Stimulus controller:
        #   button(**on_client(:click, js.hide(".panel").show("#panel-2")))
        #
        # `window:`, `once:`, and `outside:` compose exactly like on()'s event
        # modifiers (#80): outside-click-to-close a dropdown is
        #   div(**mix(reactive_root, on_client(:click, js.hide("#menu"), outside: true)))
        # Window-bound triggers are never preventDefault-ed by the client and skip
        # the forced type="button".
        #
        # Ops are EPHEMERAL UI: any server re-render of the component (an action
        # reply, a broadcast, a morph) rebuilds from server state and resets
        # whatever they toggled — by design (the LiveView JS-commands caveat). Use
        # a signed action for state that must survive re-renders.
        #
        # Validation is loud: only a non-empty Phlex::Reactive::JS chain is
        # accepted — a dead trigger should fail at render, not no-op in the
        # browser.
        def on_client(event, ops, window: false, once: false, outside: false, confirm: nil)
          unless ops.is_a?(Phlex::Reactive::JS)
            raise ArgumentError,
              "on_client expects a Phlex::Reactive::JS chain (e.g. js.toggle(\"#menu\")), " \
              "got #{ops.class}"
          end
          raise ArgumentError, "on_client(#{event.inspect}) got no ops — a dead trigger" if ops.empty?

          event = event.to_s
          # Issue #226: requestSubmit dispatches the very `submit` event this
          # trigger would be bound to — an infinite loop. Loud at render.
          if event == "submit" && ops.ops.any? { |name, _| name == "submit" }
            raise ArgumentError,
              "on_client(:submit, js.submit) would re-fire itself — requestSubmit dispatches the " \
              "submit event this trigger is bound to. Bind the submit op to another event " \
              "(change/input), or gate it behind a reducer's $ops / reactive_on_complete."
          end
          window_bound = window || outside
          attrs = {
            data: {
              action: "#{event}#{"@window" if window_bound}->reactive#runOps#{":once" if once}",
              reactive_ops_param: ops.to_json
            }
          }
          # STRING "true", not boolean — same Phlex valueless-attribute trap as
          # on()'s flags above.
          attrs[:data][:reactive_outside_param] = "true" if outside
          attrs[:data][:reactive_window_param] = "true" if window_bound
          # Issue #228: mark a clipboard-reading trigger so the client can gate
          # its visibility on availability — on connect the controller sets
          # hidden = !navigator.clipboard.readText. Render the trigger `hidden`
          # for reveal-when-available (a dead paste button never shows).
          attrs[:data][:reactive_clipboard] = "true" if ops.ops.any? { |name, _| name == "paste_into" }
          # Issue #178: confirm: gates the client-op chain behind the SAME
          # overridable confirmResolver on(:action, confirm:) uses (#52/#55). Emits
          # the identical data-reactive-confirm-param; the client's runOps prompts
          # via confirmResolver BEFORE applying the ops (a falsy resolve cancels
          # the chain), so a destructive client op gets the themed dialog with no
          # round trip. Issue #179: a Hash confirm: is CONDITIONAL — same shared
          # apply_confirm! branches String vs Hash for both on and on_client.
          apply_confirm!(attrs[:data], confirm) if confirm
          attrs[:type] = "button" if event == "click" && !window_bound
          attrs
        end

        # Bind a form control's `name` to an action param so its value travels with
        # the action — instead of hand-writing the magic `name: "value"` on every
        # input and silently getting no params when you forget it (issue #23).
        # Returns a Phlex attributes hash to spread onto any control:
        #   input(**reactive_field(:value, value: @record.name))
        #   select(**reactive_field(:status)) { ... }
        # Extra attrs merge over the binding; an explicit name: still wins (escape
        # hatch). The trigger (on(:save)) stays on the button, not the field — so
        # focusing the input doesn't dispatch and collapse edit mode.
        #
        # Dirty tracking is class-level now (issue #184): the per-field `dirty:`
        # kwarg is REMOVED (reject_removed_field_dirty! raises a guided error). A
        # field carries the trackDirty descriptor only when `reactive_dirty only:`
        # names it (field_dirty_tracked?) — otherwise the root delegates for the
        # whole subtree via reactive_root. The client behavior is unchanged (issue
        # #103): a change re-scans this root's owned fields and marks the changed
        # ones `data-reactive-dirty` (the root gets a count); NO client state ships —
        # the baseline is the DOM's own `defaultValue`/`defaultChecked`/
        # `defaultSelected` from the last server render (dirty = current ≠ default).
        # The descriptor deep-merges via mix, so a caller's own data-action is
        # token-joined, not clobbered (AGENTS.md Never-Do #8).
        def reactive_field(param, **attrs)
          # Issue #184: the removed dirty: kwarg lands in **attrs — catch it and
          # print the reactive_dirty rewrite.
          reject_removed_field_dirty!(attrs)
          # Under reactive_scope, emit the SCOPED wire name (name="invoice[date]")
          # so the POST arrives bracketed (the endpoint unwraps one level) AND the
          # field matches the client show/compute resolvers, which already query
          # [name="scope[x]"]. An explicit name: in attrs still wins via the spread
          # (a third-party wire name, never re-scoped) — the escape hatch.
          binding_attrs = { name: scoped_field_name(param), **attrs }
          # Per-field dirty descriptor when reactive_dirty only: names this field
          # (issue #184) — otherwise the root delegates for the whole subtree.
          return binding_attrs unless field_dirty_tracked?(param)

          mix(binding_attrs, { data: { action: "input->reactive#trackDirty" } })
        end

        # The removed reactive_field(dirty:) kwarg (issue #184) — now a guided error.
        def reject_removed_field_dirty!(attrs)
          return unless attrs.key?(:dirty)

          raise ArgumentError,
            "reactive_field(dirty:) was removed in issue #184 — declare " \
            "`reactive_dirty only: %i[...]` (class-level) instead."
        end

        # True when reactive_dirty only: names this field, so it carries its own
        # trackDirty descriptor (issue #184).
        def field_dirty_tracked?(param)
          return false unless self.class.respond_to?(:reactive_dirty_config)

          only = self.class.reactive_dirty_config&.dig(:only)
          only&.include?(param.to_sym) || false
        end

        # The wire name for a bare field param: `scope[param]` when the component
        # declares reactive_scope, else the bare param. Read self.class.reactive_scope
        # the way reactive_attrs does (helpers.rb) so scoped + unscoped stay aligned.
        def scoped_field_name(param)
          scope = self.class.reactive_scope if self.class.respond_to?(:reactive_scope)
          scope ? "#{scope}[#{param}]" : param.to_s
        end

        # REMOVED in issue #184 — one binding helper (reactive_field); the element
        # is the caller's: input(**reactive_field(:value, value: @record.name)).
        # Raises a guided error printing that rewrite.
        def reactive_input(param, **)
          raise ArgumentError,
            "reactive_input was removed in issue #184 — use " \
            "input(**reactive_field(#{param.inspect}, …)) (one binding helper; the element is yours)."
        end

        # Mirror a compute output (or a declared input) into a TEXT NODE — a live
        # preview heading, a character counter, a "Hello, {name}" greeting (issue
        # #104). The text sibling of reactive_field: reactive_field binds a FORM
        # CONTROL; reactive_text binds a plain span the client writes via
        # textContent (XSS-safe by construction — never innerHTML).
        #
        #   h2 { reactive_text(:title_preview, @post.title) }
        #   small { reactive_text(:char_count) }
        #
        # The span carries data-reactive-text=<name> and NO `name` attribute, so
        # #collectFields never sweeps it into the POSTed params. `initial` seeds the
        # first paint — the SERVER render must seed the same derived value the
        # reducer would, or a morph repaints stale text (same reconcile contract
        # reactive_compute documents). Extra attrs merge over the binding.
        def reactive_text(name, initial = nil, **attrs)
          # Issue #183: with no explicit initial, seed the first paint from
          # reactive_values (Phase A) when the component declares it and covers this
          # name — so the server render matches what the reducer would paint (the
          # same no-flash reconcile contract reactive_show's first paint uses).
          initial = reactive_text_seed(name) if initial.nil?
          span(**mix({ data: { reactive_text: name.to_s } }, attrs)) { initial }
        end

        # The reactive_values first-paint seed for a reactive_text name, stringified
        # the way the client reports a field (via show_value_string), or nil when
        # the component declares no reactive_values or doesn't cover the name.
        def reactive_text_seed(name)
          return nil unless respond_to?(:reactive_values)

          values = reactive_values
          return nil unless values.is_a?(Hash) && values.key?(name.to_sym)

          show_value_string(values[name.to_sym])
        end

        # Value-conditional visibility (issue #180) — the x-show / data-show /
        # wire:show equivalent, entirely client-side, in ONE Ruby-native
        # conditions language. Spread onto the element to show/hide; declare an
        # if:/if_any:/unless: condition with where-style values, and the generic
        # controller toggles `hidden` from the fields' CURRENT values on every
        # input/change — no round trip, no token, no bespoke Stimulus controller.
        #
        # THE VALUE LANGUAGE (Phlex::Reactive::ShowConditions):
        #   Hash    = AND (multiple keys ANDed)          if: { a: "x", b: "y" }
        #   Array   = membership                          if: { size: %w[l xl] }
        #   Range   = threshold (10.. / ..10 / ...10 / 10..20)  if: { qty: 10.. }
        #   true/false = checkbox checked-state           if: { gift: true }
        #   nil     = blank                               if: { note: nil }
        #   unless: = negation (composes with if:/if_any:)
        #
        #   div(**reactive_show(unless: { mode: "off" }))          { "details" }
        #   div(**reactive_show(if: { size: %w[l xl] }))           { "surcharge" }
        #   div(**reactive_show(if: { qty: 10.. }))                { "bulk note" }
        #   # OR-of-AND — director OR (shareholder AND role == "individual"):
        #   div(**reactive_show(if_any: [
        #     { director: true },
        #     { shareholder: true, role: "individual" }
        #   ]))
        #
        # There is no expression surface — every term is a declared literal, so
        # the same default-deny posture as before. Everything normalizes to ONE
        # DNF wire attr (data-reactive-show='{"any":[[term,…],…]}').
        #
        # FIRST PAINT is computed for you: declare reactive_values (an instance
        # method returning { field => value }) and every binding whose fields are
        # all provided renders the correct initial `hidden:` server-side — no
        # per-section mirror method, no flash. An explicit `hidden:` always wins;
        # a per-call `values:` override merges over reactive_values.
        #
        # `disable: true` disables the section's OWNED controls while it is hidden
        # so a switched-away value never submits. `reactive_scope :form` lets
        # bindings use bare field symbols ([name="form[field]"] on the client).
        #
        # Scope: presentational only, strictly less powerful than the js ops — it
        # reads owned fields (#15 ownership) and toggles `hidden` (+ optionally
        # `disabled`) on owned elements. Extra attrs deep-merge over the binding
        # (mix), like reactive_field.
        def reactive_show(field = nil, **options)
          reject_legacy_show_surface!(field, options)

          conditions = options.slice(*SHOW_CONDITION_KEYS)
          disable = options.delete(:disable)
          values_override = options.delete(:values)
          attrs = options.except(*SHOW_CONDITION_KEYS)

          groups = Phlex::Reactive::ShowConditions.normalize(**conditions)
          data = { reactive_show: { "any" => groups }.to_json }
          data[:reactive_show_disable] = "true" if disable

          result = mix({ data: }, attrs)
          apply_first_paint_hidden(result, groups, values_override)
        end

        # Client-side option filtering for the searchable combobox (issue #163)
        # — the "preload + type to narrow" half of #72's keyboard nav, entirely
        # client-side. Spread onto the ROOT (mix with reactive_root); it names
        # the input whose value drives the filter and the option elements to
        # show/hide, and the generic controller toggles `hidden` on every
        # keystroke by substring-matching each option's haystack — no round
        # trip, no token, no bespoke per-feature controller:
        #
        # Issue #186: name the FIELD that drives the filter — reactive_filter(:q)
        # compiles :q to [name="q"] (scope-aware) and defaults option to the
        # [role=option] convention. group:/empty: stay opt-in; any selector kwarg
        # overrides a convention:
        #
        #   div(**mix(reactive_root, reactive_filter(:q, empty: "#no-matches"))) do
        #     input(name: "q", type: "search", **reactive_listnav)  # listnav → [role=option]
        #     …
        #   end
        #
        # Each option's haystack is its `data-reactive-filter-text` attribute
        # (server-rendered — pack in synonyms/categories), falling back to the
        # option's own text. Matching is a case-folded substring test — a
        # DECLARED literal match, never an expression (no eval surface, the
        # reactive_show posture). `group:` hides any group element whose every
        # contained option is hidden; `empty:` reveals the no-matches node when
        # 0 options are visible. The client seeds at connect and re-syncs after
        # a morph; selectors resolve WITHIN this root only (#15 ownership).
        #
        # Filtering composes with reactive_listnav (Arrow/Enter/Escape skip
        # hidden options) and each option's own on(:select, …) trigger —
        # selection still round-trips as a signed action; only FILTERING is
        # local. Blank selectors raise: a dead binding must fail at render.
        #
        # Issue #224: `input:` is the ESCAPE HATCH — a raw CSS selector for the
        # one driving input the field form can't express: a deliberately
        # NAME-LESS query input inside a real POST form (a named input would
        # submit a stray param), targeted by id. A form builder (phlex-forms'
        # tag_field) computes that id per instance. Verbatim, never re-scoped;
        # exactly one of field/input: per call — the field form stays the
        # blessed default:
        #   reactive_filter(input: "#user_tags_query")
        def reactive_filter(field = nil, input: nil, option: nil, group: nil, empty: nil)
          # nil-presence, NOT truthiness: `input: cond && "#sel"` with cond false
          # must fail loudly in filter_selector! below (a boolean is never a
          # selector), never slip into the field branch and emit a dead binding.
          if field && !input.nil?
            raise ArgumentError,
              "reactive_filter takes ONE driving-input form — a field name (reactive_filter(:q), " \
              "scope-aware) OR input: (a raw CSS selector for a name-less input), not both"
          end
          if field.nil? && input.nil?
            raise ArgumentError,
              "reactive_filter needs a field name — reactive_filter(:q) — or the input: " \
              "escape hatch (a raw CSS selector, e.g. input: \"#tags_query\")"
          end

          data = {
            # Compile the field to a scoped [name="…"] selector (same scope convention
            # reactive_field uses, so the filter input aligns with its own field) — or
            # take the input: selector verbatim (issue #224).
            reactive_filter_input: input.nil? ? %([name="#{scoped_field_name(field)}"]) : filter_selector!(:input, input),
            # option defaults to the [role=option] convention; a kwarg overrides it.
            reactive_filter_option: option ? filter_selector!(:option, option) : "[role=option]"
          }
          # group/empty stay OPT-IN (no convention default — a default would change the
          # byte-stable wire and always-emit an attribute the client would then query).
          data[:reactive_filter_group] = filter_selector!(:group, group) if group
          data[:reactive_filter_empty] = filter_selector!(:empty, empty) if empty

          { data: }
        end

        # STANDALONE combobox keyboard navigation (issue #163) — the same
        # Arrow/Enter/Escape wiring `on(…, listnav:)` appends, without the
        # dispatch descriptor. A preload-and-filter combobox input fires NO
        # action (filtering is pure client), so it can't carry on(); spread
        # this onto the input instead:
        #
        #   input(id: "search", type: "search", **reactive_listnav("[role=option]"))
        #
        # Arrow keys move the client-side highlight among the (visible) options,
        # Enter picks the highlighted one by clicking its own reactive trigger
        # (selection stays a signed action), Escape clears. Combine with other
        # attrs via mix so a caller's data-action token-joins, not clobbers.
        def reactive_listnav(option_selector = "[role=option]")
          {
            data: {
              action: LISTNAV_ACTIONS.join(" "),
              reactive_listnav_option_param: filter_selector!(:selector, option_selector)
            }
          }
        end

        # Tag-chip input (issue #203) — the composed combobox/tags primitive.
        # Spread onto the ROOT (mix with reactive_root); it names the hidden
        # field that stores the COMMA-JOINED value, and the generic controller
        # maintains that field + the chip list entirely client-side. The value
        # is FORM state (like text in an input), never component state — so
        # add/remove round-trips nothing; the surrounding form submit carries
        # the joined value and the server splits it (`tags.split(",")`).
        #
        #   div(**mix(reactive_root, reactive_tags(:tags), reactive_filter(:tag_query))) do
        #     input(type: :hidden, **reactive_field(:tags), value: @tags.join(","))
        #     div(data: { reactive_tags_list: true }) { }             # chips render here
        #     template(data: { reactive_tags_template: true }) do     # the chip markup (server-owned)
        #       span(class: "chip") do
        #         span(data: { reactive_tag_text: true })             # the client writes the tag here (textContent)
        #         button(**reactive_tags_remove) { "×" }              # the client fills the tag param per chip
        #       end
        #     end
        #     input(name: "tag_query", **mix(reactive_listnav, reactive_tags_add))
        #     button(**reactive_tags_option("Ruby")) { "Ruby" }       # preloaded options, filter narrows them
        #   end
        #
        # The chip list is a CLIENT PROJECTION of the hidden field: every sync
        # rebuilds the chips by cloning the <template> (textContent writes only
        # — never innerHTML), so the hidden value is the single source of truth
        # and a server re-render/morph re-seeds cleanly. An option whose tag is
        # already selected is hidden and marked data-reactive-tags-selected
        # (reactive_filter keeps it hidden through re-filters). Tags dedupe
        # case-insensitively, keeping the first casing.
        #
        # Composes with reactive_filter (type to narrow — same driving input)
        # and reactive_listnav (Arrow/Enter/Escape; Enter picks the highlighted
        # option via its own tagsPick trigger, and reactive_tags_add only adds
        # the TYPED text when nothing is highlighted — no double add).
        #
        # Issue #224: `name:` is the ESCAPE HATCH for an instance-dynamic wire
        # name — a form builder (phlex-forms' tag_field) computes "user[tags]"
        # per instance, which the class-level reactive_scope compile can't
        # express. Verbatim, NEVER re-scoped (reactive_field's explicit-name
        # precedent); exactly one of field/name: per call:
        #   reactive_tags(name: "user[tags]")
        def reactive_tags(field = nil, name: nil)
          # nil-presence, NOT truthiness: `name: cond && "user[tags]"` with cond
          # false must fail loudly in verbatim_name_selector!, never silently
          # fall through to the field branch.
          unless name.nil?
            if field
              raise ArgumentError,
                "reactive_tags takes ONE field form — a field name (reactive_tags(:tags), scope-aware) " \
                "OR name: (a verbatim wire name, never re-scoped), not both"
            end
            return { data: { reactive_tags_field: verbatim_name_selector!(:reactive_tags, name) } }
          end

          if field.nil? || field.to_s.strip.empty?
            raise ArgumentError,
              "reactive_tags needs a field name — reactive_tags(:tags) — or the name: " \
              "escape hatch (a verbatim wire name, e.g. name: \"user[tags]\")"
          end

          # Compile the field to a scoped [name="…"] selector, the reactive_filter
          # convention — so the hidden field written via reactive_field(:tags)
          # resolves under reactive_scope too.
          { data: { reactive_tags_field: %([name="#{scoped_field_name(field)}"]) } }
        end

        # The Enter-to-add trigger for the tags query input (issue #203) — a
        # CLIENT-ONLY keyboard action (no dispatch descriptor, no POST). Mix it
        # AFTER reactive_listnav so Enter prefers the highlighted option
        # (listnavPick preventDefaults; tagsAdd then skips), and free text adds
        # only when nothing is highlighted:
        #   input(name: "tag_query", **mix(reactive_listnav, reactive_tags_add))
        # Enter never submits the enclosing form — the client preventDefaults.
        def reactive_tags_add
          { data: { action: "keydown.enter->reactive#tagsAdd" } }
        end

        # A preloaded option row that ADDS its tag on click (issue #203) — the
        # tags sibling of the combobox's on(:select) option, but CLIENT-ONLY
        # (form state, no POST). Emits the [role=option] convention (so
        # reactive_filter/reactive_listnav see it), the forced type="button" (a
        # bare button inside a <form> would submit it), and the tag value the
        # client reads. Compose extra attrs (the filter haystack, a testid) via
        # mix. The tag can't contain a comma — it would corrupt the joined value.
        def reactive_tags_option(tag)
          {
            type: "button",
            role: "option",
            data: {
              action: "click->reactive#tagsPick",
              reactive_tag_param: tags_tag!(:reactive_tags_option, tag)
            }
          }
        end

        # A chip's remove button (issue #203) — client-only, no POST. Two forms:
        # inside the <template data-reactive-tags-template> chip, call it with NO
        # tag (the client fills data-reactive-tag-param per cloned chip); on a
        # server-rendered initial chip, pass the tag explicitly:
        #   button(**reactive_tags_remove(tag)) { "×" }
        def reactive_tags_remove(tag = nil)
          attrs = { type: "button", data: { action: "click->reactive#tagsRemove" } }
          attrs[:data][:reactive_tag_param] = tags_tag!(:reactive_tags_remove, tag) unless tag.nil?
          attrs
        end

        # Draft nested-attribute rows (issue #208) — the "new parent + child
        # rows" primitive. A form that builds child rows BEFORE the parent
        # exists (a new order accumulating line items) can't be a reactive
        # collection: an unsaved parent has no gid to sign, so there is nothing
        # to round-trip. These helpers run that pre-save window entirely
        # CLIENT-SIDE, the reactive_tags posture: the rows are FORM state (like
        # text in an input), never component state — add/remove round-trips
        # nothing, and the surrounding REAL form submit carries Rails'
        # accepts_nested_attributes_for names so the server reconciles parent +
        # rows in ONE create.
        #
        # The wiring (all inside one reactive root, itself inside the real
        # <form> that will POST the parent):
        #
        #   div(**reactive_root) do
        #     div(**reactive_nested_list(:line_items)) { }            # rows land here
        #     template(**reactive_nested_template(:line_items)) do    # ONE row's markup (server-owned)
        #       div(**reactive_nested_row) do
        #         input(name: nested_field_name(:line_items, :quantity))  # …[NEW_ROW][quantity]
        #         button(**reactive_nested_remove) { "×" }
        #       end
        #     end
        #     button(**reactive_nested_add(:line_items)) { "Add row" }
        #   end
        #
        # Clicking add clones the template and swaps every NEW_ROW in the
        # clone's name/id/for attributes for a fresh unique index, so each row
        # posts as its own `…_attributes[<index>][field]` group. Remove on a
        # draft row deletes it from the DOM; remove on a row carrying a hidden
        # `[_destroy]` input (a persisted row in an edit form, rendered with
        # nested_field_name(index: item_index)) marks it "1" and hides the row
        # — Rails destroys it on save. The DOM is the single source of truth;
        # a server re-render of the root REPLACES the rows, so keep replace-
        # shaped actions out of a root holding unsent draft rows.
        #
        # Several collections can share one root — every marker/trigger is
        # keyed by the association name. Nesting a collection INSIDE another's
        # template is not supported (the placeholder swap would hit both).
        # Once the parent is saved, the persisted flow takes over: the same row
        # markup renders with real indexes, or graduates to a reactive
        # collection (reactive_collection + reply.append/remove).

        # The index placeholder a template row carries in its field names; the
        # client swaps it for a fresh unique index on every add. Referenced by
        # both sides of the wire — change it nowhere.
        NESTED_NEW_ROW = "NEW_ROW"

        # The Rails nested-attributes wire name for one row field — the name
        # accepts_nested_attributes_for expects. Defaults to the template
        # placeholder; pass index: for a server-rendered row. Scope-aware: the
        # `<association>_attributes` base goes through reactive_scope FIRST, so
        # a `reactive_scope :order` component emits
        # order[line_items_attributes][3][quantity] (never a nested-bracket
        # corruption of the scope wrap).
        #
        # Issue #224: `scope:` is the per-call ESCAPE HATCH — a form builder's
        # object name is per-instance ("order", or itself bracketed for a
        # nested fieldset: "user[profile]"), which the class-level
        # reactive_scope can't express. Used verbatim as the wrap and WINS over
        # reactive_scope:
        #   nested_field_name(:line_items, :quantity, scope: "order")
        #   # => order[line_items_attributes][NEW_ROW][quantity]
        def nested_field_name(association, field, index: NESTED_NEW_ROW, scope: nil)
          nested_identifier!(:nested_field_name, :association, association)
          nested_identifier!(:nested_field_name, :field, field)
          unless index.to_s == NESTED_NEW_ROW || index.to_s.match?(/\A\d+\z/)
            raise ArgumentError,
              "nested_field_name index: must be an integer or the NEW_ROW placeholder, " \
              "got #{index.inspect} — anything else corrupts the bracketed wire name"
          end

          base = :"#{association}_attributes"
          prefix = scope.nil? ? scoped_field_name(base) : "#{nested_scope!(scope)}[#{base}]"
          "#{prefix}[#{index}][#{field}]"
        end

        # The container cloned rows land in — one per association, inside the
        # root. Server-rendered rows (an edit form's persisted children) render
        # inside it too.
        #
        # `as: :json` (issue #208) switches the SUBMIT wire from Rails'
        # accepts_nested_attributes_for names to ONE hidden JSON field — for an
        # app whose controller already parses a serialized JSON param
        # (`JSON.parse(params[:order][:todos])`) instead of nested attributes.
        # The container keeps its plain marker (nestedAdd/Remove still key on
        # it), and gains data-reactive-nested-json plus a scope-aware selector
        # naming the hidden field the client mirrors the rows into on every
        # add/remove/input. The default (:attributes) is unchanged — the plain
        # accepts_nested_attributes_for wire.
        #
        # Issue #224: `name:` is the verbatim ESCAPE HATCH for that hidden
        # field's wire name — a form builder's "order[todos]" the class-level
        # reactive_scope compile can't express. JSON-mode only (the
        # :attributes mode has no field to name); never re-scoped:
        #   reactive_nested_list(:todos, as: :json, name: "order[todos]")
        def reactive_nested_list(association, as: :attributes, name: nil)
          assoc = nested_identifier!(:reactive_nested_list, :association, association)
          data = { reactive_nested_list: assoc }
          if as == :attributes
            unless name.nil?
              raise ArgumentError,
                "reactive_nested_list(name:) only applies to as: :json — it names the hidden JSON " \
                "sync field; the :attributes mode has no field to name"
            end
            return { data: }
          end

          unless as == :json
            raise ArgumentError,
              "reactive_nested_list(as:) takes :attributes (the default, Rails nested-attribute names) " \
              "or :json (serialize the rows into one hidden JSON field), got #{as.inspect}"
          end

          # JSON mode: mark the container and name the hidden field the client
          # keeps in sync — a scope-aware [name="…"] selector, the same
          # convention reactive_tags/reactive_filter use so the field resolves
          # under reactive_scope too. name: takes the wire name verbatim
          # (issue #224).
          data[:reactive_nested_json] = assoc
          # nil-presence, NOT truthiness (the reactive_tags rationale): a falsy
          # non-nil name: must fail loudly in verbatim_name_selector!.
          data[:reactive_nested_json_field] =
            if name.nil?
              %([name="#{scoped_field_name(association)}"])
            else
              verbatim_name_selector!(:reactive_nested_list, name)
            end
          { data: }
        end

        # The <template> holding ONE row's markup (server-owned, inert until
        # cloned). Field names inside use nested_field_name's placeholder form.
        def reactive_nested_template(association)
          { data: { reactive_nested_template: nested_identifier!(:reactive_nested_template, :association,
            association) } }
        end

        # The row wrapper marker — what nestedRemove resolves from its trigger
        # (closest). Spread on the template row's outermost element AND on
        # server-rendered rows, so both remove the same way.
        def reactive_nested_row
          { data: { reactive_nested_row: true } }
        end

        # The add-a-row trigger — CLIENT-ONLY (no dispatch descriptor, no
        # POST). Forced type="button": a bare button inside the surrounding
        # real <form> would submit it.
        #
        # FILL-THEN-ADD (issue #208 Scenario A). By default add clones the
        # template and focuses the new row's first field — INLINE-EDIT (you
        # type INTO the row). But a common form shape puts the add controls
        # OUTSIDE the row (a preset <select>, a typeahead, plain inputs) and
        # "Add" SNAPSHOTS those values into a new row, then clears them for the
        # next entry. `from:` expresses that: a map of ROW FIELD name => SOURCE
        # CONTROL selector. On click the client fills each cloned-row field
        # from its source's current value (matching the field by the trailing
        # bracket segment of its name — the SAME key inference JSON mode uses,
        # so the two agree), keeps focus on the sources, and (with `clear:
        # true`) resets the sources. It composes with BOTH wire modes: the
        # seeded values ride the renumbered `…_attributes[i][field]` names on
        # submit (:attributes), and the end-of-add JSON sync serializes them
        # (as: :json) with no extra wiring.
        #
        #   a(**reactive_nested_add(:items,
        #     from: { name: "#item-name", quantity: "#item-qty" }, clear: true))
        #
        # `from:` values are RAW CSS selectors (the escape-hatch posture of
        # reactive_filter/reactive_tags) — the sources are author-owned markup,
        # not reactive_field bindings — resolved root-scoped (#15 ownership).
        def reactive_nested_add(association, from: nil, clear: false)
          data = {
            action: "click->reactive#nestedAdd",
            reactive_association_param: nested_identifier!(:reactive_nested_add, :association, association)
          }
          unless from.nil?
            data[:reactive_nested_from_param] = nested_from_param!(from)
            # STRING "true", not boolean: a valueless boolean attr reads "" (falsy)
            # client-side — the on()/tags precedent.
            data[:reactive_nested_clear_param] = "true" if clear
          end
          { type: "button", data: }
        end

        # Validate + compile a fill-then-add `from:` map into its JSON wire
        # (issue #208). Each key is a ROW FIELD name (plain identifier, like the
        # association); each value is a SOURCE CONTROL selector (non-blank). An
        # empty map is a dead binding — fail at render (the reactive_show_targets
        # posture), never a silent no-op.
        def nested_from_param!(from)
          unless from.is_a?(Hash) && from.any?
            raise ArgumentError,
              "reactive_nested_add from: needs at least one row-field => source-selector pair " \
              "(e.g. from: { quantity: \"#item-qty\" }), got #{from.inspect}"
          end

          from.to_h do |field, selector|
            [nested_identifier!(:reactive_nested_add, :field, field),
             filter_selector!(:reactive_nested_add_from, selector)]
          end.to_json
        end

        # A row's remove trigger — client-only. Draft rows leave the DOM;
        # persisted rows (a hidden [_destroy] input present) are marked and
        # hidden instead, so Rails destroys them on save.
        #
        # CONFIRM (issue #218). Removing a row can be a real loss (line items
        # with entered amounts), so this trigger accepts the SAME confirm: the
        # other triggers (on/on_client) do — routed through the shared
        # apply_confirm!, so the client gates the remove behind the overridable
        # confirmResolver (the styled-modal seam, #52/#55/#178). A String is
        # the static message; a Hash is the CONDITIONAL form (#179) — prompt
        # only when { when: … } matches or a { predicate: … } fires. Per-row
        # messages come for free: the app builds a different string per row at
        # render time. No confirm: → the plain immediate-remove fast path,
        # unchanged.
        #
        #   button(**reactive_nested_remove(confirm: "Really delete #{row.name}?")) { "×" }
        def reactive_nested_remove(confirm: nil)
          data = { action: "click->reactive#nestedRemove" }
          apply_confirm!(data, confirm) if confirm
          { type: "button", data: }
        end

        # CROSS-ROOT value-conditional visibility (issue #164) — the visibility
        # parallel to reactive_compute's `mirror:` (#159). A plain reactive_show
        # is root-scoped by design (#15), so it can't express "this control
        # drives elements ELSEWHERE on the page" — a nav tab, a panel in another
        # tab pane, a sidebar note. reactive_show_targets is the declared,
        # id-allowlisted escape: the component that OWNS the field declares
        # which outside ids it governs. Spread it on the ROOT (mix alongside
        # reactive_root — the client reads it off the controller element):
        #
        #   div(**mix(reactive_root, reactive_show_targets(:mode,
        #     "#advanced-tab"   => "advanced",          # equals
        #     "#advanced-panel" => "advanced",
        #     "#premium-note"   => %w[gold platinum]))) # membership
        #
        # Same posture as mirror: — opt-in and declared, never implicit (a plain
        # reactive_show stays root-isolated); targets are SINGLE ID SELECTORS
        # only, enforced here at declare time AND warn-and-skipped by the client
        # interpreter (two-sided default-deny); the value uses the same where-
        # style conditions vocabulary (scalar/Array/Range, no expressions); and
        # the toggle is `hidden` only — no innerHTML, no attribute freedom. The
        # FIELD read stays owned (#15): you can only drive outside visibility from
        # a field this root owns. A target id not on the page is silently skipped
        # (an unrendered tab pane is normal). A target value is positive-only (no
        # per-target unless:) — express "not X" as a membership Array over the
        # remaining options.
        #
        # ONE call per root. Phlex `mix` space-joins duplicate STRING data
        # values, so a second call's JSON would concatenate into an unparseable
        # attr and the client would drop BOTH maps (it warns when that
        # happens). Several fields therefore go in ONE call via the hash form:
        #
        #   reactive_show_targets(mode: { "#advanced-tab" => "advanced" },
        #                         kind: { "#premium-note" => %w[gold platinum] })
        #
        # MULTI-FIELD targets (issue #209): a "#id" KEY takes a full
        # if:/if_any:/unless: conditions Hash — the SAME language reactive_show
        # speaks, so a cross-root target can finally read a COMBINATION of
        # owned fields (the last case forcing a bespoke JS listener):
        #
        #   reactive_show_targets("#trade-warning" => {
        #     if: { type: "trade", price: ..0 }   # type == "trade" AND price <= 0
        #   })
        #
        # Target-keyed and field-keyed entries mix in the ONE call (a "#" key is
        # unambiguous — a field name may never start with "#"). The client folds
        # the target's DNF payload with the same per-term field reads as an
        # in-root reactive_show: every referenced field must be OWNED by this
        # root (a missing owned field reads as blank, fail-closed); a target
        # whose fields are ALL unowned is left alone, like the single-field skip.
        def reactive_show_targets(field, targets = nil)
          field_maps = targets.nil? ? field : { field => targets }
          unless field_maps.is_a?(Hash) && field_maps.any?
            raise ArgumentError,
              "reactive_show_targets needs at least one target " \
              "(:field, \"#id\" => value), got #{field_maps.inspect}"
          end

          normalized = field_maps.to_h do |name, map|
            if name.to_s.start_with?("#")
              # Target-keyed conditions (issue #209): "#id" => { if:/if_any:/unless: }.
              [name.to_s, normalize_show_target_conditions(name.to_s, map)]
            else
              [name.to_s, normalize_show_target_map(name, map)]
            end
          end

          { data: { reactive_show_targets: normalized.to_json } }
        end

        # Client-only localStorage draft over the fields this root OWNS (issue
        # #239) — "don't make me start over". Spread on the ROOT (mix with
        # reactive_root, like reactive_show_targets); the generic controller
        # then writes every owned control's value to localStorage as the user
        # types (debounced on `input`, immediate on `change`, flushed on
        # disconnect), restores the draft on the NEXT connect, and forgets it
        # when the owning form submits successfully (turbo:submit-end), when
        # `ttl` elapses, or on a js.persist_clear op:
        #
        #   div(**mix(reactive_root, reactive_persist(key: "village-apply", ttl: 7.days))) do
        #     input(**reactive_field(:name))                       # persisted
        #     input(name: "fuckery", **reactive_persist_skip)      # honeypot — never
        #     input(type: "hidden", name: "tz")                    # hidden — never (default)
        #   end
        #
        # Never persisted: type=hidden/file/password/submit/button/reset/image,
        # anything carrying reactive_persist_skip, a nested reactive root's
        # controls (#15 ownership), and — when `fields:` narrows the set —
        # any name outside it (scope-aware symbols, the reactive_show form).
        # Rich editors ARE persisted (#241): a named lexxy-editor / trix-editor
        # (Trix's name may come from its `input=`-paired hidden input) or a
        # bare named [contenteditable] is drafted and restored through its own
        # value surface (the editor's `value` setter, textContent) — never
        # innerHTML; put reactive_persist_skip on the editor element to opt out.
        # `autocomplete="off"` is NOT an implicit skip: honeypots (an
        # invisible_captcha text input looks like any other) must opt out
        # explicitly or sit outside the root.
        #
        # `restore:` — `:blank` (default) restores a draft value only into a
        # control the server rendered BLANK, so a 422 re-render's submitted
        # values win over an older draft; `:always` lets the draft win.
        #
        # Same posture as reactive_show: no token, no POST, no expression
        # surface. Stored values are plain user input replayed via
        # .value/.checked (never HTML) — a tampered draft can only fill what
        # the user could type. PII sits in localStorage for `ttl`; the
        # successful-submit clear and `ttl` are the shared-computer mitigation
        # (see docs/security). ONE call per root — Phlex `mix` space-joins
        # duplicate string data values, so a second call would corrupt the JSON.
        def reactive_persist(key:, ttl: 7.days, fields: nil, restore: :blank, debounce: 300)
          payload = {
            "key" => validate_persist_key!(key),
            "ttl" => validate_persist_ttl!(ttl),
            "debounce" => validate_persist_debounce!(debounce)
          }
          payload["restore"] = "always" if validate_persist_restore!(restore) == :always
          payload["fields"] = validate_persist_fields!(fields) if fields

          { data: { reactive_persist: payload.to_json } }
        end

        # Mark ONE control as never persisted (issue #239) — a honeypot, a
        # one-time code. Spread on the control: input(name: "x", **reactive_persist_skip).
        def reactive_persist_skip
          { data: { reactive_persist: "off" } }
        end

        def validate_persist_key!(key)
          return key if key.is_a?(String) && !key.strip.empty?

          raise ArgumentError, "reactive_persist key: must be a non-blank String, got #{key.inspect}"
        end

        # Seconds on the wire: an ActiveSupport::Duration (7.days) or an Integer.
        def validate_persist_ttl!(ttl)
          seconds = ttl.is_a?(ActiveSupport::Duration) ? ttl.to_i : ttl
          return seconds if seconds.is_a?(Integer) && seconds.positive?

          raise ArgumentError, "reactive_persist ttl: must be a positive duration or Integer seconds, got #{ttl.inspect}"
        end

        def validate_persist_debounce!(debounce)
          return debounce if debounce.is_a?(Integer) && !debounce.negative?

          raise ArgumentError, "reactive_persist debounce: must be a non-negative Integer (ms), got #{debounce.inspect}"
        end

        def validate_persist_restore!(restore)
          return restore if %i[blank always].include?(restore)

          raise ArgumentError, "reactive_persist restore: must be :blank or :always, got #{restore.inspect}"
        end

        def validate_persist_fields!(fields)
          list = Array(fields)
          raise ArgumentError, "reactive_persist fields: needs at least one field name" if list.empty?

          list.map { scoped_field_name(it) }
        end

        # Scoped busy indicator (issue #99). Marks an element so the generic
        # controller toggles `data-reactive-busy` on it ONLY while `action` is in
        # flight — the scoped sibling of the always-on `data-reactive-busy` the
        # trigger and root carry. Spread onto any element inside the reactive root;
        # style it with `[data-reactive-busy] { … }` and zero Ruby:
        #   span(**busy_on(:save), class: "spinner hidden")
        def busy_on(action)
          { data: { reactive_busy_on: action.to_s } }
        end

        # REMOVED in issue #183 — the compute binding moved to
        # reactive_root(compute: :name), which emits the descriptors AND the
        # recompute delegation at the root, so no field carries per-field wiring:
        #   div(**reactive_root(compute: :payment_split)) { … }
        # This helper now raises a guided ArgumentError printing that rewrite.
        def reactive_compute_attrs(name)
          raise ArgumentError,
            "reactive_compute_attrs(#{name.inspect}) was removed in issue #183 — " \
            "pass reactive_root(compute: #{name.inspect}) instead (bind + listen at the root)"
        end

        # The root's compute descriptors + the recompute delegation (issue #183).
        # Emits the same data-reactive-compute-* attrs as before PLUS the
        # input->reactive#recompute action, all on the root element. Raises for an
        # undeclared name (fail fast, not a silent no-op).
        def compute_binding(name)
          definition = self.class.reactive_computes[name.to_sym]
          raise Error, "#{self.class} has no reactive_compute #{name.inspect}" unless definition

          data = {
            action: "input->reactive#recompute",
            reactive_compute_reducer_param: definition.reducer,
            reactive_compute_inputs_param: compute_inputs_param(definition),
            reactive_compute_outputs_param: definition.outputs.map(&:to_s).to_json,
            # Issue #199: the client self-seeds the derived fields on connect from
            # this marker, so a freshly-rendered compute root computes its outputs
            # + mirrors on first paint — no wait for the first user input, and no
            # synthetic seed `input` for an app to race. STRING "true" (a valueless
            # boolean attr renders "" → falsy client-side; the client reads == "true").
            reactive_compute_seed: "true"
          }
          # Declared cross-root text mirrors (issue #159) ride as a JSON object of
          # name → [id selectors]; omitted entirely when undeclared so the shipped
          # wire stays byte-identical.
          data[:reactive_compute_mirror_param] = compute_mirror_param(definition) if definition.mirror

          { data: }
        end

        # The mirror param wire (issue #159): { "sum_a" => ["#sum_a"], … } — the
        # values are ALWAYS arrays so the client parses one uniform shape.
        def compute_mirror_param(definition)
          definition.mirror.transform_keys(&:to_s).to_json
        end

        # The inputs param wire (issue #104). Untyped (array form) → a JSON ARRAY of
        # names, byte-identical to the shipped wire so the client keeps its numeric
        # coercion. Typed (hash form) → a JSON OBJECT of name→type
        # ({"title":"string","qty":"number"}) so the client reads a :string raw and
        # coerces a :number through Number.
        def compute_inputs_param(definition)
          types = definition.input_types
          return definition.inputs.map(&:to_s).to_json if types.nil?

          definition.inputs.to_h { [it.to_s, types[it].to_s] }.to_json
        end

        # REMOVED in issue #184 — one binding helper (reactive_field); the element
        # is the caller's: select(**reactive_field(:status)) { status_options }.
        # Raises a guided error printing that rewrite.
        def reactive_select(param, **, &)
          raise ArgumentError,
            "reactive_select was removed in issue #184 — use " \
            "select(**reactive_field(#{param.inspect})) { … } (one binding helper; the element is yours)."
        end

        # Map a declared nested param onto Rails' <assoc>_attributes, carrying the
        # existing associated record's id so accepts_nested_attributes_for matches
        # it IN PLACE instead of building a second one (issue #24). Returns the
        # update hash; pass it to update!:
        #   def save(address:) = nested_update!(:address, address)
        # The id is only added when the association already exists, so the first
        # save (no associated record yet) creates one cleanly. The given attrs are
        # not mutated.
        def nested_attributes(association, attrs)
          merged = attrs.dup
          existing = reactive_record_for_nested.public_send(association)
          merged[:id] = existing.id if existing

          { "#{association}_attributes": merged }
        end

        # Map a nested param onto <assoc>_attributes (with id preservation) AND
        # apply it to the component's record in one call (issue #24). Extra keyword
        # attributes update alongside the association.
        #   def save(address:, name:) = nested_update!(:address, address, name:)
        def nested_update!(association, attrs, **extra)
          reactive_record_for_nested.update!(**nested_attributes(association, attrs), **extra)
        end

        # The conditions-language kwargs (issue #180): if:/if_any:/unless: —
        # compiled by Phlex::Reactive::ShowConditions into the DNF wire. The ONE
        # vocabulary; there are no predicate kwargs any more.
        SHOW_CONDITION_KEYS = %i[if if_any unless].freeze

        # The removed 0.9.5 surface (issue #180 clean break): each of these
        # kwargs — and a positional field — now raises a GUIDED error printing
        # the if:/if_any:/unless: rewrite. Kept only to detect the legacy call
        # shape; nothing here reaches the wire.
        LEGACY_SHOW_PREDICATE_KEYS = %i[equals not in gte gt lte lt].freeze
        LEGACY_SHOW_CONNECTIVE_KEYS = %i[all any].freeze

        private

        # A reactive_filter/reactive_listnav selector, validated non-blank and
        # stringified (issue #163). A blank selector is a dead binding — the
        # client would silently match nothing — so it fails loudly at render,
        # like reactive_show's predicate validation. A boolean is rejected too
        # (issue #224): `input: cond && "#sel"` with cond false would otherwise
        # stringify to the plausible-looking dead selector "false".
        def filter_selector!(name, value)
          selector = value.to_s
          if value == true || value == false || selector.strip.empty?
            raise ArgumentError,
              "reactive_filter/reactive_listnav #{name}: needs a CSS selector, got #{value.inspect}"
          end

          selector
        end

        # A declared tag value for reactive_tags_option/reactive_tags_remove
        # (issue #203), validated non-blank and comma-free at render — the hidden
        # field is comma-joined, so a declared tag containing a comma would
        # corrupt the stored value (and a blank tag is a dead trigger).
        def tags_tag!(helper, tag)
          value = tag.to_s.strip
          raise ArgumentError, "#{helper} needs a non-blank tag, got #{tag.inspect}" if value.empty?
          if value.include?(",")
            raise ArgumentError,
              "#{helper}(#{tag.inspect}): a tag can't contain a comma — the hidden field is comma-joined"
          end

          value
        end

        # A verbatim wire name for the name:-form escape hatches (issue #224) —
        # an instance-dynamic name (a form builder's "user[tags]") used exactly
        # as given, never re-scoped. The name is interpolated into a
        # double-quoted [name="…"] attribute selector the CLIENT passes to
        # querySelectorAll, so anything that breaks a CSS string breaks the
        # binding IN THE BROWSER: a `"` ends the string early, a `\` CSS-escapes
        # (a trailing one swallows the closing quote — the selector silently
        # matches the wrong name), and a raw control character (newline) makes
        # querySelectorAll THROW, aborting the controller's connect. All fail
        # loudly here at render instead. Booleans are rejected with the blank
        # check: `name: cond && "user[tags]"` with cond false must never
        # compile the plausible-looking [name="false"].
        def verbatim_name_selector!(helper, name)
          value = name.to_s
          if name == true || name == false || value.strip.empty?
            raise ArgumentError,
              "#{helper} name: needs a non-blank wire name (e.g. name: \"user[tags]\"), got #{name.inspect}"
          end
          if value.match?(/["\\\x00-\x1f]/)
            raise ArgumentError,
              "#{helper} name: can't contain a double quote, backslash, or control character — " \
              "the name is compiled into a [name=\"…\"] selector the client queries with, " \
              "got #{name.inspect}"
          end

          %([name="#{value}"])
        end

        # The per-call scope: override for nested_field_name (issue #224) — a
        # form builder's parent prefix, possibly itself bracketed
        # ("user[profile]"), validated non-blank. Used verbatim as the wrap.
        # String/Symbol only: `scope: cond && "order"` with cond false would
        # otherwise stringify to the silently-corrupting "false[…]" wire name.
        def nested_scope!(scope)
          unless scope.is_a?(String) || scope.is_a?(Symbol)
            raise ArgumentError,
              "nested_field_name scope: needs a String or Symbol parent prefix " \
              "(e.g. scope: \"order\"), got #{scope.inspect}"
          end

          value = scope.to_s
          return value unless value.strip.empty?

          raise ArgumentError,
            "nested_field_name scope: needs a non-blank parent prefix (e.g. scope: \"order\"), " \
            "got #{scope.inspect}"
        end

        # An association/field name for the nested-rows wire (issue #208),
        # validated to a plain Ruby identifier at render — it becomes an
        # attribute value, a CSS selector fragment, AND a bracketed param name,
        # so anything else is a dead (or corrupting) binding.
        def nested_identifier!(helper, kind, name)
          value = name.to_s
          return value if value.match?(/\A[a-z_][a-z0-9_]*\z/)

          raise ArgumentError,
            "#{helper} needs a plain #{kind} name (e.g. :line_items), got #{name.inspect}"
        end

        # Issue #179: apply a confirm: gate to a trigger's data hash. A String is
        # the static #52/#55 form (data-reactive-confirm-param, unchanged). A Hash
        # is the CONDITIONAL form (data-reactive-confirm-when-param, JSON) — warn
        # only when field values look suspect:
        #   { when: { total: 0 }, message: }  — reactive_show conditions language
        #     (scalar=equals, Range=threshold, Array=set); prompts when it MATCHES.
        #   { predicate: "name", message: }   — a JS fn registered with
        #     setConfirmPredicate, evaluated over collected fields (multi-field logic).
        # Shared by on and on_client so both paths speak the same three forms. The
        # predicate is soft-validation UX, NOT authorization — a user can bypass it;
        # the action still hits the endpoint's real authorize/default-deny.
        def apply_confirm!(data, confirm)
          case confirm
          when String
            data[:reactive_confirm_param] = confirm
          when Hash
            data[:reactive_confirm_when_param] = compile_conditional_confirm(confirm).to_json
          else
            raise ArgumentError,
              "confirm: takes a String (static) or a Hash ({ when: {…}, message: } / " \
              "{ predicate: \"name\", message: }), got #{confirm.class}"
          end
        end

        # Validate + compile a Hash confirm: into its wire payload. Exactly one of
        # when:/predicate:, message: required — a dead binding fails loudly at
        # render (the reactive_show posture), never silently in the browser.
        def compile_conditional_confirm(confirm)
          message = confirm[:message]
          has_when = confirm.key?(:when)
          has_predicate = confirm.key?(:predicate)

          if has_when == has_predicate
            raise ArgumentError,
              "confirm: needs exactly one of when: (a conditions hash) or predicate: " \
              "(a registered name), not both/neither — got #{confirm.except(:message).inspect}"
          end
          raise ArgumentError, "confirm: Hash needs a message: to show when it fires" if message.nil?

          if has_predicate
            { "predicate" => confirm[:predicate].to_s, "message" => message }
          else
            groups = Phlex::Reactive::ShowConditions.normalize(if: confirm[:when])
            { "groups" => { "any" => groups }, "message" => message }
          end
        end

        # Normalize + validate ONE field's target map (issue #180): each key a
        # single id selector (loud raise — the declare-time half of the two-sided
        # default-deny), each value a where-style condition value (scalar/Array/
        # Range) that compiles to ONE DNF group (terms ANDed). Shared by both
        # reactive_show_targets call forms.
        def normalize_show_target_map(field, targets)
          unless targets.is_a?(Hash) && targets.any?
            raise ArgumentError,
              "reactive_show_targets(#{field.inspect}) needs at least one target " \
              "(\"#id\" => value), got #{targets.inspect}"
          end

          targets.to_h do |selector, value|
            selector = selector.to_s
            unless selector.match?(DSL::MIRROR_ID_SELECTOR)
              raise ArgumentError,
                "reactive_show_targets(#{field.inspect}) target #{selector.inspect} must be a single " \
                "ID selector (\"#id\") — cross-root visibility is id-allowlisted, like mirror: (#159)"
            end
            if value.is_a?(Hash)
              raise ArgumentError,
                "reactive_show_targets(#{field.inspect}) target #{selector.inspect}: the { equals: ... } " \
                "predicate form was removed — pass a bare value (#{selector.inspect} => \"advanced\", " \
                "=> %w[a b] for a set, => 10.. for a threshold)"
            end

            # A target compiles to ONE group: the field-vs-value condition.
            groups = Phlex::Reactive::ShowConditions.normalize(if: { field => value })
            [selector, groups.first]
          end
        end

        # Normalize + validate ONE target-keyed entry (issue #209): the "#id"
        # key is a single id selector (the same declare-time guard as
        # field-keyed targets), the value a full if:/if_any:/unless: conditions
        # Hash compiled by ShowConditions into the SAME { "any" => groups } DNF
        # payload reactive_show emits. Anything else — a bare value, unknown
        # keys, empty conditions — raises a guided error at render (a dead
        # binding must never reach the browser).
        def normalize_show_target_conditions(selector, conditions)
          unless selector.match?(DSL::MIRROR_ID_SELECTOR)
            raise ArgumentError,
              "reactive_show_targets target #{selector.inspect} must be a single " \
              "ID selector (\"#id\") — cross-root visibility is id-allowlisted, like mirror: (#159)"
          end
          unless conditions.is_a?(Hash) && conditions.any?
            raise ArgumentError,
              "reactive_show_targets: a target key takes a conditions Hash — " \
              "reactive_show_targets(#{selector.inspect} => { if: { field: value, ... } }); " \
              "to key by field instead: reactive_show_targets(:field, #{selector.inspect} => value). " \
              "Got #{selector.inspect} => #{conditions.inspect}"
          end
          # Unknown keys are reported BEFORE the presence check so { bogus: 1 }
          # names its offender instead of the generic shape message (specific
          # beats generic). A non-empty hash surviving this subtraction holds
          # only condition keys, so no separate presence check remains.
          if (unknown = conditions.keys - SHOW_CONDITION_KEYS).any?
            raise ArgumentError,
              "reactive_show_targets #{selector.inspect}: unknown conditions key(s) " \
              "#{unknown.map(&:inspect).join(", ")} — a target's conditions Hash takes only " \
              "if:/if_any:/unless: (the reactive_show language)"
          end

          { "any" => Phlex::Reactive::ShowConditions.normalize(**conditions) }
        end

        # Reject the removed 0.9.5 reactive_show surface (issue #180 clean break)
        # with a GUIDED error printing the if:/if_any:/unless: rewrite. A
        # positional field, a predicate kwarg (equals:/not:/in:/gte:/…), or a
        # connective (all:/any:) all land here before any conditions parsing.
        def reject_legacy_show_surface!(field, options)
          unless field.nil?
            raise ArgumentError,
              "reactive_show no longer takes a positional field — the conditions language is " \
              "keyword-only: reactive_show(if: { #{field}: <value> }) (a Range is a threshold, " \
              "an Array is a set, unless: negates). See the 0.10 upgrade notes."
          end

          if (pred = options.keys & LEGACY_SHOW_PREDICATE_KEYS).any?
            raise ArgumentError,
              "reactive_show(#{pred.first}: ...) was removed — use the conditions language: " \
              "reactive_show(if: { field: value }). equals:/not: → if:/unless:, in: → an Array value, " \
              "gte:/gt:/lte:/lt: → a Range value (10.., ..10, ...10)."
          end
          if (conn = options.keys & LEGACY_SHOW_CONNECTIVE_KEYS).any?
            replacement = conn.first == :all ? "if: { … }" : "if_any: [{ … }, { … }]"
            raise ArgumentError,
              "reactive_show(#{conn.first}: [...]) was removed — use #{replacement}. " \
              "all: → if: (one AND group); any: → if_any: (OR of AND groups). Terms are now " \
              "field => value pairs, not { field:, equals: } hashes."
          end
        end

        # Compute the first-paint `hidden:` from reactive_values (issue #180) so
        # the author never restates the predicate as a Ruby mirror method. Fires
        # only when EVERY field the binding references is provided (by
        # reactive_values, merged under a per-call `values:` override); otherwise
        # the attrs are returned untouched. An explicit `hidden:` in the caller's
        # attrs always wins (it survives the mix, so this is a no-op then).
        def apply_first_paint_hidden(attrs, groups, values_override)
          return attrs if attrs.key?(:hidden)

          provided = show_values(values_override)
          return attrs if provided.nil?

          referenced = Phlex::Reactive::ShowConditions.fields(groups)
          return attrs unless referenced.all? { provided.key?(it) }

          visible = Phlex::Reactive::ShowConditions.match?(groups, provided)
          attrs.merge(hidden: !visible)
        end

        # The { field => current-string-value } map the first-paint evaluator
        # reads: reactive_values (if the component declares it) merged under a
        # per-call values: override, both stringified the way the client reads a
        # field (checkbox → "true"/"false", nil → ""). nil when neither source
        # exists — first paint then no-ops (no flash guarantee is the author's,
        # exactly as before).
        def show_values(values_override)
          base = respond_to?(:reactive_values) ? reactive_values : nil
          return nil if base.nil? && values_override.nil?

          merged = {}
          merged.merge!(base) if base
          merged.merge!(values_override) if values_override
          merged.to_h { |name, value| [name.to_s, show_value_string(value)] }
        end

        # Stringify a reactive_values entry the way the client's #showFieldValue
        # reports the live field: a boolean is the checkbox checked-state string,
        # nil is blank, everything else is to_s.
        def show_value_string(value)
          case value
          when true then "true"
          when false then "false"
          when nil then ""
          else value.to_s
          end
        end

        # True when the hint declares checked: :keep — the click-bound
        # checkbox/radio case that must SKIP the forced type="button" so the native
        # control (and its native flip) survives (issue #98). Accepts symbol or
        # string keys/values; nil-safe for the no-hint hot path.
        def optimistic_keeps_native?(optimistic)
          return false unless optimistic.is_a?(Hash)

          value = optimistic[:checked] || optimistic["checked"]
          value.to_s == "keep"
        end

        # The removed on() pending-state kwargs (issue #181). loading:/disable_with:
        # collapsed into busy:; listnav: into the standalone reactive_listnav.
        # They now land in **params, so catch them there and raise a guided error
        # showing the rewrite — a clean break (pre-1.0), not a silent shim that
        # would ship a stale call to the browser wrong.
        REMOVED_ON_KWARGS = {
          disable_with: 'busy: "…" (String shorthand for { disable: true, text: "…" })',
          loading: "busy: { disable:, add_class:, text:, to: } (same keys as optimistic:)",
          listnav: "reactive_listnav — mix(on(:search, event: \"input\"), reactive_listnav)"
        }.freeze

        # The unified pending-state hint vocabulary (issue #181): the js.* op names
        # shared by optimistic: and busy:, plus disable:/to:. checked: :keep is
        # optimistic-ONLY (a native control flip has no settle-revert meaning).
        PENDING_CLASS_OPS = %w[toggle_class add_class remove_class].freeze

        private_constant :REMOVED_ON_KWARGS, :PENDING_CLASS_OPS

        def reject_removed_on_kwargs!(action_name, params)
          removed = params.keys & REMOVED_ON_KWARGS.keys
          return if removed.empty?

          key = removed.first
          raise ArgumentError,
            "on(#{action_name.inspect}) #{key}: was removed in issue #181 — use #{REMOVED_ON_KWARGS[key]}"
        end

        # Normalize + validate a pending-state hint (issue #181), returning its
        # JSON wire form. ONE vocabulary + ONE normalizer for both optimistic: (kind
        # :optimistic, reverts on FAILURE) and busy: (kind :busy, reverts on
        # SETTLE); they differ only in client lifecycle, not in shape. The String
        # shorthand `busy: "Saving…"` expands to { disable: true, text: … }. `to:`
        # resolves through the SAME JS.normalize_target the js op builder uses (a
        # :root sentinel or a verbatim CSS selector). checked: :keep is accepted
        # only for :optimistic. An unknown key, a bad value, or the wrong type
        # raises — a dead hint fails loudly at render, never silently on the client.
        def pending_hint_json(source, action_name, kind)
          source = { disable: true, text: source } if kind == :busy && source.is_a?(String)
          unless source.is_a?(Hash)
            raise ArgumentError,
              "on(#{action_name.inspect}) #{kind}: must be a #{"String or " if kind == :busy}Hash of visual " \
              "hints (e.g. { disable: true, text: \"Saving…\" }), got #{source.class}"
          end

          hint = {}
          source.each do |key, value|
            case key.to_s
            when *PENDING_CLASS_OPS
              hint[key.to_s] = Array(value).map(&:to_s)
            when "hide", "show", "disable"
              hint[key.to_s] = value ? true : false
            when "text"
              hint["text"] = value.to_s
            when "to"
              hint["to"] = Phlex::Reactive::JS.normalize_target(value)
            when "checked"
              hint["checked"] = pending_checked!(value, action_name, kind)
            else
              raise ArgumentError,
                "on(#{action_name.inspect}) got an unknown #{kind} hint #{key.inspect} — supported: " \
                "add_class/remove_class/toggle_class, hide:, show:, disable:, text:, to:" \
                "#{", checked: :keep" if kind == :optimistic}"
            end
          end

          hint.to_json
        end

        # checked: :keep flips a native checkbox/radio and reverts on failure — it
        # only makes sense for optimistic: (a settle-revert busy: hint has no native
        # control to keep). Reject it for :busy, and reject any value but :keep.
        def pending_checked!(value, action_name, kind)
          if kind != :optimistic
            raise ArgumentError,
              "on(#{action_name.inspect}) #{kind}: does not support checked: — the native-control " \
              "flip is an optimistic-only hint (it reverts on failure, not on settle)"
          end
          unless value.to_s == "keep"
            raise ArgumentError,
              "on(#{action_name.inspect}) optimistic checked: only supports :keep " \
              "(flip the native control, revert on failure), got #{value.inspect}"
          end

          "keep"
        end

        # The component's record, for the nested-attributes helpers. Requires a
        # declared reactive_record (the nested helper only makes sense for a
        # record-backed component).
        def reactive_record_for_nested
          key = self.class.reactive_record_key
          raise Error, "#{self.class} must declare `reactive_record` to use nested_update!/nested_attributes" unless key

          instance_variable_get(:"@#{key}")
        end
      end
    end
  end
end
