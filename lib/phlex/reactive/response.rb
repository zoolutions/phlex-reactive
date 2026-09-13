# frozen_string_literal: true

module Phlex
  module Reactive
    # An explicit, immutable description of the ACTOR's HTTP response to a
    # reactive action. An action MAY return one; if it returns anything else
    # (the legacy contract — return value ignored), the endpoint falls back to
    # the implicit single component.to_stream_replace.
    #
    # A Response governs ONLY the actor's HTTP reply. Cross-tab updates still go
    # through Streamable's broadcast_*_to(..., exclude: reactive_connection_id).
    #
    # An action builds one through `reply` (issue #182 — the ONE door; the former
    # Response.* class verbs are removed and raise a guided rewrite):
    #
    #   reply.replace                          # re-render in place (the default, explicit)
    #   reply.replace.flash(:error, msg)       # surface a validation error
    #   reply.replace.also(heading: @record.name)  # + a companion element by id
    #   reply.remove                           # drop the element (e.g. moderation queue)
    #   reply.redirect(article_url(@article))  # slug changed -> Turbo.visit the new URL
    #   reply.replace.stream(Totals.update(@order))  # multi-stream
    class Response
      attr_reader :streams, :redirect_url, :token_component, :subject_component

      # Issue #182: `reply` is the ONE documented door. Each former public class
      # verb (Response.replace(self), …) is removed — it raises a guided
      # ArgumentError naming the `reply.<verb>` rewrite. The builder BODIES live
      # on as internal-use `build_*` class methods (public in Ruby terms — Reply
      # calls them directly — but NOT part of the documented reply-facing surface;
      # Response stays the single place that knows how to construct itself). The
      # rewrite shown for a collection verb points at the keyword form (issue #182).
      REMOVED_CLASS_VERBS = {
        replace: "reply.replace",
        morph: "reply.morph",
        update: "reply.update",
        remove: "reply.remove",
        redirect: "reply.redirect(url)",
        with: "reply.with(*streams)",
        streams: "reply.streams(*streams)",
        collection_append: "reply.append(model, to: :name)",
        collection_prepend: "reply.prepend(model, to: :name)",
        collection_remove: "reply.remove(model, from: :name)"
      }.freeze

      # rubocop:disable Style/ItBlockParameter -- `it` is illegal inside the
      # define_singleton_method block (it takes ordinary |*, **| params), so the
      # outer each_key must name its param explicitly.
      REMOVED_CLASS_VERBS.each_key do |verb|
        define_singleton_method(verb) do |*, **|
          raise ArgumentError,
            "Phlex::Reactive::Response.#{verb} was removed in issue #182 — " \
            "return #{REMOVED_CLASS_VERBS[verb]} from the action (reply is the only door)"
        end
      end
      # rubocop:enable Style/ItBlockParameter

      class << self
        # Re-render the component in place (explicit form of today's default).
        # `morph: true` morphs the subtree (preserves the focused input + caret)
        # instead of an outerHTML swap — see .build_morph (issue #28).
        # `effect:` (issue #215) stamps the per-call effect override on the
        # emitted stream — same on every self-targeting builder below.
        def build_replace(component, morph: false, effect: nil)
          new(streams: [component.to_stream_replace(morph:, effect:)],
            subject_component: component)
        end

        # Re-render the component in place via Idiomorph (issue #28). Emits
        # `<turbo-stream action="replace" method="morph">`, so Turbo 8 morphs the
        # subtree — the focused <input> + caret survive the save. Use this for
        # per-field reactive editing (a "spreadsheet" grid where a debounced save
        # fires while the user is still typing/tabbing). The morphed root still
        # carries the fresh signed token, so the next action verifies.
        def build_morph(component, effect: nil)
          new(streams: [component.to_stream_replace(morph: true, effect:)], subject_component: component)
        end

        # Update only inner HTML (preserves the root element + its token attr).
        # `morph: true` morphs the inner HTML in place (issue #113) instead of
        # replacing it, so a cross-tab update keeps a peer's focus/caret.
        def build_update(component, morph: false, effect: nil)
          new(streams: [component.to_stream_update(morph:, effect:)], subject_component: component)
        end

        # Remove the component's element from the DOM. Uses the instance
        # to_stream_remove (the component already knows its own #id — no
        # class-builder reconstruction; works for record- and state-backed).
        def build_remove(component, effect: nil)
          new(streams: [component.to_stream_remove(effect:)], render_self: false)
        end

        # Client-side full navigation (Turbo.visit). Use when the current URL
        # is dead (slug rename) or the outcome belongs on another page. Pass a
        # *_url (the off-request render context has no request host for *_path).
        def build_redirect(url) = new(redirect_url: url, render_self: false)

        # Escape hatch / multi-stream root: zero or more raw turbo-stream strings.
        def build_with(*strings) = new(streams: strings.flatten)

        # --- Reactive collections (issue #35) ---
        # Add/remove a row in a declared reactive_collection, emitting the row
        # stream + the count companion update + the empty-state toggle as ONE
        # Response. `component` is the bound CONTAINER (it carries the
        # declaration and the size resolver); `model` is the row's record (or, for
        # remove, a model OR a dom-id string). count/empty/size are optional — a
        # stream is emitted only for the pieces declared.
        #
        # render_self is false: the row append/prepend/remove IS the update, so
        # we must NOT also replace the whole container (that would re-render every
        # row and clobber the just-streamed delta).
        #
        # token_component is the CONTAINER (cosmos#1939): a reply that does NOT
        # re-render self must STILL refresh self's signed token, or the list is
        # add-once-only — correct on the first click, then every subsequent dispatch
        # from the list root is rejected (its token went stale) with no error. The
        # container owns the add/remove trigger, so the endpoint appends its inert
        # `reactive:token` stream (the same #30 machinery reply.streams uses) to roll
        # the token forward without re-rendering the rows.
        # `effect:` (issue #215) stamps the ROW stream only — the count
        # companion and the empty-state toggle are bookkeeping, not the thing
        # entering/leaving.
        # Issue #248: the bookkeeping BODIES moved to Phlex::Reactive::Collections
        # so the job-side settle and the peers broadcast run the SAME code. These
        # builders keep their exact behaviour by delegating.
        def build_collection_append(component, name, model, effect: nil, **row_kwargs)
          definition = Phlex::Reactive::Collections.definition!(component, name)
          new(streams: Phlex::Reactive::Collections.add_streams(definition, component, model, :append, row_kwargs,
            effect:), render_self: false, token_component: component)
        end

        def build_collection_prepend(component, name, model, effect: nil, **row_kwargs)
          definition = Phlex::Reactive::Collections.definition!(component, name)
          new(streams: Phlex::Reactive::Collections.add_streams(definition, component, model, :prepend, row_kwargs,
            effect:), render_self: false, token_component: component)
        end

        def build_collection_remove(component, name, model, effect: nil)
          definition = Phlex::Reactive::Collections.definition!(component, name)
          new(streams: Phlex::Reactive::Collections.remove_streams(definition, component, model, effect:),
            render_self: false, token_component: component)
        end

        # --- Async-action lifecycle (issue #248) ---
        # Mark targets pending and hand the fulfilment to the app's own job. The
        # reply deliberately does NOT re-render the container: re-rendering it
        # here would draw the PRE-JOB world (the endpoint renders inside the
        # transaction; the queue publishes on commit) — the exact bug this verb
        # exists to fix. render_self is therefore false, with the container as
        # token_component so the signed token still rolls forward (cosmos#1939 —
        # without it the list is act-once-only).
        #
        # The Response only RECORDS the segment; the ENDPOINT turns it into the
        # marker + directive streams after the transaction committed.
        # Pull `in:` out of reply.pending's **opts and REFUSE anything left over.
        # `in` is a Ruby keyword, so it cannot be a named parameter — which means
        # every other keyword lands in **opts and would otherwise be silently
        # dropped. A typo (`jbo:` for `job:`) would then mark the rows pending
        # and enqueue NOTHING: a permanently shimmering row, the exact failure
        # this feature exists to prevent. So it fails at the call site instead.
        def pending_collection!(opts)
          collection = opts.delete(:in)
          unless opts.empty?
            raise ArgumentError,
              "reply.pending got unknown keyword(s) #{opts.keys.map(&:inspect).join(", ")} — " \
              "it takes in:, job:, args:, peers: and a block. A dropped keyword would mark the " \
              "targets pending with nothing to settle them."
          end

          collection
        end

        def build_pending(component, records, collection:, peers:, job:, args:, enqueue:)
          segment = Phlex::Reactive::Pending.build_segment(
            component, records, collection:, peers:, job:, args:, enqueue:
          )
          new(streams: [], render_self: false, token_component: component,
            pending_segments: segment ? [segment] : NO_SEGMENTS)
        end

        # Partial / per-field update with a TOKEN-ONLY refresh (issue #30). Emits
        # EXACTLY the given streams — no forced full-self replace — but binds
        # `component` so the endpoint appends its tiny `to_stream_token` stream.
        # So the signed token rolls forward (the next action verifies) while the
        # component's own live inputs are never torn down: ideal for a
        # spreadsheet-like grid where a debounced save re-streams only a total
        # cell and the user is still typing in a sibling field.
        #
        #   reply.streams(Totals.update(@invoice))   # update only the totals
        #
        # render_self is false (we do NOT inject the full replace); the token is
        # refreshed by the bound component's token stream instead.
        def build_streams(component, *strings)
          new(streams: strings.flatten, render_self: false, token_component: component)
        end

        # Build a flash turbo-stream that appends `content` into a host-app
        # container. `content` is a Phlex component instance (rendered through
        # the configured renderer so t()/url_for work) or a String — supplied
        # by the caller because the render context is off-request (there is no
        # Rails `flash`). The LEVEL reaches the wire (issue #77): string
        # content gets a level-carrying wrapper (or the configured
        # Phlex::Reactive.flash_component); component content renders VERBATIM
        # — the caller owns the markup, no wrapper, no double-wrapping.
        def flash_stream(level, content, target:, dismiss_after: nil)
          Phlex::Reactive.stream_builder.append(target, html: flash_html(level, content, dismiss_after))
        end

        # Resolve flash `content` to HTML, carrying the level (issue #77):
        #   * a Phlex component instance — rendered verbatim, exactly as before
        #     (byte-identical; it also bypasses flash_component).
        #   * a String with Phlex::Reactive.flash_component configured — the
        #     app's component is instantiated new(level:, content:) and
        #     rendered through the existing render_html path.
        #   * a String otherwise — the default level-carrying wrapper below.
        def flash_html(level, content, dismiss_after = nil)
          # Verbatim Phlex component content owns its own markup (and lifecycle),
          # so dismiss_after has nowhere to hang — it wraps only string content.
          return render_html(content) if content.is_a?(::Phlex::SGML)

          builder = Phlex::Reactive.flash_component
          if builder
            # The app-owned callable maps (level, content) to its own component —
            # the gem no longer guesses kwargs (issue #182).
            html = render_html(builder.call(level, content))
            return dismiss_after ? wrap_dismiss(html, dismiss_after) : html
          end

          default_flash_html(level, content, dismiss_after)
        end

        # The default string-flash wrapper:
        #   <div class="reactive-flash reactive-flash--{level}"
        #        data-reactive-flash-level="{level}">{content}</div>
        # The level is unconditionally HTML-escaped (it lands in a class name
        # and a data attribute). The content keeps the exact pre-#77 injection
        # contract, now applied INSIDE the wrapper: ERB::Util.html_escape
        # escapes a plain String but passes an html_safe String verbatim —
        # the same behavior Turbo's TagBuilder gave the unwrapped string, so
        # a model value still can't inject markup while intentional raw HTML
        # (html_safe) still renders. The wrapper is html_safe by construction
        # (both interpolations are escaped above), so the TagBuilder emits it
        # as-is.
        def default_flash_html(level, content, dismiss_after = nil)
          level_attr = CGI.escapeHTML(level.to_s)
          body = ERB::Util.html_escape(content.to_s)

          # html_safe is safe by construction: every interpolated piece is escaped
          # (dismiss_attr coerces to an integer, so it can't inject an attribute).
          %(<div class="reactive-flash reactive-flash--#{level_attr}" \
data-reactive-flash-level="#{level_attr}"#{dismiss_attr(dismiss_after)}>#{body}</div>).html_safe
        end

        # Issue #182: flash rendering is an INTERNAL concern — the endpoint's
        # error_flash path and Response#flash reach these via send. They are not
        # part of the public reply surface. (Inside `class << self`, plain `private`
        # marks these singleton methods private — private_class_method is for the
        # class body, not here.)
        private :flash_stream, :flash_html, :default_flash_html

        # The self-dismiss attribute, or "" when off. The value is forced through
        # to_i so a String/float (or an injection attempt) becomes a plain integer
        # — the client's document-level handler reads it as a timeout in ms.
        def dismiss_attr(dismiss_after)
          return "" if dismiss_after.nil?

          %( data-reactive-dismiss-after="#{dismiss_after.to_i}")
        end

        # Wrap already-rendered flash HTML (the flash_component path) in a
        # dismiss-bearing div. SafeBuffer#to_s returns SELF, so concatenate the
        # html_safe pieces (never .to_s + raw) to keep the buffer safe.
        def wrap_dismiss(html, dismiss_after)
          (%(<div#{dismiss_attr(dismiss_after)}>).html_safe + html.html_safe + "</div>".html_safe)
        end

        # Build a turbo-stream that updates an arbitrary target id with `content`
        # (a Phlex component instance or an HTML string). Used by #also to
        # re-render a companion element that isn't itself a Streamable component.
        def update_stream(target, content)
          Phlex::Reactive.stream_builder.update(target, html: render_html(content))
        end

        # Build a `reactive:js` turbo-stream carrying server-pushed client DOM
        # ops (issue #97). `ops` is a Phlex::Reactive::JS chain or a raw
        # [[op, args], ...] array; `target` (an element id or nil) scopes op
        # resolution on the client (nil → document-scoped). The ops JSON is
        # HTML-escaped into the attribute exactly like to_stream_token — a raw
        # interpolation would be an injection vector. The client's registered
        # reactive:js handler runs the ops through the SAME whitelist interpreter
        # as on_client (default-deny), so an unknown op is warn-and-skipped there.
        def js_stream(ops, target: nil)
          json = js_ops_json(ops)
          target_attr = target ? %( target="#{ERB::Util.html_escape(target)}") : ""
          # Issue #237: carry the verbose gate on the stream element itself, so
          # the client can warn on zero-target resolution even for a
          # document-scoped op with no controller root to read the flag from.
          verbose_attr = Phlex::Reactive.verbose_errors ? %( data-reactive-verbose="true") : ""
          %(<turbo-stream action="reactive:js"#{target_attr}#{verbose_attr} \
data-reactive-ops="#{ERB::Util.html_escape(json)}"></turbo-stream>).html_safe
        end

        # Normalize `ops` to its JSON wire form, rejecting an empty chain — a
        # reactive:js stream with no ops is a dead stream (a mistake at the call
        # site), so fail loudly rather than emit an inert tag.
        def js_ops_json(ops)
          if ops.is_a?(Phlex::Reactive::JS)
            raise ArgumentError, "js(...) got no ops — a dead reactive:js stream" if ops.empty?

            ops.to_json
          else
            list = Array(ops)
            raise ArgumentError, "js(...) got no ops — a dead reactive:js stream" if list.empty?

            # The builder validates attr names at build time; a raw [op, args]
            # list skips that, so re-apply the allowlist here (defense in depth —
            # the client interpreter also refuses on*/URL/style attrs).
            Phlex::Reactive::JS.assert_ops_allowed!(list)
            list.to_json
          end
        end

        # Resolve `content` to the HTML for a turbo-stream's `html:`. Two forms,
        # both SAFE against injection by default:
        #   * a Phlex component instance — rendered through the configured
        #     renderer, which auto-escapes interpolated values.
        #   * any other value — coerced with to_s and handed to Turbo's
        #     TagBuilder, which HTML-ESCAPES a plain String. So a model value
        #     (`html: @record.name`) cannot inject markup. To emit intentional
        #     raw HTML, pass an `html_safe` String (Turbo leaves those verbatim)
        #     or a Phlex component. Same contract as the pre-existing flash_stream.
        def render_html(content)
          content.is_a?(::Phlex::SGML) ? Phlex::Reactive.render(content) : content.to_s
        end
      end

      # render_self: when true (default for replace/update/with), the endpoint
      # GUARANTEES the component's own replace is present so its
      # data-reactive-token-value refreshes (the client extracts the next token
      # from the response HTML). remove/redirect set it false (nothing stays).
      #
      # token_component: set by .streams (issue #30) — a partial update that opts
      # OUT of the full-self replace but still needs the token refreshed. The
      # endpoint appends this component's tiny to_stream_token instead, so the
      # token rolls forward without re-rendering (and clobbering) the children.
      #
      # subject_component: the component a self-targeting builder (replace/morph/
      # update) re-renders (issue #97). Distinct from token_component so it does
      # NOT trip refresh_token? — it exists only to default #js's target to the
      # bound component's id, so reply.morph.js(js.focus("@root")) scopes to the
      # morphed root without the caller repeating the id.
      # No deferred segments — the shared default so the common (non-defer)
      # reply never allocates an empty array per Response.
      NO_SEGMENTS = [].freeze

      def initialize(streams: [], redirect_url: nil, render_self: true, token_component: nil,
                     subject_component: nil, deferred_segments: NO_SEGMENTS, pending_segments: NO_SEGMENTS)
        @streams = streams.freeze
        @redirect_url = redirect_url
        @render_self = render_self
        @token_component = token_component
        @subject_component = subject_component
        @deferred_segments = deferred_segments.freeze
        @pending_segments = pending_segments.freeze
        freeze
      end

      # The recorded reply.defer segments (issue #165), in call order. The
      # Response only RECORDS them; the endpoint (via the Defer module) builds
      # the placeholder + directive streams AFTER the action's transaction
      # committed and picks the delivery lane.
      attr_reader :deferred_segments

      def deferred? = !@deferred_segments.empty?

      # The recorded reply.pending segments (issue #248), in call order. Same
      # contract as deferred_segments: recorded here, turned into wire streams
      # by the endpoint AFTER the transaction committed.
      attr_reader :pending_segments

      def pending? = !@pending_segments.empty?

      # Append extra turbo-stream strings (a sibling component, a flash).
      # Returns a NEW Response (immutable).
      def stream(*more)
        self.class.new(
          streams: @streams + more.flatten,
          redirect_url: @redirect_url,
          render_self: @render_self,
          token_component: @token_component,
          subject_component: @subject_component,
          deferred_segments: @deferred_segments,
          pending_segments: @pending_segments
        )
      end

      # Record a DEFERRED segment (issue #165): `component`'s render is taken
      # off the actor's critical path — the reply carries a pending marker (or
      # `placeholder:`) plus a delivery directive, and the real HTML reaches
      # the SAME actor when the render completes (pull fetch or pgbus push,
      # picked at the endpoint). `morph: true` makes the arrival morph in place.
      # Returns a NEW Response (immutable). Chain it like any other verb:
      #
      #   reply.streams(volume_cell_stream).defer(SessionTotals.new(workout:))
      #
      # Dead constructs fail HERE, loudly: defer on a redirect (the client is
      # navigating away), a non-reactive component (its identity could never be
      # rebuilt at render time), a bogus placeholder type.
      def defer(component, placeholder: nil, morph: false)
        if redirect?
          raise Phlex::Reactive::Error,
            "reply.defer on a redirect reply is dead — the client is navigating away, " \
            "so the deferred render could never land"
        end
        Phlex::Reactive::Defer.validate_segment!(component, placeholder)

        self.class.new(
          streams: @streams,
          redirect_url: @redirect_url,
          render_self: @render_self,
          token_component: @token_component,
          subject_component: @subject_component,
          deferred_segments: @deferred_segments +
            [Phlex::Reactive::Defer::Segment.new(component:, placeholder:, morph:)],
          pending_segments: @pending_segments
        )
      end

      # Chain reply.pending onto an existing reply (issue #248), so an action can
      # do one synchronous thing AND mark other targets pending:
      #
      #   reply.replace.pending(rows, in: :declined, job: RestoreJob)
      #
      # Dead on a redirect, exactly like #defer: the client is navigating away,
      # so the settle could never land.
      def pending(records, peers: false, job: nil, args: nil, **opts, &enqueue)
        if redirect?
          raise Phlex::Reactive::Error,
            "reply.pending on a redirect reply is dead — the client is navigating away, " \
            "so the settle could never land"
        end

        subject = pending_subject!
        # ONE subscription per anchor. Every pending segment on the same
        # container emits a directive targeting that container's id, and the
        # client keys its in-flight subscriptions BY TARGET — so a second
        # directive supersedes the first, silently orphaning the jobs the first
        # call enqueued. Two pending calls on one container in one reply is a
        # call-site mistake; make it a loud one.
        if @pending_segments.any? { it.handle.anchor == subject.id }
          raise Phlex::Reactive::Error,
            "reply.pending was called twice for #{subject.class} (##{subject.id}) — the second " \
            "subscription would supersede the first on the client, so the first call's jobs could " \
            "never settle. Mark every target in ONE reply.pending call (the settle names its own " \
            "collection: s.remove(record, from: :name))."
        end

        built = self.class.build_pending(
          subject, records, collection: self.class.pending_collection!(opts),
          peers:, job:, args:, enqueue:
        )
        self.class.new(
          streams: @streams,
          redirect_url: @redirect_url,
          render_self: @render_self,
          token_component: @token_component || built.token_component,
          subject_component: @subject_component,
          deferred_segments: @deferred_segments,
          pending_segments: @pending_segments + built.pending_segments
        )
      end

      # Chain a `reactive:js` op stream — server-pushed client DOM ops (issue
      # #97) — onto this reply, so a focus/dispatch/class toggle runs on the
      # client after the render applies:
      #
      #   reply.morph.js(js.focus("[name=next]").dispatch("app:saved"))
      #
      # `ops` is a Phlex::Reactive::JS chain (or a raw [[op, args], ...] array).
      # `target` (an element id) scopes op resolution on the client; it defaults
      # to the bound component's id (subject_component/token_component) so
      # self-scoped ops (@root, a component-relative selector) just work, and is
      # nil (document-scoped) for a subject-free reply.with. Returns a NEW
      # Response (immutable) — the op stream rides the same stream() plumbing, so
      # the endpoint emits it LAST (after all render streams) and a focus op sees
      # the post-render DOM.
      def js(ops, target: :__default)
        resolved = target == :__default ? default_js_target : target
        stream(self.class.js_stream(ops, target: resolved))
      end

      # Append a flash turbo-stream into a host-app container (default
      # <div id="flash">, configurable via Phlex::Reactive.flash_target).
      # `dismiss_after:` (ms) makes the flash self-remove after the timeout — a
      # document-level client handler removes any [data-reactive-dismiss-after]
      # container, so it works for reply AND broadcast flashes (issue #100). It
      # wraps only STRING content; a verbatim Phlex component owns its lifecycle.
      def flash(level, content, target: Phlex::Reactive.flash_target, dismiss_after: nil)
        stream(self.class.send(:flash_stream, level, content, target:, dismiss_after:))
      end

      # Also re-render COMPANION elements alongside self (issue #182 — one door,
      # replacing also_update + also_replace). The ARGUMENT TYPE picks the Turbo
      # action; there is no verb to choose:
      #
      #   .also(SummaryCard.new(order: @order))          -> REPLACE at the component's own #id
      #   .also(SummaryCard.new(order: @order), morph:)  -> the same, MORPHED in place
      #   .also(page_heading: @record.name)              -> UPDATE (inner HTML) of id "page_heading"
      #   .also("nav-badge" => @record.name)             -> UPDATE of id "nav-badge" (dashed id)
      #
      # So the two shapes are:
      #
      #   * a Streamable COMPONENT (positional) — a `replace` targeting its OWN #id
      #     (it self-targets, like every reactive component). `morph: true` morphs
      #     it in place (issue #28) when it holds focusable inputs to preserve.
      #   * target => content pairs — an `update` (inner HTML) of each id. The id
      #     need NOT be a reactive component (it's any element), so the only sound
      #     swap is its inner HTML. Content is a plain String (HTML-ESCAPED by
      #     Turbo, so a model value is safe), a Phlex component (rendered +
      #     auto-escaped), or an html_safe String for intentional raw HTML. Written
      #     brace-less as keywords or as an explicit Hash.
      #
      # This is NOT for collection rows — a row add/remove goes through
      # reply.append(model, to: :name) / reply.remove(id, from: :name), which also
      # emit the count + empty-state streams. `.also` only re-renders EXISTING
      # companion elements.
      #
      # Returns a NEW Response (immutable). `companion` is EITHER a positional
      # component OR target=>content pairs — never both (that raises). The
      # brace-less keyword form lands in **targets; an explicit Hash lands in
      # `companion`. `morph:` is reserved for the component form.
      def also(companion = :__none, morph: false, **targets)
        if companion != :__none && !targets.empty?
          raise ArgumentError, "reply.also takes EITHER a component OR target => content pairs, not both"
        end

        case companion
        when :__none
          also_targets(targets)
        when ::Phlex::SGML
          stream(companion.to_stream_replace(morph:))
        when Hash
          also_targets(companion)
        else
          raise ArgumentError,
            "reply.also expects target => content pairs or a Streamable component, got #{companion.class}"
        end
      end

      # Issue #182: also_update / also_replace collapsed into #also. Guided errors
      # naming the rewrite (the html: kwarg lied — it accepted components too).
      def also_update(target, **)
        raise ArgumentError,
          "also_update was removed in issue #182 — use also(#{target.inspect} => content)"
      end

      def also_replace(*, **)
        raise ArgumentError,
          "also_replace was removed in issue #182 — use also(component, morph: …)"
      end

      def redirect? = !@redirect_url.nil?
      def render_self? = @render_self

      # True when a partial update (.streams) opted out of the full-self replace
      # but still needs the token rolled forward — the endpoint appends the bound
      # component's tiny token-only stream (issue #30).
      def refresh_token? = !@token_component.nil?

      private

      # The container a chained .pending marks: the component this reply is
      # already bound to. A subject-free reply (reply.with) has none — chaining
      # .pending onto it is a call-site mistake, so it fails loudly.
      def pending_subject!
        (@subject_component || @token_component) ||
          raise(Phlex::Reactive::Error,
            "reply.pending needs a bound component (the container that owns the collection) — " \
            "chain it off a component verb (reply.replace.pending(...)) or call reply.pending(...) directly")
      end

      # The default `target` for #js: the bound component's id when this reply is
      # component-scoped (replace/morph/update set subject_component; .streams and
      # collections set token_component), else nil — a subject-free reply.with is
      # document-scoped unless the caller passes target: explicitly.
      def default_js_target
        (@subject_component || @token_component)&.id
      end

      # Build one update stream per { target_id => content } pair (issue #182). An
      # empty call is a dead reply.also — fail loudly rather than return unchanged.
      def also_targets(targets)
        raise ArgumentError, "reply.also needs target => content pairs (or a component) — got nothing" if targets.empty?

        stream(*targets.map { |target, content| self.class.update_stream(target, content) })
      end
    end
  end
end
