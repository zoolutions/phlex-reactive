# frozen_string_literal: true

module Phlex
  module Reactive
    # An immutable, chainable builder of client-side DOM commands (issue #95) —
    # the ops behind Component#on_client. Each verb returns a NEW frozen
    # instance; #to_json emits the wire format the generic controller's runOps
    # action interprets, entirely in the browser:
    #
    #   button(**on_client(:click, js.toggle("#menu"))) { "Menu" }
    #   # -> data-reactive-ops-param='[["toggle",{"to":"#menu"}]]'
    #
    # These are declarative DOM OPERATIONS, not state: nothing is shipped back
    # to the server, nothing is trusted from the client, and any server
    # re-render of the component resets whatever they toggled (the LiveView
    # JS-commands caveat — by design; use a signed action for state that must
    # survive re-renders).
    #
    # Targets: a CSS selector string is resolved WITHIN the component's root by
    # default (nested reactive roots excluded, issue #15 semantics); `:root`
    # targets the root element itself; `global: true` opts a single op out of
    # root scoping (document escape hatch, e.g. a page-level overlay).
    #
    # The op vocabulary is a fixed whitelist mirrored by the client interpreter
    # — an op name the client doesn't know is warn-and-skipped there
    # (client-side default-deny). Validation here is deliberately LOUD: a bad
    # target or an empty class list raises at render time rather than silently
    # doing nothing in the browser.
    class JS
      # Serialized stand-in for "the component's own root element".
      ROOT_SENTINEL = "@root"

      # The attribute-name allowlist (issue #96) — the security-critical part of
      # the attr ops, enforced HERE at build time AND again in the client
      # interpreter (two-sided default-deny: a hand-built ops attr must not
      # bypass it either). Rejected:
      #   * /\Aon/i        — event-handler attributes (onclick, onmouseover) → XSS.
      #   * the URL set     — href/src/srcdoc/action/formaction/xlink:href can carry
      #                       a `javascript:` payload; setting them from client ops
      #                       is a navigation/injection surface, not a UI toggle.
      #   * style           — inline CSS injection; use classes (add_class/...).
      # The INTENDED surface is class ops plus boolean/state attributes:
      #   hidden, disabled, open, selected, aria-*, data-*.
      URL_BEARING_ATTRS = %w[href src srcdoc action formaction xlink:href].freeze
      EVENT_HANDLER_ATTR = /\Aon/i

      # The attr ops whose args carry a "name" the allowlist must gate. Used to
      # re-validate a RAW [op, args] list (the js([...]) / broadcast_js_to([...])
      # escape hatch) that skips the builder's build-time attr_args check.
      ATTR_NAME_OPS = %w[set_attr remove_attr toggle_attr].freeze

      # Validate a raw ops list ([[op, args], ...] as passed to js/broadcast_js_to
      # without the builder) against the attribute allowlist, so the escape hatch
      # gets the SAME server-side default-deny as the JS chain (defense in depth;
      # the client also enforces it). Non-attr ops and malformed entries pass
      # through untouched — the client interpreter default-denies unknown ops.
      # :root -> the sentinel; a String passes through as a CSS selector. Shared
      # by the js op builder AND the on() pending-state hint normalizer (issue
      # #181) so BOTH resolve a `to:` target through one code path. Anything else
      # (a stray symbol, nil) is a bug at the call site — raise at render time
      # instead of silently matching nothing in the browser.
      def self.normalize_target(to)
        return ROOT_SENTINEL if to == :root
        return to if to.is_a?(String)

        raise ArgumentError,
          "target must be :root or a CSS selector string, got #{to.inspect}"
      end

      def self.assert_ops_allowed!(list)
        Array(list).each do |op, args|
          next unless ATTR_NAME_OPS.include?(op.to_s) && args.is_a?(::Hash)

          name = args["name"] || args[:name]
          assert_allowed_attr(name.to_s) if name
        end
      end

      # The attribute-name allowlist (issue #96), case-insensitive. Refuses
      # event-handler (on*), URL-bearing, and style attributes. Enforced at build
      # time by the instance builder AND on the raw-list escape hatch — two-sided
      # default-deny with the client interpreter.
      def self.assert_allowed_attr(name)
        lower = name.downcase
        if name.match?(EVENT_HANDLER_ATTR)
          raise ArgumentError,
            "#{self}: attribute #{name.inspect} is an event handler (on*) — refused (XSS). " \
            "Client attr ops target hidden/disabled/open/selected/aria-*/data-* and classes."
        end
        return unless URL_BEARING_ATTRS.include?(lower) || lower == "style"

        raise ArgumentError,
          "#{self}: attribute #{name.inspect} is refused — URL-bearing attributes " \
          "(#{URL_BEARING_ATTRS.join(", ")}) and `style` can't be set from client ops " \
          "(injection surface). Use classes for styling; target aria-*/data-*/boolean attrs."
      end

      # The accumulated [name, args] op pairs, oldest first. Frozen.
      attr_reader :ops

      def initialize(ops = [].freeze)
        @ops = ops
        freeze
      end

      # --- Visibility (the `hidden` attribute) ---
      #
      # `transition:` (issue #96) — an optional [during, from, to] class triple
      # animated around the visibility flip: `during`+`from` are applied, then on
      # the next frame `from`→`to` swaps, and the whole set is awaited via
      # `animationend` (with a setTimeout fallback so a non-animated element never
      # hangs the op chain). Omit it for the instant flip.
      #
      # `expanded:` (issue #271) — a disclosure trigger to keep honest: the
      # client sets its aria-expanded from the op's INTENDED state (show →
      # "true", hide → "false", toggle → the pre-flip hidden state), before any
      # transition runs. Resolved with the op's own scoping (`:root` or a
      # selector, document-wide under global: true). Pair it with ONE disclosure
      # target — with several, the last one wins.
      #   js.toggle("#menu", expanded: "#menu-trigger")

      def show(to, global: false, transition: nil, expanded: nil)
        append("show", target_args(to, global:, transition:, expanded:))
      end

      def hide(to, global: false, transition: nil, expanded: nil)
        append("hide", target_args(to, global:, transition:, expanded:))
      end

      def toggle(to, global: false, transition: nil, expanded: nil)
        append("toggle", target_args(to, global:, transition:, expanded:))
      end

      # --- Classes ---

      def add_class(to, *classes, global: false)
        append("add_class", class_args(to, classes, global:))
      end

      def remove_class(to, *classes, global: false)
        append("remove_class", class_args(to, classes, global:))
      end

      def toggle_class(to, *classes, global: false)
        append("toggle_class", class_args(to, classes, global:))
      end

      # --- Attributes (issue #96) — allowlisted names only ---
      #
      # set_attr(to, name, value) / remove_attr(to, name) / toggle_attr(to, name).
      # The value is stringified (a Phlex-style flag rides as the string "true",
      # never a valueless attribute). The name is checked against the allowlist at
      # build time — an event-handler, URL-bearing, or style name raises here.
      #
      # toggle_attr(to, name, on, off) (issue #271) flips BETWEEN two values
      # instead of toggling presence — current == on ? off : on, so an absent
      # attribute becomes `on`. For aria-expanded/aria-pressed/data-state:
      #   js.toggle_attr("#trigger", "aria-expanded", "true", "false")

      def set_attr(to, name, value, global: false)
        append("set_attr", attr_args(to, name, global:, value:))
      end

      def remove_attr(to, name, global: false)
        append("remove_attr", attr_args(to, name, global:))
      end

      def toggle_attr(to, name, *values, global: false)
        args = attr_args(to, name, global:)
        return append("toggle_attr", args) if values.empty?

        append("toggle_attr", args.merge("values" => toggle_values(name, values)).freeze)
      end

      # --- Focus (issue #96) ---
      #
      # focus(to)        — focus the FIRST match of the selector.
      # focus_first(to)  — focus the first FOCUSABLE DESCENDANT of the match
      #                    (e.g. focus the first menuitem inside an opened menu).

      def focus(to, global: false)
        append("focus", target_args(to, global:))
      end

      def focus_first(to, global: false)
        append("focus_first", target_args(to, global:))
      end

      # --- Submit (issue #226) ---
      #
      # submit(to = :root) — requestSubmit() the TARGET'S OWN form: the target
      # itself when it IS a form, else its form owner (input.form, honoring a
      # form= attribute), else the nearest ancestor form. requestSubmit runs
      # constraint validation and fires a REAL cancelable `submit` event, so it
      # composes with both a native/Turbo form and an on(:action, event:
      # "submit") interception. ACTOR-ONLY like focus: allowed from on_client /
      # reply.js / a reducer's $ops, refused in broadcast_to(js:) — a broadcast
      # submit would force-submit every subscriber's form.
      #
      # submitter: (issue #319) — a CSS selector for the submit control to
      # submit THROUGH (form.requestSubmit(submitter)), so the request carries
      # its name=value — the bulk-action "Delete" that posts action=delete. It
      # resolves with the op's own scoping; one that isn't a submit control of
      # that form warns in the browser and falls back to a plain submit.
      #   js.submit("#bulk", submitter: "#delete-submit")

      def submit(to = :root, global: false, submitter: nil)
        args = target_args(to, global:)
        return append("submit", args) if submitter.nil?

        unless submitter.is_a?(String) && !submitter.empty?
          raise ArgumentError,
            "js.submit submitter: must be a CSS selector string naming a submit control, got #{submitter.inspect}"
        end

        append("submit", args.merge("submitter" => submitter).freeze)
      end

      # --- Clipboard-source paste (issue #228) ---
      #
      # paste_into(to) — on a user gesture, read navigator.clipboard.readText()
      # and feed the text into the target field through the normal `input`
      # pipeline: set .value, dispatch a bubbling `input` event (so
      # reactive_compute reducers, reactive_show, and reactive_on_complete all
      # run exactly as if the user had typed it), then focus the field. The
      # permission UX is the browser's own; a rejected or unavailable read is a
      # SILENT NO-OP — page state must not change. The target is a FIELD: there
      # is no :root default and an explicit :root is refused loudly (pasting
      # into the root div is always a call-site bug). ACTOR-ONLY like
      # focus/submit: allowed from on_client / reply.js / reactive_on_complete,
      # refused in broadcast_to(js:) — a broadcast that reads every
      # subscriber's clipboard would be hostile. on_client marks the trigger
      # with data-reactive-clipboard so the client can hide it wherever the
      # clipboard API is missing (no dead button). NOTE: the gate owns the
      # trigger's `hidden` flag — don't also bind reactive_show to the trigger
      # element (the two passes would fight over the same attribute).

      def paste_into(to, global: false)
        if to == :root
          raise ArgumentError,
            "#{self.class}: paste_into targets a field, not the component root — " \
            "pass the input's CSS selector (e.g. js.paste_into(\"[name=code]\"))"
        end

        append("paste_into", target_args(to, global:))
      end

      # --- Text content (issue #159) ---
      #
      # text(to, value) — set the target's textContent (stringified; nil clears).
      # XSS-safe by construction: textContent only, NEVER innerHTML — strictly
      # less powerful than set_attr. Pair with `global: true` to paint a value
      # into a node OUTSIDE the component's root (the cross-root text escape,
      # e.g. a read-only recap in another tab pane).

      def text(to, value, global: false)
        args = { "to" => normalize_target(to), "value" => value.to_s }
        args["global"] = true if global
        append("text", args.freeze)
      end

      # --- Tick or untick a checkbox group (issue #342) ---
      #
      # check_group(group, checked = true) — set every OWNED box of the group
      # (the #15 rule: a nested root's boxes are its own) the way a
      # reactive_select_all header does: every box first, then `input` +
      # `change` on each one it flipped, then ONE re-sync of the header, count,
      # show and enable bindings. The group is a checkbox name resolved like
      # reactive_select_all's: a bare name takes reactive_scope, a bracketed one
      # ("ids[]") is used verbatim. `global: true` is for a trigger outside the
      # root that owns the group: every reactive root on the page flips the
      # boxes it owns. ACTOR-ONLY like focus/submit: a broadcast that cleared
      # every subscriber's selection would be hostile (BROADCAST_REFUSED_OPS).
      #   button(**on_client(:click, js.check_group("ids[]", false))) { "✕" }

      # Positional `checked` on purpose: js.check_group("ids[]", false) reads as
      # the op it is (the issue #342 API).
      def check_group(group, checked = true, global: false) # rubocop:disable Style/OptionalBooleanParameter
        name = group.to_s
        if name.strip.empty?
          raise ArgumentError, "check_group needs a checkbox group name (e.g. \"ids[]\"), got #{group.inspect}"
        end
        unless [true, false].include?(checked)
          raise ArgumentError, "check_group(#{name.inspect}) takes true or false, got #{checked.inspect}"
        end

        args = { "to" => ROOT_SENTINEL, "group" => name, "checked" => checked }
        args["global"] = true if global
        append("check_group", args.freeze)
      end

      # --- Dispatch a bubbling CustomEvent (issue #96) ---
      #
      # dispatch(name, to: nil, detail: {}) — emit a bubbling CustomEvent so other
      # components/controllers can react to a client-only interaction without a
      # round trip. `to:` picks the element to dispatch ON (nil → the component
      # root, serialized as the @root sentinel so the client resolves it
      # uniformly); `detail:` is the event's `detail` payload. The client uses raw
      # element.dispatchEvent — the shared controller SHADOWS Stimulus's
      # this.dispatch helper, so the interpreter must not use it.
      def dispatch(name, to: nil, detail: {}, global: false)
        args = { "name" => name.to_s, "to" => normalize_target(to.nil? ? :root : to), "detail" => detail }
        args["global"] = true if global
        append("dispatch", args.freeze)
      end

      # The wire format: a JSON array of [op, args] pairs, applied in order.
      def to_json(*)
        @ops.to_json
      end

      def empty?
        @ops.empty?
      end

      # --- Client-only drafts (issue #239) ---
      #
      # persist_state(**state) — merge a FLAT bag of scalars (a wizard's
      # current step) into the root's reactive_persist draft alongside the
      # owned fields' values; the client restores it on the next connect as
      # data-reactive-persist-state on the root plus the
      # reactive:persist-restored event's detail.state. Always targets the
      # ROOT (the draft lives there). persist_clear — forget the draft now
      # (the explicit sibling of the automatic turbo:submit-end clear).
      # Both ACTOR-ONLY like focus/submit: a broadcast that rewrote or wiped
      # every subscriber's draft would be hostile (BROADCAST_REFUSED_OPS).

      def persist_state(**state)
        raise ArgumentError, "#{self.class}: persist_state needs at least one key (e.g. step: 2)" if state.empty?

        state.each do |name, value|
          next if value.nil? || [String, Numeric, TrueClass, FalseClass].any? { value.is_a?(it) }

          raise ArgumentError,
            "#{self.class}: persist_state values must be scalar (String/Numeric/true/false/nil) — " \
            "#{name.inspect} is #{value.class} (the draft stays flat)"
        end

        append("persist_state", { "to" => ROOT_SENTINEL, "state" => state.transform_keys(&:to_s).freeze }.freeze)
      end

      def persist_clear
        append("persist_clear", { "to" => ROOT_SENTINEL }.freeze)
      end

      private

      # Immutability: every verb funnels here and returns a NEW frozen chain —
      # a builder held in a constant or memo can never be mutated by later use.
      def append(name, args)
        self.class.new([*@ops, [name, args].freeze].freeze)
      end

      def target_args(to, global:, transition: nil, expanded: nil)
        args = { "to" => normalize_target(to) }
        args["global"] = true if global
        args["transition"] = normalize_transition(transition) if transition
        args["expanded"] = normalize_target(expanded) unless expanded.nil?
        args.freeze
      end

      # The [on, off] pair of a two-value toggle_attr, stringified. Loud on a
      # half-specified pair or one that could never change anything.
      def toggle_values(name, values)
        unless values.size == 2
          raise ArgumentError,
            "#{self.class}: toggle_attr(#{name.to_s.inspect}) takes no values (presence toggle) " \
            "or two values to flip between, got #{values.size}: #{values.inspect}"
        end

        on, off = values.map(&:to_s)
        if on == off
          raise ArgumentError, "#{self.class}: toggle_attr(#{name.to_s.inspect}) values must differ, got #{on.inspect} twice"
        end

        [on, off].freeze
      end

      # An attr op's args: the target, the allowlisted name, an optional
      # (stringified) value. The name is validated LOUDLY at build time.
      def attr_args(to, name, global:, value: :__none)
        name = name.to_s
        assert_allowed_attr(name)
        args = { "to" => normalize_target(to), "name" => name }
        args["value"] = value.to_s unless value == :__none
        args["global"] = true if global
        args.freeze
      end

      # Build-time attr-name allowlist for the instance builder — delegates to the
      # shared class-method check (also used by the raw-list escape hatch).
      def assert_allowed_attr(name)
        self.class.assert_allowed_attr(name)
      end

      # A transition is NAMED legs { during:, from:, to: } (issue #186), compiled to
      # the [during, from, to] wire array (zero client change). The old positional
      # Array form is removed — it raises with the caller's OWN values slotted into
      # the named form, so the rewrite is copy-pasteable.
      def normalize_transition(transition)
        if transition.is_a?(Array)
          d, f, t = transition
          raise ArgumentError,
            "#{self.class}: transition: takes named legs (issue #186) — " \
            "transition: { during: #{d.inspect}, from: #{f.inspect}, to: #{t.inspect} }"
        end
        unless transition.is_a?(Hash) && %i[during from to].all? { transition.key?(it) }
          raise ArgumentError,
            "#{self.class}: transition: must name during:, from:, to: class lists, got #{transition.inspect}"
        end

        [transition[:during], transition[:from], transition[:to]].map(&:to_s).freeze
      end

      def class_args(to, classes, global:)
        if classes.empty?
          raise ArgumentError, "#{self.class}: a class op needs at least one class (got none for #{to.inspect})"
        end

        args = { "to" => normalize_target(to), "classes" => classes.map(&:to_s).freeze }
        args["global"] = true if global
        args.freeze
      end

      # Instance-side alias for the class method (used by the op builder). See
      # JS.normalize_target — the shared :root/selector translation.
      def normalize_target(to) = self.class.normalize_target(to)
    end
  end
end
