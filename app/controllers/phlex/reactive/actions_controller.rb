# frozen_string_literal: true

module Phlex
  module Reactive
    # The single endpoint behind every reactive component. The generic
    # `reactive` Stimulus controller POSTs here with a signed identity token,
    # an action name, and params. We verify the token, rebuild the component
    # (re-finding the record from the DB for record-backed components), run the
    # whitelisted action, and return an auto-targeted Turbo Stream the client
    # morphs in.
    #
    # Customizing in your app:
    #   * Authentication — by default this inherits from
    #     Phlex::Reactive.base_controller (ActionController::Base). Set it to
    #     your ApplicationController to get current_user/Current/CSRF, but make
    #     sure the action path isn't force-redirected for logged-out users if
    #     you have public reactive components.
    #   * Authorization — DO IT IN THE COMPONENT ACTION. The token proves the
    #     identity is ours, not that this user may act. Raise from the action
    #     (e.g. authorize!), and configure Phlex::Reactive.authorization_errors
    #     so it's rendered as 403 here.
    class ActionsController < Phlex::Reactive.base_controller
      # Our JSON body uses keys that collide with Rails' reserved routing
      # params (action/controller) and would be wrapped by wrap_parameters.
      # Disable wrapping so the body lands flat; the action name travels as
      # `act` (not `action`, which is reserved and resolves to "create").
      wrap_parameters false if respond_to?(:wrap_parameters)

      def create
        # ONE action.phlex_reactive event per request (issue #107). The event
        # payload carries the component/action NAMES + outcome ONLY (never the
        # token, params, or state); we fill it as those become known and set
        # :outcome on every exit path — the success tail and each rescue. The
        # rescue bodies are unchanged (verbose diagnostics + reactive_error per
        # #82/#87); we only ADD the outcome finalizer. `action` is safe to read
        # up front (it comes from the request, not the verified token).
        event = { component: nil, action: reactive_action_name.to_s, outcome: nil }
        # Mint any reply.defer directive tokens UNDER the actor's binding (issue
        # #165 security), so the defer endpoint accepts them ONLY back from this
        # same actor. The defer token is built in response_streams (inside this
        # block via the Defer builder), so the binding must be established here.
        # Thread the ACTOR's url_options (protocol/host/port) into the reply
        # render (issue #232): the reply renders through the memoized
        # off-request view context, whose process-default url_options emit the
        # wrong host for absolute URL helpers on a multi-host app. Broadcasts
        # fired inside the action are exempted at their render (see
        # Streamable.broadcast_component) — subscribers can be on other hosts.
        Phlex::Reactive.with_url_options(Phlex::Reactive.url_options_for(request)) do
          Phlex::Reactive.with_defer_binding(Phlex::Reactive.defer_binding_for(request)) do
            Phlex::Reactive.instrument("action", event) do
              create_action(event)
            end
          end
        end
      end

      # The defer endpoint (issue #165) — the pull lane's render leg. Verifies
      # the purpose-scoped, short-TTL defer token (an ACTION token is rejected
      # here by signature — purpose confusion fails closed), rebuilds the
      # component from its signed identity, and returns its replace (or morph,
      # per the SIGNED mode) stream. No action runs and no transaction opens —
      # this is a read. Authorization: the base controller's auth applies as on
      # every reactive request; a component that guards visibility can raise a
      # registered authorization error from from_identity/render (→ 403) or
      # return false from render? (→ 204: keep content, clear pending).
      def deferred
        event = { component: nil, outcome: nil }
        # Verify UNDER the actor's binding (issue #165 security): a defer token
        # minted for another actor's session fails the binding-scoped purpose,
        # so a leaked token can't be exchanged here for this actor's render (and
        # its embedded fresh identity token). Unbound requests (no session) are
        # unchanged.
        # The defer PULL is an actor request too (issue #232) — its render gets
        # the same request-derived url_options as the action reply. The PUSH
        # lane (job → SSE) has no request and stays on process defaults.
        Phlex::Reactive.with_url_options(Phlex::Reactive.url_options_for(request)) do
          Phlex::Reactive.with_defer_binding(Phlex::Reactive.defer_binding_for(request)) do
            Phlex::Reactive.instrument("defer", event) do
              deferred_action(event)
            end
          end
        end
      end

      private

      # The defer body, mirroring create_action's shape: fill the event payload
      # on every exit path, reuse the shared rescue → reactive_error plumbing.
      def deferred_action(event)
        payload = verified_defer_payload
        component_class = resolve_component(payload["c"])
        event[:component] = component_class.name
        component = component_class.from_identity(payload)

        if component.respond_to?(:render?) && !component.render?
          event[:outcome] = :no_content
          return head :no_content
        end

        event[:outcome] = :ok
        stream = component.to_stream_replace(morph: payload["m"] == "morph")
        render turbo_stream: stream
      rescue Phlex::Reactive::InvalidToken => e
        event[:outcome] = :invalid_token
        reactive_error(:bad_request, e.message, kind: e.diagnostic || :tampered)
      rescue ActiveRecord::RecordNotFound
        event[:outcome] = :not_found
        reactive_error(:not_found, record_not_found_message(payload), kind: :not_found)
      rescue *authorization_errors => e
        event[:outcome] = :unauthorized
        reactive_error(:forbidden, deferred_authorization_message(e, component_class), kind: :forbidden)
      rescue => e # rubocop:disable Style/RescueStandardError
        # Issue #207, the defer (read) leg: a render that raises uncaught is
        # OBSERVED (tag + report + flash) then re-raised unchanged, mirroring the
        # action leg. The defer payload has no `action:` — report_error/the
        # adapters treat a nil action gracefully (transaction is the component).
        report_action_error(e, event)
        raise
      end

      def verified_defer_payload
        token = params.require(:token)
        Phlex::Reactive.verify_defer(token) || raise(Phlex::Reactive::InvalidToken.new(
          "defer token invalid — expired (defer_token_ttl is #{Phlex::Reactive.defer_token_ttl}s), " \
          "tampered, or an ACTION token posted to the defer endpoint (the purposes are disjoint)",
          diagnostic: :tampered
        ))
      end

      def deferred_authorization_message(error, component_class)
        "#{error.class.name} raised rebuilding/rendering #{component_class&.name} for a deferred " \
          "segment — the signature proves identity, not permission"
      end

      # The action body, run inside the instrument block so its payload (`event`)
      # can be finalized on every exit path. Kept separate so `create` stays a
      # thin instrument wrapper.
      def create_action(event)
        payload = verified_payload
        component_class = resolve_component(payload["c"])
        event[:component] = component_class.name
        action_def = component_class.reactive_actions[reactive_action_name.to_sym]

        # default-deny
        unless action_def
          event[:outcome] = :denied_undeclared
          return reactive_error(:forbidden, undeclared_action_message(component_class), kind: :forbidden)
        end

        component = component_class.from_identity(payload)
        coerced = coerce_params(action_def, component_class:, action_name: action_def.name)

        # verify_authorized (issue #168): instrument the class ONCE (idempotent,
        # per class object) so its authorization methods mark the tracking cell.
        # Only when the feature is on — zero cost otherwise.
        Phlex::Reactive::Authorization.instrument!(component_class) if Phlex::Reactive.verify_authorized

        result = run_action(component, action_def, coerced)

        event[:outcome] = :ok
        render turbo_stream: response_streams(result, component)
      rescue Phlex::Reactive::AuthorizationNotVerified
        # A developer error (a forgotten authorize!), NOT a client fault — it
        # bubbles as a 500 so error trackers fire, but we tag the event first so
        # the action.phlex_reactive outcome stays accurate, then re-raise.
        event[:outcome] = :unverified
        raise
      rescue Phlex::Reactive::InvalidToken => e
        # The component name here came from an UNVERIFIED token — do NOT report it
        # as trusted. Leave event[:component] nil.
        event[:outcome] = :invalid_token
        reactive_error(:bad_request, e.message, kind: e.diagnostic || :tampered)
      rescue ActiveRecord::RecordNotFound
        event[:outcome] = :not_found
        reactive_error(:not_found, record_not_found_message(payload), kind: :not_found)
      rescue *authorization_errors => e
        event[:outcome] = :unauthorized
        reactive_error(:forbidden, authorization_error_message(e, component_class, action_def), kind: :forbidden)
      rescue => e # rubocop:disable Style/RescueStandardError
        # Turnkey APM error reporting (issue #207). A previously-UNCAUGHT
        # action-body error — NOT one of the specific 4xx cases above (those still
        # win by ordering) — is OBSERVED here and then re-raised UNCHANGED, so
        # Rails' own error reporting and the app's middleware fire exactly as
        # today. The status never changes: this catch adds no new 4xx.
        #   1. tag the event outcome (fills the #107 nil-outcome gap),
        #   2. report to the APM adapter + on_action_error hooks WITH the name-only
        #      component/action context (each reporter isolated — see report_error),
        #   3. render the error_flash for the crash so the actor SEES a flash (500s
        #      now flow through the same error_flash path 4xx already used), THEN
        #   4. re-raise. The flash is built but MUST NOT swallow the raise.
        report_action_error(e, event)
        raise
      end

      # OBSERVE a previously-uncaught action-body error (issue #207) without
      # altering what propagates. Tag the outcome, fan the error out to the APM
      # adapter + on_action_error hooks (report_error isolates each reporter), and
      # render the error_flash for the crash. Every step is best-effort and MUST
      # NOT raise (the caller re-raises the ORIGINAL error immediately after): a
      # broken reporter is swallowed inside report_error; the flash render is
      # guarded here. The flash reuses the SAME 4xx machinery — error_flash_stream
      # degrades to nil on its own failure, and we render at :internal_server_error
      # so the body (if any) matches the 500 the re-raise ultimately yields.
      def report_action_error(error, event)
        event[:outcome] = :error
        Phlex::Reactive.report_error(error, event)

        flash = error_flash_stream(:error)
        render turbo_stream: flash, status: :internal_server_error if flash
      rescue => e # rubocop:disable Style/RescueStandardError
        # The observation path itself failed — log it, but NEVER let it replace the
        # action-body error the caller is about to re-raise.
        ::Rails.logger&.warn("[phlex-reactive] error observation failed: #{e.class}: #{e.message}") if
          defined?(::Rails) && ::Rails.respond_to?(:logger)
      end

      # Reply to an endpoint failure. The status NEVER changes with any flag —
      # only the body. Precedence for the body (issue #100):
      #   1. error_flash set → a turbo-stream flash the user actually SEES (the
      #      client renders non-OK turbo-stream bodies). It wins over the verbose
      #      diagnostic (both can't be the body); the diagnostic still logs below.
      #   2. else verbose_errors → the plain-text diagnostic (client console.errors it).
      #   3. else a bare head.
      # The warn log fires in EVERY environment first, so a misbehaving client is
      # debuggable from the server log alone regardless of which body path runs.
      def reactive_error(status, message, kind: nil)
        ::Rails.logger&.warn("[phlex-reactive] #{message}") if defined?(::Rails) && ::Rails.respond_to?(:logger)

        flash = error_flash_stream(kind)
        if flash
          render turbo_stream: flash, status: status
        elsif Phlex::Reactive.verbose_errors
          render plain: message, status: status
        else
          head status
        end
      end

      # Build the error flash turbo-stream when Phlex::Reactive.error_flash is
      # configured, else nil (the non-flash body paths run). Degrades gracefully:
      # a lambda that raises returns nil so the endpoint falls back to the bare/
      # diagnostic body and NEVER turns one failure into a 500.
      def error_flash_stream(kind)
        callable = Phlex::Reactive.error_flash
        return unless callable

        message = callable.call(kind)
        # flash_stream is a private Response builder (issue #182) — the endpoint's
        # error path is an internal caller, so reach it via send.
        Phlex::Reactive::Response.send(:flash_stream, :error, message, target: Phlex::Reactive.flash_target)
      rescue => e # rubocop:disable Style/RescueStandardError
        ::Rails.logger&.warn("[phlex-reactive] error_flash raised: #{e.message}") if defined?(::Rails) &&
                                                                                     ::Rails.respond_to?(:logger)
        nil
      end

      def undeclared_action_message(component_class)
        declared = component_class.reactive_actions.keys.join(", ")
        "action :#{reactive_action_name} is not declared on #{component_class.name} — " \
          "declared actions: #{declared}"
      end

      def record_not_found_message(payload)
        gid = payload.is_a?(Hash) && payload["gid"]
        return "record not found" unless gid

        "record #{gid} not found — deleted while a page still showed it?"
      end

      def authorization_error_message(error, component_class, action_def)
        where = [component_class&.name, action_def&.name].compact.join("#")
        "#{error.class.name} raised in #{where} — the signature proves identity, not permission; " \
          "authorize in the action"
      end

      # Run the action inside a transaction so transactional broadcasts (pgbus
      # broadcasts_to ... durable:) defer to after_commit and never fire for a
      # rolled-back change. Override to add per-request instrumentation.
      #
      # The actor's SSE connection id (sent as X-Pgbus-Connection) is exposed
      # for the duration of the action via Phlex::Reactive.current_connection_id,
      # so a broadcast in the action can pass exclude: reactive_connection_id
      # and skip the actor's own echo.
      #
      # The component-aware around_action stack (issue #112) folds in HERE —
      # INSIDE with_connection_id (so a wrapper's own broadcast can exclude the
      # actor) but OUTSIDE transaction_wrapper (so a rate-limit rejection never
      # opens a transaction, and an audit wrapper observes commit/rollback). The
      # fold returns the continuation's value unchanged, so the action's
      # Phlex::Reactive::Response survives to response_streams.
      def run_action(component, action_def, coerced)
        Phlex::Reactive.with_connection_id(request.headers["X-Pgbus-Connection"]) do
          with_around_actions(component, action_def, coerced) do
            transaction_wrapper do
              # verify_authorized (issue #168): open the tracking window, run the
              # action, then verify INSIDE the transaction so an unverified action
              # rolls its mutation back (fail-closed). with_tracking is a bare
              # yield's-worth of overhead; verify! is a no-op when the feature is
              # off / the action is skipped / something marked. The interceptor
              # (create_action's instrument!) marks the window on a real
              # authorization call.
              Phlex::Reactive::Authorization.with_tracking do
                result = if coerced.any?
                           component.public_send(action_def.name, **coerced)
                         else
                           component.public_send(action_def.name)
                         end
                Phlex::Reactive::Authorization.verify!(component.class, action_def)
                result
              end
            end
          end
        end
      end

      # Fold the registered around_action wrappers around `block`, innermost being
      # the transactioned action. The empty-stack fast path is a bare `yield` —
      # the default request gains only one Array#empty? check. Each wrapper is
      # called with the frozen ActionContext and the continuation as its block, so
      # a well-behaved wrapper returns action.call's value and the action's
      # Response propagates out unchanged (issue #112).
      #
      # Fold: seed the accumulator with the innermost action, then walk the stack
      # oldest → newest wrapping each wrapper AROUND the accumulated continuation.
      # The FIRST-registered wrapper wraps the action, and each later wrapper wraps
      # that — so the LAST-registered runs OUTERMOST (LIFO nesting).
      def with_around_actions(component, action_def, coerced, &block)
        stack = Phlex::Reactive.around_actions
        return yield if stack.empty?

        # A frozen DUP of the coerced params, not the live hash: the same hash is
        # splatted into the action below, so sharing it would let a wrapper mutate
        # ctx.params and alter the action's actual inputs — breaking both the
        # observe-only context contract and the schema-coercion guarantee. The
        # dup+freeze runs only when a wrapper is registered (never the empty-stack
        # hot path).
        ctx = Phlex::Reactive::ActionContext.new(
          component: component,
          action_name: action_def.name,
          params: coerced.dup.freeze,
          request: request
        )

        stack.reduce(block) do |inner, wrapper|
          -> { wrapper.call(ctx, &inner) }
        end.call
      end

      # Turn the action's return value into the turbo-stream(s) to render for
      # the actor. A Phlex::Reactive::Response is honored explicitly; any other
      # value (the legacy contract — return value ignored) falls back to the
      # implicit single replace, so existing actions are unaffected.
      def response_streams(result, component)
        return [component.to_stream_replace] unless result.is_a?(Phlex::Reactive::Response)
        return [redirect_stream(result.redirect_url)] if result.redirect?

        streams = result.streams

        # Partial update (reply.streams, issue #30): the action
        # re-rendered only PART of the component and opted out of the full-self
        # replace. Append a tiny token-only stream so the signed token still rolls
        # forward WITHOUT re-rendering (and clobbering) the live inputs. Skip it
        # only if the caller already supplied THIS component's token (idempotent) —
        # the dedupe is scoped to the actor's own target, NOT a global substring,
        # so a partial reply that legitimately includes another reactive
        # component's stream (which carries its OWN token) still refreshes ours.
        #
        # (refresh_token? implies render_self? is false — .streams/collections set
        # both — so folding this into the if/elsif below is behavior-preserving.)
        if result.refresh_token? && !carries_token_for?(streams, result.token_component)
          streams = [*streams, result.token_component.to_stream_token]

        # Guarantee the component's signed identity token is refreshed unless the
        # Response opted out (remove/redirect navigate away — handled above). The
        # client reads the next token from the response body (#extractToken), so
        # the real invariant is "a fresh data-reactive-token-value is present",
        # NOT "some stream targets self". Checking the token directly is correct
        # for replace AND update of self (both re-render the root via
        # render_component, carrying the token), and still adds the fallback
        # replace when a hand-built `with(...)` stream omits it. Idempotent: a
        # reply.replace/update already carries the token, so we
        # don't double the self-render.
        #
        # GUARD 2 (issue #114): GLOBAL, un-scoped — "does ANY stream carry a
        # token?", NOT target-scoped. A Stream answers from its precomputed
        # ground-truth flag (rx_carries_token?), a raw string from a substring
        # scan. Deliberately NOT rx_refreshes_token_for? (target-scoped): scoping
        # this guard would regress update/morph of self on an aliased id.
        #
        # A self-render reply (reply.replace/update/morph — subject_component
        # set) whose streams somehow carry no token gets the full self-replace
        # (defensive, unchanged). A companion-only reply.with (NO subject, NO
        # token_component) that doesn't re-render the root gets a token-ONLY
        # refresh instead — issue #180 automatic token refresh: reply.with and
        # reply.streams converge, the author never picks a verb to keep the token
        # fresh, and a live input is never clobbered by a forced replace.
        elsif result.render_self? && streams.none? { stream_carries_token?(it) }
          streams =
            if result.subject_component
              [component.to_stream_replace, *streams]
            else
              [*streams, component.to_stream_token]
            end
        end

        append_pending_streams(append_deferred_streams(streams, result), result)
      end

      # Pending segments (issue #248) ride LAST, alongside the deferred ones and
      # for the same reason: this runs AFTER run_action returned, i.e. after the
      # action's transaction COMMITTED — a rolled-back action takes the rescue
      # paths, so no pending marker and no subscription directive can ever
      # outlive a mutation that did not happen. (The ENQUEUE itself already ran
      # inside the action, exactly like the app's own perform_later would have;
      # its transactional behaviour is the queue adapter's, unchanged.) The
      # common non-pending reply pays one empty? check.
      def append_pending_streams(streams, result)
        return streams unless result.pending?

        [*streams, *result.pending_segments.flat_map { Phlex::Reactive::Pending.streams_for(it) }]
      end

      # Deferred segments (issue #165) ride LAST — after every render stream and
      # after the reactive:js op stream — so their placeholder/directive apply
      # to the fully-updated DOM (Turbo applies in document order) and delivery
      # kicks off only once the reply's own paints are in flight. This runs
      # AFTER run_action returned, i.e. after the action's transaction
      # COMMITTED — a rolled-back action takes the rescue paths and no directive
      # (or push-lane enqueue) can ever leak. The common non-defer reply pays
      # one empty? check.
      def append_deferred_streams(streams, result)
        return streams unless result.deferred?

        via = Phlex::Reactive::Defer.resolve_via
        [*streams, *result.deferred_segments.flat_map { Phlex::Reactive::Defer.streams_for(it, via:) }]
      end

      # GUARD 2 predicate. A Stream with intact metadata answers structurally
      # (O(1) flag read); a raw string / metadata-degraded object falls back to
      # the substring scan the endpoint always used.
      def stream_carries_token?(stream)
        if stream.is_a?(Phlex::Reactive::Stream) && stream.rx_action
          stream.rx_carries_token?
        else
          stream.include?(Phlex::Reactive::Stream::TOKEN_ATTR)
        end
      end

      # Actions that RE-RENDER the component's own root (so the root's fresh
      # data-reactive-token-value rolls the signed token forward). `append`/
      # `prepend` are deliberately excluded: they insert CHILDREN into the
      # component, and a reactive child carries its OWN token — that child token is
      # not the component's (issue #44). reactive:token is our inert token-only
      # refresh; replace/update re-render the root.
      #
      # Issue #114: a Phlex::Reactive::Stream now knows its own action structurally
      # (Stream::SELF_RENDER_ACTIONS), so this allowlist survives ONLY for the
      # LEGACY regex fallback below — the path raw strings (reply.with,
      # interpolated/degraded streams) take. The primary path is structural.
      SELF_RENDER_ACTIONS = %w[replace update reactive:token].freeze
      private_constant :SELF_RENDER_ACTIONS

      # GUARD 1 (issue #114): true when one of `streams` already carries a fresh
      # token by RE-RENDERING this component itself — so appending to_stream_token
      # would double it. Target+root scoped (distinct from GUARD 2's global scan).
      #
      # A Phlex::Reactive::Stream answers STRUCTURALLY (rx_refreshes_token_for? —
      # the three-way test carries_token AND renders_root AND same target, no
      # regex). A raw string / metadata-degraded object falls back to the legacy
      # opening-tag regex, which encodes the same rule:
      #   * A sibling component's replace targets a DIFFERENT id → no match, so we
      #     still refresh ours (issue #30).
      #   * A reactive child row appended/prepended INTO the component carries its
      #     own token at the component's target, but append/prepend do NOT
      #     re-render the root → no match, so we still refresh the CONTAINER's
      #     token (issue #44). Before this, the child's token at the container
      #     target suppressed the container's refresh and the list was
      #     add-once-only.
      def carries_token_for?(streams, component)
        streams.any? { stream_refreshes_token_for?(it, component.id) }
      end

      # Per-stream GUARD 1 predicate: a Stream with intact metadata answers
      # structurally (rx_refreshes_token_for?); a raw string / metadata-degraded
      # object falls back to the legacy opening-tag regex.
      def stream_refreshes_token_for?(stream, component_id)
        if stream.is_a?(Phlex::Reactive::Stream) && stream.rx_action
          stream.rx_refreshes_token_for?(component_id)
        else
          legacy_self_render_token?(stream, component_id)
        end
      end

      # LEGACY fallback for raw strings (reply.with) and metadata-degraded
      # streams: the pre-#114 substring + opening-tag regex, kept verbatim as the
      # floor beneath the structural path.
      def legacy_self_render_token?(stream, component_id)
        target = %(target="#{ERB::Util.html_escape(component_id)}")
        stream.include?("data-reactive-token-value") &&
          stream.include?(target) &&
          self_render_stream_for?(stream, target)
      end

      # Does this turbo-stream's OPENING tag re-render `target` itself? Matches a
      # `<turbo-stream action="<self-render>" ... target="<id>">` opening tag — the
      # action and target on the SAME tag — so a child row's token embedded in an
      # append/prepend `<template>` can never count as the container's own refresh.
      # LEGACY: only the raw-string fallback reaches this now.
      def self_render_stream_for?(stream, target)
        open_tag = stream[/<turbo-stream\b[^>]*>/]
        return false unless open_tag&.include?(target)

        action = open_tag[/\baction="([^"]+)"/, 1]
        SELF_RENDER_ACTIONS.include?(action)
      end

      # A 200 turbo-stream carrying a namespaced custom action the client turns
      # into Turbo.visit — NOT an HTTP 3xx, which the client hard-bails on
      # (response.redirected). The matching client handler is registered in
      # reactive_controller.js.
      def redirect_stream(url)
        %(<turbo-stream action="reactive:visit" data-url="#{ERB::Util.html_escape(url)}"></turbo-stream>)
      end

      def transaction_wrapper(&)
        if defined?(::ActiveRecord::Base)
          ::ActiveRecord::Base.transaction(&)
        else
          yield
        end
      end

      def verified_payload
        token = params.require(:token)
        Phlex::Reactive.verify(token) || raise(Phlex::Reactive::InvalidToken.new(
          "token signature invalid — stale token from before a deploy? secret_key_base mismatch? " \
          "a reply.with(...) stream that skipped the token refresh?",
          diagnostic: :tampered
        ))
      end

      # NB: must NOT be named `action_name` — that's reserved by
      # ActionController dispatch and overriding it recurses fatally.
      def reactive_action_name
        params.require(:act).to_sym
      end

      # Coerce client params against the action's compiled schema (issue #109 —
      # the coerce family now lives in Phlex::Reactive::ParamSchema). Anything not
      # in the schema is dropped — no raw mass assignment reaches the component.
      #
      # With verbose_errors on, ParamSchema fills a collector with every dropped
      # key (full bracketed path + reason) and we warn-log it once per action.
      # With the flag off the collector is nil and every diagnostic branch is
      # skipped — zero extra work on the production path.
      def coerce_params(action_def, component_class: nil, action_name: nil)
        dropped = Phlex::Reactive.verbose_errors ? [] : nil
        raw = unwrap_scope(params.fetch(:params, {}), component_class)
        raw = apply_empty_groups(raw, action_def.schema, component_class, dropped) if params[:empty_groups]

        coerced = action_def.schema.coerce(raw, dropped)
        log_dropped_params(dropped, action_def.params, component_class, action_name)
        coerced
      end

      # Issue #184: a scoped component's fields POST bracketed (todo[title]), which
      # Rails expands to { "todo" => { "title" => … } } before the action runs. Peel
      # exactly ONE scope level so the FLAT schema { title: :string } matches (the
      # #67 bracket-drop footgun). Only when the component declares reactive_scope
      # AND the raw params carry that single key mapping to a Hash — otherwise the
      # raw params pass through untouched (unscoped components + nested_attributes
      # shapes are unaffected).
      def unwrap_scope(raw, component_class)
        scope = reactive_scope_of(component_class)
        return raw unless scope

        # At the endpoint `raw` is ActionController::Parameters, so `raw[scope]` is
        # too — NOT a Hash. Accept either shape (both answer to the schema's
        # coerce): unwrap only when the scope key maps to a nested params/hash.
        nested = raw[scope.to_s]
        nested.is_a?(Hash) || nested.is_a?(ActionController::Parameters) ? nested : raw
      end

      # Issue #258: a form body cannot carry an empty array, so the client
      # ANNOUNCES a cleared `[]` group — its key absent from params, its name in
      # `empty_groups[]` beside token/act/params. Those names are written back as
      # empty arrays, the value the JSON path sends outright. The README documents
      # what the rule accepts and what it leaves alone.
      #
      # The key written is whatever `array_param` hands back, so it is always a
      # key the DECLARATION holds — never the announced name, which is only ever
      # compared. Runs AFTER unwrap_scope so the params root is the only target:
      # no node is built to reach a group, hence no nested-attributes row.
      def apply_empty_groups(raw, schema, component_class, dropped)
        names = params[:empty_groups]
        return raw unless names.is_a?(Array)
        # `raw` is whatever arrived: a String from `params=x` in a query string
        # normalises to {} in coerce, but writing into it would raise.
        return raw unless raw.is_a?(Hash) || raw.is_a?(ActionController::Parameters)

        scope = reactive_scope_of(component_class)
        # Flat is enough — only the root is written — and it keeps the filled key
        # off the request's own params object.
        raw = raw.dup
        names.each do
          key = announced_key(it, schema, scope)
          # Its OWN reason, not :undeclared: that one routes through the #16/#21
          # shape hints, which would read `empty_groups` as a param and advise
          # nesting the group under it. `dropped` is nil unless verbose_errors.
          next dropped&.<<(["empty_groups #{it}", ANNOUNCED_UNDECLARED]) unless key

          raw[key] = [] unless raw.key?(key)
        end
        raw
      end

      ANNOUNCED_UNDECLARED = :"undeclared — the action declares no array param by that name"
      private_constant :ANNOUNCED_UNDECLARED

      # The declared key an announced name resolves to, or nil — bare (`tags`) or
      # carrying the component's scope (`todo[tags]`), the two shapes the client
      # emits for one group. Anything else resolves to nothing, whatever its
      # type: array_param only answers with a key it already holds.
      def announced_key(name, schema, scope)
        schema.array_param(unscoped_group_name(name.to_s, scope))
      end

      # `todo[tags]` => `tags` under `reactive_scope :todo`. One level off the
      # front, never a walk — a deeper name (todo[a][tags]) keeps its remaining
      # brackets and simply fails the lookup.
      def unscoped_group_name(name, scope)
        return name unless scope

        prefix = "#{scope}["
        return name unless name.start_with?(prefix) && name.end_with?("]")

        name.delete_prefix(prefix).delete_suffix("]")
      end

      # Read the way unwrap_scope reads it — the peel and this strip have to
      # agree on the scope or an announced name lands at the wrong depth.
      def reactive_scope_of(component_class)
        component_class.reactive_scope if component_class.respond_to?(:reactive_scope)
      end

      # ---- verbose_errors dropped-param logging --------------------------
      # ParamSchema collects the dropped entries; the controller formats the ONE
      # warn line (with the #16/#21 shape hints). Everything below runs ONLY when
      # the collector exists (flag on); the production path never reaches it.

      # ONE warn line per action naming every dropped param with its reason —
      # plus, for the #16/#21 confusion, a hint when a dropped name looks like
      # the flat/bracketed twin of a declared key. `schema` is the RAW declared
      # hash (action_def.params), read only for the shape hints.
      def log_dropped_params(dropped, schema, component_class, action_name)
        return if dropped.nil? || dropped.empty?
        return unless defined?(::Rails) && ::Rails.respond_to?(:logger) && ::Rails.logger

        entries = dropped.map { |path, reason| "#{path} (#{dropped_reason(path, reason, schema)})" }
        where = [component_class, action_name].compact.join("#")
        where = "#{where} " unless where.empty?
        ::Rails.logger.warn("[phlex-reactive] #{where}dropped params: #{entries.join(", ")}")
      end

      def dropped_reason(path, reason, schema)
        return reason.to_s unless reason == :undeclared
        return "undeclared — the action declares no params" if schema.empty?

        hint = shape_hint(path, schema)
        hint ? "undeclared — #{hint}" : "undeclared"
      end

      # Fires only when a dropped segment matches a DECLARED key at a different
      # nesting level — a bracketed name whose leaf the schema declares flat, or
      # a flat name the schema declares one level down. Deliberately simple: it
      # searches one nesting level (hash / array-of-hash), no deeper.
      def shape_hint(path, schema)
        segments = bracket_path(path)
        if segments.length > 1
          leaf = segments.last
          return unless declared_key?(schema, leaf)

          "schema declares :#{leaf} at top level; nested schemas look like " \
            "{ #{segments.first}: { #{leaf}: :string } }"
        else
          parent = nested_declaration_of(segments.first, schema)
          return unless parent

          "schema declares :#{segments.first} nested under :#{parent}; " \
            "post it as #{parent}[#{segments.first}]"
        end
      end

      # A schema declares `name` whether it was written with a symbol or a
      # string key; ParamSchema.compile keeps whichever the author used.
      def declared_key?(schema, name)
        schema.key?(name.to_sym) || schema.key?(name.to_s)
      end

      # The first schema key whose nested hash (or array-of-hash element
      # schema) declares `name` one level down.
      def nested_declaration_of(name, schema)
        schema.find do |_key, type|
          inner = type.is_a?(Array) ? type.first : type
          inner.is_a?(Hash) && declared_key?(inner, name)
        end&.first
      end

      # Matches each bracket segment in "items_attributes][0][qty]" — the part
      # after the first "[". Hoisted to a frozen constant so the shape-hint path
      # (verbose only) doesn't recompile the pattern per call.
      BRACKET_SEGMENT = /[^\[\]]+/
      private_constant :BRACKET_SEGMENT

      # "invoice[date]" => ["invoice", "date"]. A key with no brackets is a
      # single-element path. Used only to shape the dropped-param hint.
      def bracket_path(key)
        return [key] unless key.include?("[")

        head, rest = key.split("[", 2)
        [head, *rest.scan(BRACKET_SEGMENT)]
      end

      # ---- end verbose_errors logging ------------------------------------

      # Only components that opt into Reactive may be resolved. The signature
      # already gates this; defense in depth against constant injection. The
      # two failure causes carry distinct diagnostics: a name that doesn't
      # resolve at all vs a constant that resolved but isn't a reactive
      # component.
      def resolve_component(name)
        klass = name.to_s.safe_constantize
        unless klass
          raise Phlex::Reactive::InvalidToken.new(
            "token class #{name} does not resolve — component renamed/removed while a page was open?",
            diagnostic: :unknown_class
          )
        end
        unless klass.respond_to?(:reactive_actions) && klass.include?(Phlex::Reactive::Component)
          raise Phlex::Reactive::InvalidToken.new(
            "#{name} resolved but does not include Phlex::Reactive::Component",
            diagnostic: :not_reactive_class
          )
        end

        klass
      end

      def authorization_errors
        Phlex::Reactive.authorization_errors
      end
    end
  end
end
