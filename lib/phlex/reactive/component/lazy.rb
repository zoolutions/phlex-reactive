# frozen_string_literal: true

module Phlex
  module Reactive
    module Component
      # Lazy initial mount (issue #165): a `reactive_lazy` component's FIRST
      # (page-embedded) render emits a placeholder SHELL — the root id, the
      # generic controller, the pending markers, and a defer token ON the root
      # — and the client fetches the real content through the same defer
      # machinery on connect (the Livewire #[Lazy] shape).
      #
      # Lazy applies ONLY to the initial mount. Every render that goes through
      # the reactive machinery — an action reply's self-replace, a broadcast,
      # the defer endpoint/job, the class stream builders — runs inside
      # Defer.with_real_render, so it renders the REAL template. Anything else
      # would make an action on a lazy component cost two round trips.
      #
      # `reactive_lazy(on:)` (issue #276) defers the REQUEST, not just the
      # server time: the shell carries the identity token (no TTL, unlike the
      # defer token). An event shell binds a `__materialize` trigger `once` to
      # its event; a visibility shell has no binding — the client's
      # IntersectionObserver starts the same `__materialize` request itself.
      # The action endpoint routes `__materialize` to the same real render the
      # defer endpoint does. The real render never contains the shell or its
      # trigger, so `once` cannot re-arm.
      module Lazy
        extend ActiveSupport::Concern

        # The framework-owned act the on: shell dispatches. Reserved: `action`
        # refuses it, and the endpoint answers it only for reactive_lazy(on:).
        MATERIALIZE_ACTION = :__materialize
        # A DOM event name usable in a Stimulus descriptor: no key filter (.),
        # no target (@), no descriptor syntax (->, #) — `panel:opened` is fine.
        EVENT_NAME = /\A[A-Za-z][\w:-]*\z/
        # An IntersectionObserver rootMargin: one to four px/% lengths.
        # Any CSS whitespace between lengths; normalized to single spaces.
        ROOT_MARGIN = /\A\s*-?\d+(?:\.\d+)?(?:px|%)(?:\s+-?\d+(?:\.\d+)?(?:px|%)){0,3}\s*\z/

        # `on:` → { event: "x" } | { visible: "<rootMargin>" }, or raise.
        def self.normalize_trigger(on)
          case on
          when String
            return { event: on } if on.match?(EVENT_NAME)
          when :visible
            return { visible: "0px" }
          when ::Hash
            margin = on[:visible]
            if on.keys == [:visible] && margin.is_a?(String) && margin.match?(ROOT_MARGIN)
              return { visible: margin.split.join(" ") }
            end
          end
          raise ArgumentError,
            "reactive_lazy on: expects a DOM event name (\"panel:opened\"), :visible, or " \
            "{ visible: \"200px\" } (a px/% rootMargin) — got #{on.inspect}"
        end

        # `cache:` → { max_age: <seconds> }, or raise. Only a whole, positive
        # number of seconds (an Integer or an ActiveSupport::Duration) is a
        # lifetime; the endpoint caps it at fragment_cache_max_age_limit.
        def self.normalize_cache(cache)
          unless cache.is_a?(::Hash) && cache.keys == [:max_age]
            raise ArgumentError,
              "reactive_lazy cache: expects { max_age: <seconds> } (e.g. { max_age: 10.minutes }) — got #{cache.inspect}"
          end

          max_age = cache[:max_age]
          seconds = max_age.is_a?(ActiveSupport::Duration) ? max_age.to_i : max_age
          unless seconds.is_a?(::Integer) && seconds.positive?
            raise ArgumentError,
              "reactive_lazy cache: max_age must be a positive whole number of seconds — got #{max_age.inspect}"
          end

          { max_age: seconds }
        end

        private

        # Phlex 2's render hook: the template runs inside the block. Overridden
        # (not yield-then-decorate) so the lazy shell can REPLACE the template
        # entirely on the initial mount. A component's own around_template
        # override composes via normal method lookup as long as it calls super.
        def around_template(&)
          klass = self.class
          if klass.respond_to?(:reactive_lazy?) && klass.reactive_lazy? && !Phlex::Reactive::Defer.real_render?
            (trigger = klass.reactive_lazy_trigger) ? render_trigger_shell(trigger) : render_defer_shell
          else
            super
          end
        end

        # The on: shell (issue #276): the same placeholder contract as the
        # defer shell (id, class, aria-busy, deferred_placeholder), but mounted
        # like a reactive root — reactive_attrs' identity token. No defer token
        # and no pending marker: the client's lazy probe gates on the token, so
        # it skips this shell, and nothing is in flight until the trigger fires.
        #
        # The marker tells the client which shell this is, on connect AND after
        # a Turbo morph re-shows it on a connected root (no Stimulus lifecycle):
        #   * data-reactive-lazy-on="<event>" — plus the once-bound Stimulus
        #     descriptor for `__materialize`, so the first event takes the
        #     ordinary action path. The client re-arms the event itself after a
        #     morph, because a spent `once` binding never fires again.
        #   * data-reactive-lazy-visible="<rootMargin>" — no descriptor at all;
        #     the client's IntersectionObserver materializes directly.
        #
        # A `cache:` component (issue #277) adds its fragment URL: the client
        # then loads with a cacheable GET instead of the __materialize POST.
        def render_trigger_shell(trigger)
          attrs = mix(
            { id:, class: "reactive-defer-placeholder", aria: { busy: "true" } },
            reactive_attrs,
            { data: trigger_shell_data(trigger) }
          )
          # Mixed in only when present: a non-cached shell allocates nothing extra.
          src = fragment_src
          attrs = mix(attrs, { data: { reactive_defer_src: src } }) if src
          public_send(self.class.reactive_lazy_tag, **attrs) { render_deferred_placeholder_content }
        end

        # The cacheable fragment URL (issue #277) for a `cache:` component, else
        # nil (Phlex omits a nil attribute, so a non-cached shell is unchanged).
        # Deterministic: the same identity (+ version) renders the same URL on
        # every page view, which is what lets the browser's HTTP cache hit.
        def fragment_src
          return unless self.class.reactive_lazy_cache

          version = respond_to?(:reactive_cache_version, true) ? send(:reactive_cache_version) : nil
          Phlex::Reactive::Fragment.src(reactive_identity_payload, version:, viewer: fragment_viewer_param)
        end

        # The `u` of the fragment URL: the digest of reactive_cache_viewer when
        # the component declares who its render is for, else nil. The shell
        # renders it; the endpoint recomputes it in the requesting session and
        # compares (see FragmentsController).
        def fragment_viewer_param
          return unless respond_to?(:reactive_cache_viewer, true)

          Phlex::Reactive::Fragment.viewer_param(send(:reactive_cache_viewer))
        end

        def trigger_shell_data(trigger)
          return { reactive_lazy_visible: trigger[:visible] } if trigger[:visible]

          event = trigger[:event]
          {
            action: "#{event}->reactive#dispatch:once",
            reactive_action_param: MATERIALIZE_ACTION.to_s,
            reactive_params_param: Helpers::EMPTY_PARAMS_JSON,
            reactive_lazy_on: event
          }
        end

        # The shell: owns the component's id (the arrival replaces it by that
        # id), mounts the generic controller, and carries the defer token as a
        # ROOT attribute — the controller's connect() probes it and enters the
        # same module-level fetch path a reply directive uses. Pending markers
        # + the .reactive-defer-placeholder class are the CSS hooks.
        #
        # A `cache:` component (issue #277) carries its stable fragment URL in
        # data-reactive-defer-src INSTEAD of the token: the client GETs it, and
        # the browser's private cache can answer.
        def render_defer_shell
          src = fragment_src
          public_send(
            self.class.reactive_lazy_tag,
            id:,
            class: "reactive-defer-placeholder",
            aria: { busy: "true" },
            data: {
              controller: "reactive",
              reactive_defer_pending: "true",
              # The same verbose stamp reactive_attrs writes (nil is omitted):
              # the shell may be the page's only reactive root when its mount
              # fetch runs, and the client's verbose gate reads it (issue #279).
              reactive_verbose: (Phlex::Reactive.verbose_errors ? "true" : nil),
              # UNBOUND (issue #165 security): a lazy shell renders during the
              # page render — on a fresh visit the session doesn't exist yet, so
              # the token can't be actor-bound (it would 400 at the endpoint,
              # which by then IS bound). It lives in the actor's own page (a
              # small leak surface); the TTL + `authorize!` are its bound. Only
              # reply.defer tokens (in action responses that can transit proxies)
              # are actor-bound.
              reactive_defer_token: (Phlex::Reactive.sign_defer(reactive_identity_payload, unbound: true) unless src),
              reactive_defer_src: src
            }
          ) { render_deferred_placeholder_content }
        end

        # Same content contract as reply.defer's placeholder: true — the
        # component's deferred_placeholder returns a Phlex component instance
        # (rendered), an html_safe String (raw), or a plain String (escaped
        # text — data, not markup). No method / nil → the empty shell.
        def render_deferred_placeholder_content
          return unless respond_to?(:deferred_placeholder, true)

          value = send(:deferred_placeholder)
          case value
          when nil then nil
          when ::Phlex::SGML then render(value)
          else
            value.html_safe? ? raw(value) : plain(value.to_s)
          end
        end
      end
    end
  end
end
