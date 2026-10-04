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
      # defer token) and a `__materialize` trigger bound `once` to the event —
      # or to `reactive:visible`, which the client fires from an
      # IntersectionObserver. The action endpoint routes `__materialize` to the
      # same real render the defer endpoint does. The real render never
      # contains the shell or its trigger, so `once` cannot re-arm.
      module Lazy
        extend ActiveSupport::Concern

        # The framework-owned act the on: shell dispatches. Reserved: `action`
        # refuses it, and the endpoint answers it only for reactive_lazy(on:).
        MATERIALIZE_ACTION = :__materialize
        # The event the client's IntersectionObserver fires on a visible shell.
        VISIBLE_EVENT = "reactive:visible"
        # A DOM event name usable in a Stimulus descriptor: no key filter (.),
        # no target (@), no descriptor syntax (->, #) — `panel:opened` is fine.
        EVENT_NAME = /\A[A-Za-z][\w:-]*\z/
        # An IntersectionObserver rootMargin: one to four px/% lengths.
        ROOT_MARGIN = /\A-?\d+(?:\.\d+)?(?:px|%)(?: -?\d+(?:\.\d+)?(?:px|%)){0,3}\z/

        # `on:` → { event: "x" } | { visible: "<rootMargin>" }, or raise.
        def self.normalize_trigger(on)
          case on
          when String
            return { event: on } if on.match?(EVENT_NAME)
          when :visible
            return { visible: "0px" }
          when ::Hash
            margin = on[:visible]
            return { visible: margin } if on.keys == [:visible] && margin.is_a?(String) && margin.match?(ROOT_MARGIN)
          end
          raise ArgumentError,
            "reactive_lazy on: expects a DOM event name (\"panel:opened\"), :visible, or " \
            "{ visible: \"200px\" } (a px/% rootMargin) — got #{on.inspect}"
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
        # like a reactive root — reactive_attrs' identity token — with the
        # `__materialize` trigger bound once. No defer token and no pending
        # marker: the client's lazy probe gates on the token, so it skips this
        # shell, and nothing is in flight until the trigger fires.
        def render_trigger_shell(trigger)
          event = trigger[:event] || VISIBLE_EVENT
          data = {
            action: "#{event}->reactive#dispatch:once",
            reactive_action_param: MATERIALIZE_ACTION.to_s,
            reactive_params_param: Helpers::EMPTY_PARAMS_JSON
          }
          data[:reactive_lazy_visible] = trigger[:visible] if trigger[:visible]

          public_send(
            self.class.reactive_lazy_tag,
            **mix({ id:, class: "reactive-defer-placeholder", aria: { busy: "true" } }, reactive_attrs, { data: })
          ) { render_deferred_placeholder_content }
        end

        # The shell: owns the component's id (the arrival replaces it by that
        # id), mounts the generic controller, and carries the defer token as a
        # ROOT attribute — the controller's connect() probes it and enters the
        # same module-level fetch path a reply directive uses. Pending markers
        # + the .reactive-defer-placeholder class are the CSS hooks.
        def render_defer_shell
          public_send(
            self.class.reactive_lazy_tag,
            id:,
            class: "reactive-defer-placeholder",
            aria: { busy: "true" },
            data: {
              controller: "reactive",
              reactive_defer_pending: "true",
              # UNBOUND (issue #165 security): a lazy shell renders during the
              # page render — on a fresh visit the session doesn't exist yet, so
              # the token can't be actor-bound (it would 400 at the endpoint,
              # which by then IS bound). It lives in the actor's own page (a
              # small leak surface); the TTL + `authorize!` are its bound. Only
              # reply.defer tokens (in action responses that can transit proxies)
              # are actor-bound.
              reactive_defer_token: Phlex::Reactive.sign_defer(reactive_identity_payload, unbound: true)
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
