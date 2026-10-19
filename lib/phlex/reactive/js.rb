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
    # to the server, nothing is trusted from the client, and a server
    # re-render of the component resets whatever they toggled (the LiveView
    # JS-commands caveat; use a signed action for state the server must know).
    # The exception is `keep: true` (issue #369) on the class, visibility and
    # attribute ops: the client records what the op did to each target, and a
    # MORPH of that element re-applies it, so a selection or an expanded row
    # survives another viewer's broadcast. An element a stream REPLACES is a
    # new element and starts clean. Kept state belongs to one tab, so
    # broadcast_to(js:) refuses the flag.
    #
    # Targets: a CSS selector string is resolved WITHIN the component's root by
    # default (nested reactive roots excluded, issue #15 semantics); `:root`
    # targets the root element itself; `:trigger` (issue #442) targets the
    # element whose on_client binding fired (with on_client's within:, the
    # matching element under it); `global: true` opts a single op out of root
    # scoping (document escape hatch, e.g. a page-level overlay).
    #
    # Reads (issue #442): set_value, text and set_attr take `from:` + `attr:`
    # in place of a literal value — the value is read in the browser off the
    # `from` element (a data-* attribute or its text), so one chain bound once
    # serves every row of a list:
    #   js.set_value("#item-value", from: :trigger, attr: "data-value")
    #
    # The op vocabulary is a fixed whitelist mirrored by the client interpreter
    # — an op name the client doesn't know is warn-and-skipped there
    # (client-side default-deny). Validation here is deliberately LOUD: a bad
    # target or an empty class list raises at render time rather than silently
    # doing nothing in the browser.
    class JS
      # Serialized stand-in for "the component's own root element".
      ROOT_SENTINEL = "@root"

      # Serialized stand-in for "the element whose on_client binding fired"
      # (issue #442). Only an on_client binding has one: a server-pushed op
      # (reply.js, broadcast_to(js:)) or a reactive_on_complete run refuses it.
      TRIGGER_SENTINEL = "@trigger"

      # attr: :text's wire value — read the element's textContent.
      TEXT_READ = "@text"

      # What a from: read may take off an element (issue #442): a data-*
      # attribute — state the server declared on the element — or its text.
      # Two-sided like the write allowlist below: the client refuses anything
      # else in a hand-built record. Narrow on purpose (widening later breaks
      # nothing; narrowing would).
      READABLE_ATTR = /\Adata-[a-z][a-z0-9-]*\z/i

      # The ops whose value from: + attr: can read, and the arg keys that name
      # an element (where a server-pushed op has no @trigger to put).
      READ_OPS = %w[set_value text set_attr].freeze
      TARGET_KEYS = %w[to from expanded submitter].freeze
      # preview_file's into:/name:/wrap: name elements too (its name is no
      # attribute or event name there).
      PREVIEW_TARGET_KEYS = (TARGET_KEYS + %w[into name wrap]).freeze

      # The field-writing ops write a field the author names: never the root
      # (a container) nor the trigger (the element clicked).
      FIELD_REFUSED = {
        :root => "the component root", ROOT_SENTINEL => "the component root",
        :trigger => "the trigger", TRIGGER_SENTINEL => "the trigger"
      }.freeze

      # The positional value set_value/text/set_attr default to, so nil keeps
      # meaning "clear" and only from: may replace it.
      NO_VALUE = Object.new.freeze
      private_constant :NO_VALUE

      # The attribute-name allowlist (issue #96) — the security-critical part of
      # the attr ops, enforced HERE at build time AND again in the client
      # interpreter (two-sided default-deny: a hand-built ops attr must not
      # bypass it either). Rejected:
      #   * /\Aon/i        — event-handler attributes (onclick, onmouseover) → XSS.
      #   * the URL set     — href/src/srcdoc/action/formaction/xlink:href can carry
      #                       a `javascript:` payload; setting them from client ops
      #                       is a navigation/injection surface, not a UI toggle.
      #                       srcset (issue #373) is a URL list that picks what an
      #                       <img> loads: copy_media copies it from a server-rendered
      #                       image instead.
      #   * style           — inline CSS injection; use classes (add_class/...).
      # The INTENDED surface is class ops plus boolean/state attributes:
      #   hidden, disabled, open, selected, aria-*, data-*.
      URL_BEARING_ATTRS = %w[href src srcset srcdoc action formaction xlink:href].freeze
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

      # The op builder's target: normalize_target plus :trigger (issue #442).
      # Separate so a pending hint or a css-vars binding given :trigger keeps
      # raising — neither has a trigger element.
      def self.normalize_client_target(to)
        return TRIGGER_SENTINEL if to == :trigger
        return ROOT_SENTINEL if to == :root
        return to if to.is_a?(String)

        raise ArgumentError,
          "target must be :trigger, :root or a CSS selector string, got #{to.inspect}"
      end

      # Also refuses @trigger (a raw list is server-pushed or a
      # reactive_on_complete run: no trigger) and a read attr outside the
      # data-*/text rule (issue #442).
      def self.assert_ops_allowed!(list)
        refuse_trigger!(list)
        Array(list).each do |op, args|
          next unless args.is_a?(::Hash)

          name = arg(args, "name")
          assert_allowed_attr(name.to_s) if name && ATTR_NAME_OPS.include?(op.to_s)
          # A read: the client takes args.attr only on a read op with a from.
          read_attr(arg(args, "attr"), op) if READ_OPS.include?(op.to_s) && arg(args, "from")
        end
      end

      # Raise when an op in `list` (a JS chain or a raw [[op, args]] list)
      # names @trigger (a target, from:, or dispatch's detail_from:, which
      # reads off it). Called for every op the server pushes
      # (Response.js_ops_json: reply.js and broadcast_to(js:)) and for a
      # reactive_on_complete run.
      def self.refuse_trigger!(list, where = "a server-pushed op (reply.js, broadcast_to(js:)) " \
                                             "or a reactive_on_complete run")
        op = trigger_op(list.is_a?(JS) ? list.ops : list)
        return if op.nil?

        raise ArgumentError,
          "#{self}: #{op} names @trigger, the element whose on_client binding fired (a :trigger " \
          "target, from: :trigger or detail_from:) — #{where} has no trigger. Name the element " \
          "with a CSS selector."
      end

      # The name of the first op that names @trigger, or nil. A raw list, or a
      # hand-built JS.new([...]), may carry Symbol keys or no args Hash. An
      # empty detail_from reads nothing (the client skips it too).
      def self.trigger_op(list)
        Array(list).each do |op, args|
          next unless args.is_a?(::Hash)

          reads = arg(args, "detail_from")
          return op.to_s if reads.respond_to?(:empty?) ? !reads.empty? : reads

          keys = op.to_s == "preview_file" ? PREVIEW_TARGET_KEYS : TARGET_KEYS
          return op.to_s if keys.any? { arg(args, it) == TRIGGER_SENTINEL }
        end
        nil
      end

      # What attr: may read (issue #442): :text (or its "@text" wire form) or a
      # data-* attribute name. Returns the wire value; raises otherwise.
      def self.read_attr(attr, verb = "a read")
        return TEXT_READ if [:text, TEXT_READ].include?(attr)
        return attr if attr.is_a?(String) && attr.match?(READABLE_ATTR)

        raise ArgumentError,
          "#{self}: #{verb} attr: reads a data-* attribute or :text (textContent), got #{attr.inspect}"
      end

      # A raw list's args may carry String or Symbol keys.
      def self.arg(args, key) = args.key?(key) ? args[key] : args[key.to_sym]
      private_class_method :arg

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
      #
      # `keep:` (issue #369) — on show/hide/toggle, the class ops and the attr
      # ops: a morph of the target re-applies the op's result (the class on or
      # off, `hidden`, the attribute's value or its absence) instead of the
      # server render's. The latest kept op on an element and a class or
      # attribute wins, so "clear all, then select one" works:
      #   js.remove_class(".item", "selected", keep: true).add_class("#item-2", "selected", keep: true)
      # With `expanded:`, the trigger's aria-expanded is kept too.

      def show(to, global: false, transition: nil, expanded: nil, keep: false)
        append("show", target_args(to, global:, transition:, expanded:, keep:))
      end

      def hide(to, global: false, transition: nil, expanded: nil, keep: false)
        append("hide", target_args(to, global:, transition:, expanded:, keep:))
      end

      def toggle(to, global: false, transition: nil, expanded: nil, keep: false)
        append("toggle", target_args(to, global:, transition:, expanded:, keep:))
      end

      # --- Classes ---

      def add_class(to, *classes, global: false, keep: false)
        append("add_class", class_args(to, classes, global:, keep:))
      end

      def remove_class(to, *classes, global: false, keep: false)
        append("remove_class", class_args(to, classes, global:, keep:))
      end

      def toggle_class(to, *classes, global: false, keep: false)
        append("toggle_class", class_args(to, classes, global:, keep:))
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
      #
      # set_attr(to, name, from:, attr:) (issue #442) reads the value off an
      # element instead (see #set_value); the name allowlist above still
      # decides what may be WRITTEN:
      #   js.set_attr(:trigger, "aria-selected", "true")
      #   js.set_attr("#preview", "data-state", from: :trigger, attr: "data-state")

      def set_attr(to, name, value = NO_VALUE, from: nil, attr: nil, global: false, keep: false)
        append("set_attr", attr_args(to, name, global:, keep:) { value_args(it, "set_attr", value, from:, attr:) })
      end

      def remove_attr(to, name, global: false, keep: false)
        append("remove_attr", attr_args(to, name, global:, keep:))
      end

      def toggle_attr(to, name, *values, global: false, keep: false)
        args = attr_args(to, name, global:, keep:)
        return append("toggle_attr", args) if values.empty?

        append("toggle_attr", with_keep(args.except("keep").merge("values" => toggle_values(name, values)), keep))
      end

      # --- Focus (issue #96) ---
      #
      # focus(to)        — focus the FIRST match of the selector.
      # focus_first(to)  — focus the first FOCUSABLE DESCENDANT of the match
      #                    (e.g. focus the first menuitem inside an opened menu).
      # blur(to)         — blur the focused element when it IS the match or sits
      #                    inside it (issue #399): Escape ends a menu's
      #                    :focus-within. Focus elsewhere is left alone.

      def focus(to, global: false)
        append("focus", target_args(to, global:))
      end

      def focus_first(to, global: false)
        append("focus_first", target_args(to, global:))
      end

      def blur(to, global: false)
        append("blur", target_args(to, global:))
      end

      # --- Modal dialogs (issue #365) ---
      #
      # show_modal(to)   — HTMLDialogElement#showModal(): the top layer, a
      #                    focus trap, ::backdrop, Escape to close and focus
      #                    restored to the opener, all the browser's own. A
      #                    dialog already open NON-modally is closed and
      #                    reopened as a modal; one already modal is left as is.
      # close_dialog(to) — HTMLDialogElement#close() (a closed one is left as is).
      # A target that is not a <dialog> is skipped. Both ACTOR-ONLY like focus:
      # opening a modal steals focus, so a broadcast refuses them — a
      # broadcaster renders the dialog open with data: { reactive_modal: true }.

      def show_modal(to, global: false)
        append("show_modal", target_args(to, global:))
      end

      def close_dialog(to, global: false)
        append("close_dialog", target_args(to, global:))
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

        unless submitter == :trigger || (submitter.is_a?(String) && !submitter.empty?)
          raise ArgumentError,
            "js.submit submitter: must be a CSS selector string naming a submit control " \
            "(or :trigger), got #{submitter.inspect}"
        end

        append("submit", args.merge("submitter" => normalize_target(submitter)).freeze)
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
        refuse_field_target!(to, "paste_into targets a field, not %s — " \
                                 "pass the input's CSS selector (e.g. js.paste_into(\"[name=code]\"))")
        append("paste_into", target_args(to, global:))
      end

      # --- Preview a chosen file (issue #375) ---
      #
      # preview_file(to, into:, name: nil) — on the file input's change, paint
      # the first chosen IMAGE file onto the `into:` img through an object URL
      # the client creates itself (URL.createObjectURL) and revokes on the next
      # choice, on a clear, and when the img leaves the page. The op carries NO
      # URL — there is no parameter for one, and the client never reads a `url`
      # key — so the `src` refusal of set_attr (issue #96) stays whole. `to` is
      # an input[type=file] (an explicit :root is refused); `into:` must
      # resolve to an <img> (anything else warns and is skipped in the
      # browser); `name:` optionally names a node that gets file.name as
      # textContent. An empty selection or a non-image file clears the preview.
      # ACTOR-ONLY like paste_into: refused in broadcast_to(js:) — a broadcast
      # that read every subscriber's file input would be hostile.
      #   input(type: "file", id: "photo-file", accept: "image/*",
      #     **on_client(:change, js.preview_file("#photo-file", into: "#photo", name: "#photo-name")))
      #
      # Upload validation (issue #382): `valid: true` treats an input whose
      # validity is false (setCustomValidity, required) as empty, so a rejected
      # file never gets a preview. An app that clears the input without a
      # change event dispatches `reactive:file-changed` on it; bind the same op
      # to that event too and the preview clears:
      #   op = js.preview_file("#photo-file", into: "#photo", valid: true)
      #   input(type: "file", id: "photo-file",
      #     **mix(on_client(:change, op), on_client("reactive:file-changed", op)))
      #
      # The box and the refusals (issue #391): `wrap:` is a CSS selector the
      # client shows when it paints an image and hides when the preview clears
      # (it shows again only a wrapper it hid itself, never one the author
      # hid, and never writes its text). `max_bytes:` (a positive Integer)
      # refuses a larger file before any object URL exists. `accept: true`
      # reads the input's own accept attribute (extensions, MIME types,
      # type/*); a String is that list for this op; omitted keeps the image/*
      # rule. Only an image is painted: a listed non-image (a PDF) clears the
      # preview and hides `wrap:`, unrefused. A refused file clears the img,
      # hides `wrap:` and dispatches
      # `reactive:file-rejected` on the input (detail.reason "type" | "size").
      # The op never clears input.files nor sets a custom validity message.
      #   input(type: "file", id: "photo-file", accept: "image/png,image/jpeg",
      #     **on_client(:change, js.preview_file("#photo-file", into: "#photo",
      #       wrap: "#photo-frame", max_bytes: 2_000_000, accept: true)))
      #
      # Several files (issue #439): `per_file: true` on an input with
      # `multiple` checks EVERY file (accept, then max_bytes), rebuilds
      # input.files from the accepted ones (synchronously, so an
      # `on(:action, event: "change")` mixed in AFTER the op posts only those),
      # dispatches one `reactive:file-rejected` per refused file
      # (detail.reason, file, index — its place in the pick — and remaining,
      # how many files the input keeps), and paints the first accepted image.
      # A single input, or per_file: omitted, keeps the behaviour above.
      #   input(type: "file", id: "pick", name: "file", multiple: true, accept: "image/png",
      #     **mix(on_client(:change, js.preview_file("#pick", into: "#shot", max_bytes: 1_000_000,
      #       accept: true, per_file: true)), on(:upload, event: "change")))
      #
      # Name each refused file (issue #445): `rejected:` is a CSS selector (like
      # `into:`) for a container whose first <template> child the client clones
      # once per refused file, in pick order, before any reactive:file-rejected
      # fires. In each clone every [data-reactive-file="name"] gets file.name as
      # textContent (never HTML), and every [data-reactive-file-reason] part
      # whose value is not that file's reason is removed (a reason with no part
      # keeps only the unmarked parts; a reason part at the top level lists only
      # the reasons it names). Each top-level element
      # of a clone is marked data-reactive-file-rejected and appended; the next
      # run of the op removes the marked ones first (a pick with no refusal
      # empties the list), and a morph of the container keeps them.
      #   ul(id: "refused") do
      #     template do
      #       li do
      #         span(data: { reactive_file_reason: "size" }) { b(data: { reactive_file: "name" }); plain " is too large." }
      #         span(data: { reactive_file_reason: "type" }) { b(data: { reactive_file: "name" }); plain " is not a PNG." }
      #       end
      #     end
      #   end
      #   js.preview_file("#pick", into: "#shot", max_bytes: 1_000_000, accept: true, per_file: true, rejected: "#refused")

      def preview_file(to, into:, name: nil, global: false, valid: false, wrap: nil, max_bytes: nil, accept: nil,
                       per_file: false, rejected: nil)
        refuse_field_target!(to, "preview_file reads a file input, not %s — pass the input's CSS selector " \
                                 "(e.g. js.preview_file(\"#photo-file\", into: \"#photo\"))")
        args = { "to" => normalize_target(to), "into" => preview_selector(:into, into) }
        args["name"] = preview_selector(:name, name) unless name.nil?
        args["global"] = true if global
        args["valid"] = true if valid
        args["wrap"] = preview_selector(:wrap, wrap) unless wrap.nil?
        args["max_bytes"] = preview_max_bytes(max_bytes) unless max_bytes.nil?
        args["accept"] = preview_accept(accept) unless accept.nil? || accept == false
        args["per_file"] = true if preview_per_file(per_file)
        args["rejected"] = preview_selector(:rejected, rejected) unless rejected.nil?
        append("preview_file", args.freeze)
      end

      # --- Text content (issue #159) ---
      #
      # text(to, value) — set the target's textContent (stringified; nil clears).
      # XSS-safe by construction: textContent only, NEVER innerHTML — strictly
      # less powerful than set_attr. Pair with `global: true` to paint a value
      # into a node OUTSIDE the component's root (the cross-root text escape,
      # e.g. a read-only recap in another tab pane).
      #
      # text(to, from:, attr:) (issue #442) reads the text off an element
      # instead (see #set_value) — the label of the row that was clicked:
      #   js.text("#item-label", from: :trigger, attr: "data-label")

      def text(to, value = NO_VALUE, from: nil, attr: nil, global: false)
        args = { "to" => normalize_target(to) }
        value_args(args, "text", value, from:, attr:)
        args["global"] = true if global
        append("text", args.freeze)
      end

      # --- Copy a server-rendered image (issue #373) ---
      #
      # copy_media(to, from:) — copy src, srcset and alt from the `from` <img>
      # onto the `to` <img>. Both are ELEMENTS (:root or a CSS selector,
      # resolved with the op's own scoping, global: included): the URL is read
      # off the live source element in the browser and is never an argument,
      # so the set_attr refusal of src (issue #96) stays. A missing or
      # non-<img> source clears the target's src, srcset and alt; an <img>
      # source without src removes the target's src and srcset and copies its
      # alt (issue #381); a target that is not an <img> is skipped. The same URL twice
      # is not written again (no reload). Broadcast-safe: it only reads
      # elements already in the subscriber's document.
      #   button(**on_client(:click, js.copy_media("#logo", from: "#logo-007"))) { "North" }

      def copy_media(to, from:, global: false)
        source = normalize_target(from)
        raise ArgumentError, "#{self.class}: copy_media from: needs a CSS selector, got an empty string" if source.empty?

        args = { "to" => normalize_target(to), "from" => source }
        args["global"] = true if global
        append("copy_media", args.freeze)
      end

      # --- A field's live value (issue #374) ---
      #
      # set_value(to, value) — assign the target field's IDL `.value` (never
      # the attribute: that is set_attr, and a field the user typed in does not
      # follow it), then dispatch a bubbling `input` when the value changed, so
      # reducers and reactive_show see it as typed — the set-value contract
      # paste_into uses (issue #183). Never `change`, never focus (chain
      # js.focus for that), never parsed as HTML. The value is stringified; nil
      # and "" clear the field. The target is an input, textarea or select:
      # :root is refused loudly like paste_into, and anything else (a
      # contenteditable — reactive_editable writes those — a non-field, a
      # non-empty value for a file input) warns and skips in the browser.
      # ACTOR-ONLY like paste_into: a broadcast that overwrote every
      # subscriber's field would be hostile (BROADCAST_REFUSED_OPS).
      #   button(**on_client(:click, js.set_value("#notes", "Thanks"))) { "Thanks" }
      #
      # Reads (issue #442): `from:` + `attr:` in place of the value read it in
      # the browser off an element — `from:` is :trigger, :root or a selector,
      # resolved with the op's own scoping (global: included), first match;
      # `attr:` is a data-* attribute or :text (textContent). A missing
      # attribute reads "", so it clears; a `from:` matching nothing skips the
      # op. Exactly one of the value or `from:`. The same on text and set_attr:
      #   ul(**on_client(:click, js.set_value("#item-value", from: :trigger, attr: "data-value"),
      #                  within: "[role=option]"))

      def set_value(to, value = NO_VALUE, from: nil, attr: nil, global: false)
        refuse_field_target!(to, "set_value targets a field, not %s — " \
                                 "pass the field's CSS selector (e.g. js.set_value(\"#notes\", \"Thanks\"))")
        args = { "to" => normalize_target(to) }
        value_args(args, "set_value", value, from:, attr:)
        args["global"] = true if global
        append("set_value", args.freeze)
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
      # root that owns the group: EVERY connected reactive root on the page flips the
      # boxes of that name it owns (nested roots included). ACTOR-ONLY like focus/submit: a broadcast that cleared
      # every subscriber's selection would be hostile (BROADCAST_REFUSED_OPS).
      #   button(**on_client(:click, js.check_group("ids[]", false))) { "✕" }

      # Positional `checked` on purpose: js.check_group("ids[]", false) reads as
      # the op it is (the issue #342 API).
      def check_group(group, checked = true, global: false) # rubocop:disable Style/OptionalBooleanParameter
        name = -group.to_s
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
      #
      # detail_from: (issue #442) maps detail keys to what to read off the
      # TRIGGER (a data-* attribute or :text), merged over `detail:` in the
      # browser — every value a String. Only an on_client binding has a
      # trigger: a server-pushed dispatch refuses it.
      #   js.dispatch("app:item-picked", detail_from: { id: "data-id", text: :text })
      def dispatch(name, to: nil, detail: {}, detail_from: {}, global: false)
        args = { "name" => name.to_s, "to" => normalize_target(to.nil? ? :root : to), "detail" => detail }
        args["detail_from"] = detail_reads(detail, detail_from) unless detail_from.nil? || detail_from == {}
        args["global"] = true if global
        append("dispatch", args.freeze)
      end

      # --- Presence (issue #358) ---
      #
      # presence(**state) — write this tab's presence state through the root's
      # generated presence_set action (reactive_presence): only the declared
      # keys reach the server, typed like action params. Always targets the
      # ROOT, which must declare reactive_presence (the client warns and does
      # nothing otherwise). ACTOR-ONLY like focus/submit: a broadcast that set
      # every subscriber's selection would be hostile (BROADCAST_REFUSED_OPS).
      #   li(**on_client(:click, js.presence(selected: item.id))) { item.title }
      def presence(**state)
        raise ArgumentError, "#{self.class}: presence needs at least one state key (e.g. selected: 7)" if state.empty?

        state.each do |name, value|
          next if value.nil? || [String, Integer, TrueClass, FalseClass].any? { value.is_a?(it) }
          next if value.is_a?(Float) && value.finite? # NaN and Infinity have no JSON form

          raise ArgumentError,
            "#{self.class}: presence state values must be scalar (String/Integer/finite Float/true/false/nil) — " \
            "#{name.inspect} is #{value.class}"
        end

        append("presence", { "to" => ROOT_SENTINEL, "state" => state.transform_keys(&:to_s).freeze }.freeze)
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

      def target_args(to, global:, transition: nil, expanded: nil, keep: false)
        args = { "to" => normalize_target(to) }
        args["global"] = true if global
        args["transition"] = normalize_transition(transition) if transition
        args["expanded"] = normalize_target(expanded) unless expanded.nil?
        with_keep(args, keep)
      end

      # keep: (issue #369) rides LAST and only when true, so an op without it
      # serializes byte-identically to before.
      def with_keep(args, keep)
        args["keep"] = true if keep
        args.freeze
      end

      # preview_file's into:/name:/wrap:/rejected: — a non-empty CSS selector
      # String, never :root or its "@root" sentinel (the root is a container,
      # not the img — and a name: on it would replace the whole component with a
      # file name), nor "@trigger" (issue #442; the Symbol :trigger is no
      # String): the preview goes into elements the author names.
      def preview_selector(key, selector)
        if selector.is_a?(String) && !selector.strip.empty? && ![ROOT_SENTINEL, TRIGGER_SENTINEL].include?(selector)
          return selector
        end

        raise ArgumentError,
          "#{self.class}: preview_file #{key}: must be a CSS selector string, got #{selector.inspect}"
      end

      def preview_max_bytes(bytes)
        return bytes if bytes.is_a?(Integer) && bytes.positive?

        raise ArgumentError,
          "#{self.class}: preview_file max_bytes: must be a positive Integer, got #{bytes.inspect}"
      end

      # per_file: is a strict boolean (nil, like the other keywords, means
      # omitted): a typo'd truthy value must not change which files an upload posts.
      def preview_per_file(per_file)
        return per_file == true if [true, false, nil].include?(per_file)

        raise ArgumentError,
          "#{self.class}: preview_file per_file: must be true, false or nil, got #{per_file.inspect}"
      end

      # true reads the input's accept attribute; a String is the list itself.
      def preview_accept(accept)
        return accept if accept == true || (accept.is_a?(String) && !accept.strip.empty?)

        raise ArgumentError,
          "#{self.class}: preview_file accept: must be true or an accept list " \
          "(e.g. \"image/png,.jpg\"), got #{accept.inspect}"
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

      # An attr op's args: the target, the allowlisted name, then whatever the
      # block adds (set_attr's value or read). The name is validated LOUDLY at
      # build time.
      def attr_args(to, name, global:, keep: false)
        name = name.to_s
        assert_allowed_attr(name)
        args = { "to" => normalize_target(to), "name" => name }
        yield args if block_given?
        args["global"] = true if global
        with_keep(args, keep)
      end

      # The value of set_value/text/set_attr (issue #442): the literal
      # (stringified; nil clears) as "value", or a read as "from" + "attr".
      # Exactly one — loud at render.
      def value_args(args, verb, value, from:, attr:)
        literal = !value.equal?(NO_VALUE)
        raise ArgumentError, "#{self.class}: #{verb} takes a value or from:, not both" if literal && !from.nil?
        if from.nil? && !attr.nil?
          raise ArgumentError,
            "#{self.class}: #{verb} attr: needs from: (the element to read it off)"
        end
        return args["value"] = value.to_s if literal
        raise ArgumentError, "#{self.class}: #{verb} needs a value or from: + attr:" if from.nil?
        raise ArgumentError, "#{self.class}: #{verb} from: needs attr: (a data-* attribute or :text)" if attr.nil?

        source = normalize_target(from)
        raise ArgumentError, "#{self.class}: #{verb} from: needs a CSS selector, got an empty string" if source.empty?

        args["from"] = source
        args["attr"] = self.class.read_attr(attr, verb)
      end

      # dispatch's detail_from: — detail key → read attr, the keys Strings.
      # A key also in detail: would silently override it, so it raises; so does
      # a detail: that is no Hash (the browser merges the reads over it).
      def detail_reads(detail, reads)
        unless reads.is_a?(Hash)
          raise ArgumentError,
            "#{self.class}: dispatch detail_from: takes a Hash of detail keys to data-* attributes " \
            "(or :text), got #{reads.inspect}"
        end
        unless detail.nil? || detail.is_a?(Hash)
          raise ArgumentError, "#{self.class}: dispatch detail_from: merges over a Hash detail:, got #{detail.inspect}"
        end

        literal = detail.nil? ? [] : detail.keys.map(&:to_s)
        normalized = reads.to_h do |key, attr|
          key = key.to_s
          if literal.include?(key)
            raise ArgumentError,
              "#{self.class}: dispatch detail_from: key #{key.inspect} is also in detail: — one would override the other"
          end

          [key, self.class.read_attr(attr, "dispatch detail_from: #{key.inspect}")]
        end
        if normalized.size < reads.size
          raise ArgumentError, "#{self.class}: dispatch detail_from: keys must be unique as strings"
        end

        normalized.freeze
      end

      # set_value/paste_into/preview_file write a field the author names:
      # `message` has a %s for what was named instead (the root, the trigger).
      def refuse_field_target!(to, message)
        where = FIELD_REFUSED[to]
        raise ArgumentError, "#{self.class}: #{format(message, where)}" if where
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

      def class_args(to, classes, global:, keep: false)
        if classes.empty?
          raise ArgumentError, "#{self.class}: a class op needs at least one class (got none for #{to.inspect})"
        end

        args = { "to" => normalize_target(to), "classes" => classes.map(&:to_s).freeze }
        args["global"] = true if global
        with_keep(args, keep)
      end

      # The op builder's target translation: :trigger, :root or a selector
      # (JS.normalize_client_target; issue #442).
      def normalize_target(to) = self.class.normalize_client_target(to)
    end
  end
end
