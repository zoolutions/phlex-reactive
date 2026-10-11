# frozen_string_literal: true

module Phlex
  module Reactive
    # Deferred reply segments (issue #165): the machinery behind reply.defer —
    # "placeholder now, the real render to the ACTOR when ready".
    #
    # A Response only RECORDS segments (see Response#defer); this module turns
    # them into wire streams at the ENDPOINT, after the action's transaction
    # committed — so a rolled-back action can never leak a directive — and picks
    # the delivery lane:
    #
    #   * pull (:fetch)  — the directive carries a purpose-scoped, short-TTL
    #     defer token; the client POSTs it to the defer endpoint OFF the action
    #     queue and applies the rendered stream when it lands. Works on every
    #     transport (it's just HTTP) — this is the universal lane.
    #   * push (:stream) — pgbus durable one-shot stream + ActiveJob: the reply
    #     carries a signed SSE src; a job renders and broadcasts durably, and
    #     the since-id=0 replay closes the broadcast-before-subscribe race.
    #     Capability-gated (Phlex::Reactive.defer_push_capable?); anything
    #     missing degrades to pull.
    module Defer
      # One recorded deferred segment. `component` is the built (but not yet
      # rendered) reactive component; `placeholder` is nil (keep current
      # content, mark pending), true (the component's deferred_placeholder /
      # the built-in shell), a String, or a Phlex component; `morph` makes the
      # ARRIVAL morph instead of replace (issue #28 semantics).
      Segment = Data.define(:component, :placeholder, :morph)

      # The custom turbo-stream action the client's defer handler registers.
      DIRECTIVE_ACTION = "reactive:defer"

      # The stable marker every one-shot push-lane stream key starts with — how
      # pgbus's orphan sweep and an operator recognize a phlex-reactive defer
      # queue (issue #165).
      DEFER_KEY_MARKER = "prdefer_"
      # Minimum random hex chars on the key (64 bits) — collision-safe.
      DEFER_KEY_MIN_SUFFIX = 16
      # pgbus's MAX_QUEUE_NAME_LENGTH (its QueueNameValidator); the live
      # queue_prefix is subtracted from it to get the usable budget.
      PGBUS_MAX_QUEUE_NAME = 47
      # pgbus's default queue_prefix, used when the live one can't be read.
      DEFAULT_PGBUS_QUEUE_PREFIX = "pgbus"

      # Thread/fiber-local flag marking a REAL reactive-machinery render —
      # inside it a reactive_lazy component renders its actual template instead
      # of the placeholder shell. Set by Streamable.render_component (replies,
      # broadcasts, the defer endpoint/job, the class stream builders) and
      # Phlex::Reactive.render; a page-embedded initial mount never passes
      # through either, so it gets the shell.
      REAL_RENDER_KEY = :phlex_reactive_defer_real_render

      class << self
        def real_render?
          Thread.current[REAL_RENDER_KEY] ? true : false
        end

        def with_real_render
          previous = Thread.current[REAL_RENDER_KEY]
          Thread.current[REAL_RENDER_KEY] = true
          yield
        ensure
          Thread.current[REAL_RENDER_KEY] = previous
        end

        # Which lane deferred segments take, resolved PER REPLY (capability is
        # probed live — cheap: without pgbus it's one defined? short-circuit).
        # :fetch forces pull; :stream requests push and DEGRADES to pull with a
        # one-time warning when the capability is absent (never break); :auto
        # picks push iff fully capable.
        def resolve_via
          case Phlex::Reactive.defer_transport
          when :fetch then :fetch
          when :stream
            return :stream if Phlex::Reactive.defer_push_capable?

            warn_stream_degraded
            :fetch
          else
            Phlex::Reactive.defer_push_capable? ? :stream : :fetch
          end
        end

        # The wire streams for ONE segment on the given lane, in apply order:
        # the optional placeholder shell FIRST (so the pending state paints
        # before the directive kicks off delivery), then the directive.
        def streams_for(segment, via: resolve_via)
          streams = []
          shell = placeholder_stream(segment)
          streams << shell if shell
          streams << directive_stream(segment, via)
          streams
        end

        # Validate reply.defer arguments LOUDLY at the call site — a dead
        # segment (a component the endpoint could never rebuild, a bogus
        # placeholder) must fail in the action that wrote it, not silently at
        # reply render or, worse, at fetch time.
        def validate_segment!(component, placeholder)
          unless component.class.include?(Phlex::Reactive::Component)
            raise ::ArgumentError,
              "reply.defer expects a Phlex::Reactive::Component instance (its identity is what the " \
              "deferred render is rebuilt from) — got #{component.class}"
          end

          return if placeholder.nil? || placeholder == true ||
                    placeholder.is_a?(::String) || placeholder.is_a?(::Phlex::SGML)

          raise ::ArgumentError,
            "reply.defer placeholder: must be nil (keep current content), true (the component's " \
            "deferred_placeholder or the built-in shell), a String, or a Phlex component — " \
            "got #{placeholder.class}"
        end

        # The signed SSE URL a <pgbus-stream-source> subscribes to `key` with —
        # minted off-view, as pgbus_stream_from would. Shared with presence
        # (issue #358), whose roster subscribes to its stream the same way.
        def stream_src(key) = signed_stream_src(key)

        private

        # The delivery directive: `<turbo-stream action="reactive:defer">`
        # targeting the deferred component's own #id. The pull form carries the
        # purpose-scoped, short-TTL defer token; morph mode rides INSIDE the
        # signed payload so the client can't flip it. Wrapped in a Stream so the
        # endpoint's token guards read it structurally (it never carries
        # data-reactive-token-value, so it can never count as a token refresh).
        def directive_stream(segment, via)
          target = segment.component.id
          html = %(<turbo-stream action="#{DIRECTIVE_ACTION}" \
target="#{ERB::Util.html_escape(target)}"#{directive_attrs(segment, via)}></turbo-stream>)
          Phlex::Reactive::Stream.wrap(
            html.html_safe, action: DIRECTIVE_ACTION, target: target, renders_root: false
          )
        end

        def directive_attrs(segment, via)
          case via
          when :stream then push_directive_attrs(segment)
          else fetch_directive_attrs(segment)
          end
        end

        def fetch_directive_attrs(segment)
          token = mint_token(segment)
          %( data-reactive-defer-via="fetch" data-reactive-defer-token="#{ERB::Util.html_escape(token)}")
        end

        # The push lane's directive: mint a one-shot stream key, sign its SSE
        # src (server-side — no view context needed), enqueue the render job,
        # and hand the client the subscription coordinates. since-id="0" on a
        # FRESH key replays the job's durable broadcast even when it beats the
        # client's subscription (the rails#52420-class race, closed by pgbus's
        # connect-time read_after).
        #
        # Degrade, never break: this runs AFTER the action committed, so a
        # signing/enqueue failure must not 500 a reply whose mutation already
        # persisted — warn and fall back to the fetch directive instead (the
        # pull lane needs nothing but our own endpoint).
        def push_directive_attrs(segment)
          key = one_shot_stream_key
          src = signed_stream_src(key)
          enqueue_push_render(segment, key)
          # A fallback defer token rides ALONGSIDE the stream src: the server
          # picks push on SERVER-side capability alone, but the browser may not
          # have the pgbus client loaded (no <pgbus-stream-source>). Rather than
          # dead-end the shimmer, the client degrades to the fetch lane with this
          # token. It's the same purpose-scoped, actor-bound, short-TTL token the
          # fetch lane uses — redeeming it at the defer endpoint is identical.
          token = mint_token(segment)
          %( data-reactive-defer-via="stream" data-reactive-defer-src="#{ERB::Util.html_escape(src)}" \
data-reactive-defer-since-id="0" data-reactive-defer-token="#{ERB::Util.html_escape(token)}")
        rescue ::StandardError => e
          warn_push_failed(e)
          fetch_directive_attrs(segment)
        end

        # A one-shot key that FITS pgbus's live queue-name budget. pgbus computes
        # 47 − queue_prefix.length − 1 (default prefix "pgbus" → 41); a longer
        # app-configured prefix shrinks it, and a FIXED-width key would raise
        # StreamNameTooLong in the JOB — after the directive already shipped, so
        # the shimmer would hang forever. We size the random suffix to the live
        # budget instead. The stable DEFER_KEY_MARKER is kept (it's how the
        # orphan sweep / an operator recognizes these), and the suffix is hex
        # ([a-f0-9] — never hyphens: pgbus's sanitizer STRIPS them, colliding two
        # keys that differ only by hyphen).
        #
        # When the prefix is so long the COLLISION-SAFE minimum can't fit the
        # budget (budget < marker + min-suffix), we RAISE rather than clamp to a
        # too-long key: push_directive_attrs' rescue then degrades to :fetch
        # (a working lane) instead of enqueuing a doomed push that raises
        # StreamNameTooLong in the job once the directive is already on the wire.
        #
        # The budget is pgbus's OWN formula (Key.queue_name_budget), not a
        # hardcoded 47 − prefix − 1 — the single source of truth, so a future
        # change to MAX_QUEUE_NAME_LENGTH or the prefix is tracked automatically.
        # The minted key is finally gated through Pgbus.stream_key! (which does
        # NOT shrink — pgbus only auto-fits AR records, not random strings — it
        # returns the key unchanged when it fits and raises loudly otherwise), so
        # a sizing mistake degrades to :fetch here instead of surfacing later.
        def one_shot_stream_key
          budget = pgbus_queue_name_budget
          suffix_chars = budget - DEFER_KEY_MARKER.length
          if suffix_chars < DEFER_KEY_MIN_SUFFIX
            raise Phlex::Reactive::Error,
              "pgbus queue_prefix is too long (budget #{budget}) for a collision-safe defer key — " \
              "deferring via :fetch instead"
          end

          # SecureRandom.hex(n) yields 2n chars; halve (ceil) then trim to fit.
          key = "#{DEFER_KEY_MARKER}#{SecureRandom.hex((suffix_chars / 2.0).ceil)[0, suffix_chars]}"
          # Validate against pgbus itself (raises if our sizing is ever wrong).
          ::Pgbus.respond_to?(:stream_key!) ? ::Pgbus.stream_key!(key) : key
        end

        # pgbus's live queue-name budget: prefer its own formula (single source
        # of truth), fall back to computing it from the prefix, then to the
        # documented default — each guarded so an older pgbus without the newer
        # API still degrades cleanly rather than raising.
        def pgbus_queue_name_budget
          return ::Pgbus::Streams::Key.queue_name_budget if pgbus_key_budget_available?

          PGBUS_MAX_QUEUE_NAME - pgbus_queue_prefix_length - 1
        rescue ::StandardError
          PGBUS_MAX_QUEUE_NAME - DEFAULT_PGBUS_QUEUE_PREFIX.length - 1
        end

        def pgbus_key_budget_available?
          defined?(::Pgbus::Streams::Key) &&
            ::Pgbus::Streams::Key.respond_to?(:queue_name_budget)
        end

        # The live queue-name prefix length pgbus budgets against (default
        # "pgbus" → 5). Read defensively — an old pgbus without the accessor
        # falls back to the documented default.
        def pgbus_queue_prefix_length
          if ::Pgbus.respond_to?(:configuration) &&
             ::Pgbus.configuration.respond_to?(:queue_prefix) &&
             (prefix = ::Pgbus.configuration.queue_prefix)
            return prefix.to_s.length
          end

          DEFAULT_PGBUS_QUEUE_PREFIX.length
        rescue ::StandardError
          DEFAULT_PGBUS_QUEUE_PREFIX.length
        end

        # Replicates pgbus_stream_from's src minting off-view: the signed name
        # rides the URL path; the base is the configured streams_path, the
        # engine's mounted helper, or pgbus's documented default mount.
        def signed_stream_src(key)
          signed = ::Pgbus::Streams::SignedName.sign(key)
          "#{pgbus_streams_base_path.delete_suffix("/")}/#{signed}"
        end

        def pgbus_streams_base_path
          if ::Pgbus.respond_to?(:configuration) && (configured = ::Pgbus.configuration.streams_path)
            return configured
          end

          ::Pgbus::Engine.routes.url_helpers.streams_path
        rescue ::NameError
          "/pgbus/streams"
        end

        def enqueue_push_render(segment, key)
          component = segment.component
          Phlex::Reactive::DeferredRenderJob.perform_later(
            component.class.name,
            component.send(:reactive_identity_payload),
            key,
            component.id,
            segment.morph
          )
        end

        def warn_push_failed(error)
          return unless defined?(::Rails) && ::Rails.respond_to?(:logger) && ::Rails.logger

          ::Rails.logger.warn(
            "[phlex-reactive] defer push lane failed (#{error.class}: #{error.message}) — " \
            "falling back to the fetch directive for this segment."
          )
        end

        # Sign the component's identity (the SAME payload shape as the action
        # token — reactive_identity_payload, so the families can't drift) under
        # the defer purpose + TTL. Private on the component; reached via send
        # exactly like the identity internals are elsewhere off-instance.
        def mint_token(segment)
          payload = segment.component.send(:reactive_identity_payload)
          payload = payload.merge("m" => "morph") if segment.morph
          Phlex::Reactive.sign_defer(payload)
        end

        # The pending shell: replaces the target with a div that OWNS the
        # component's id (so any placeholder content works — the shell is the
        # stream target) and carries the pending markers the client/CSS hook
        # onto. nil when the segment keeps current content (the client's
        # directive handler marks the live element instead). Deliberately NO
        # defer token on the shell — the directive owns delivery; a token attr
        # here would double-fetch via the lazy-mount connect probe.
        def placeholder_stream(segment)
          inner = placeholder_inner_html(segment)
          return nil if inner.nil?

          target = segment.component.id
          shell = %(<div id="#{ERB::Util.html_escape(target)}" class="reactive-defer-placeholder" \
data-reactive-defer-pending="true" aria-busy="true">#{inner}</div>)
          Phlex::Reactive::Stream.wrap(
            Phlex::Reactive.stream_builder.replace(target, html: shell.html_safe),
            action: "replace", target: target, renders_root: true
          )
        end

        # Resolve the segment's placeholder to inner HTML — nil means "no
        # shell". Same content contract as flash/also: a Phlex component
        # renders through the configured renderer (auto-escaped), a plain
        # String is DATA and gets escaped, an html_safe String is intentional
        # markup and passes verbatim (ERB::Util.html_escape's own contract).
        def placeholder_inner_html(segment)
          value = resolved_placeholder(segment)
          return nil if value == :none

          case value
          when ::Phlex::SGML then Phlex::Reactive.render(value)
          else ERB::Util.html_escape(value.to_s)
          end
        end

        # `true` asks the COMPONENT: deferred_placeholder (private ok) when
        # defined, else the built-in empty shell (the pending markers + the
        # .reactive-defer-placeholder class are the whole skeleton). nil from
        # the method degrades to the empty shell too — the caller explicitly
        # asked for a placeholder.
        def resolved_placeholder(segment)
          case segment.placeholder
          when nil then :none
          when true
            component = segment.component
            if component.respond_to?(:deferred_placeholder, true)
              component.send(:deferred_placeholder) || "".html_safe
            else
              "".html_safe
            end
          else
            segment.placeholder
          end
        end

        # A forced :stream without the capability is a CONFIG mistake — warn
        # loudly but once per process (a deferred reply can fire per keystroke;
        # per-reply spam would bury the signal), then degrade to :fetch.
        def warn_stream_degraded
          return if @stream_degraded_warned

          @stream_degraded_warned = true
          return unless defined?(::Rails) && ::Rails.respond_to?(:logger) && ::Rails.logger

          ::Rails.logger.warn(
            "[phlex-reactive] defer_transport is :stream but the push lane is unavailable " \
            "(needs pgbus reactive Streams + SignedName + ActiveJob) — deferring via :fetch instead."
          )
        end
      end
    end
  end
end
