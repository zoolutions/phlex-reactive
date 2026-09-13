# frozen_string_literal: true

require "zeitwerk"
require "globalid"

# VERSION is a plain constant, not a Zeitwerk-managed file (it defines VERSION,
# not Version). Require it up front and ignore the file below so the loader
# never tries to load it — otherwise eager_load_all (host app with
# config.eager_load = true) raises Zeitwerk::NameError.
require_relative "reactive/version"

module Phlex
  # phlex-reactive: reactive Phlex components for Rails.
  #
  # Two cooperating mixins, one client runtime, one endpoint:
  #
  #   * Phlex::Reactive::Streamable — gives a component a stable `id` and class
  #     methods to render itself as a Turbo Stream (`.replace`, `.append`, ...)
  #     and to broadcast itself (`.broadcast_replace_to`, ...). The server->client
  #     half (controller responses + background broadcasts).
  #
  #   * Phlex::Reactive::Component — declares client-invokable `action`s and
  #     emits a signed identity token + the wiring the generic `reactive`
  #     Stimulus controller needs. The client->server half (clicks, form input).
  #
  # Both halves converge on ONE re-render unit: the component, targeted by its
  # `id`. See the README for the mental model and examples.
  module Reactive
    class Error < StandardError; end

    # Raised when a signed identity token fails verification (tampered, expired,
    # or signed with a different key) — or when a verified token names a class
    # that doesn't resolve to a reactive component. `diagnostic` classifies the
    # cause (:tampered, :unknown_class, :not_reactive_class) so the endpoint can
    # render a verbose_errors body explaining WHICH failure this was.
    class InvalidToken < Error
      attr_reader :diagnostic

      def initialize(msg = nil, diagnostic: nil)
        @diagnostic = diagnostic
        super(msg)
      end
    end

    # Raised at DECLARATION time (Component.action -> ParamSchema.compile) when a
    # param schema names a type symbol that isn't in the registry — a typo like
    # `params: { count: :interger }`. A stdlib ArgumentError subclass (NOT a
    # NameError): the mistake is a bad ARGUMENT to `action`, and callers rescue
    # ArgumentError, not NameError, for a bad-input contract. Loud at class load
    # (eager loading in production; first constant reference under Zeitwerk dev)
    # instead of a silent `to_s` at request time.
    #
    # Superclass is fully qualified `::ArgumentError`: the phlex gem defines
    # Phlex::ArgumentError, and a bare `ArgumentError` here resolves LEXICALLY to
    # that (Phlex::Reactive -> Phlex), coupling us to a Phlex error rather than
    # the stdlib one an app catches.
    class UnknownParamType < ::ArgumentError; end

    # Raised when the default-ON verify_authorized guard (issue #168) finds an
    # action completed WITHOUT any authorization call — the fail-closed
    # presence-side complement to authorization_errors. It fires INSIDE the
    # action's transaction, so the mutation rolls back, and it is NOT rescued
    # into a 4xx: it bubbles as a developer error (a 500 your error tracker
    # must see) because a missing authorize! is a bug, not a client fault. The
    # message names the component#action and all three remedies (call an
    # authorization method / mark_authorized! / declare skip_verify_authorized).
    class AuthorizationNotVerified < Error; end

    # Purpose string bound into every identity token's signature so a token
    # minted for phlex-reactive can't be replayed against another verifier use.
    IDENTITY_PURPOSE = "phlex-reactive/identity"

    # Purpose string for DEFER tokens (issue #165) — the short-TTL identity a
    # reply.defer directive carries so the client can fetch the expensive
    # render off the actor's critical path. A distinct purpose makes the two
    # token families non-interchangeable BY SIGNATURE: an action token is
    # rejected at the defer endpoint (it must not become a render oracle) and a
    # defer token can never invoke an action (it carries no action grant).
    DEFER_PURPOSE = "phlex-reactive/defer"

    # The defer_transport values (issue #165): :auto picks push (pgbus durable
    # one-shot stream + ActiveJob) when capable, else pull (parallel fetch);
    # :fetch forces pull; :stream requests push but still degrades to pull with
    # a warning when the capability is absent (degrade, never break).
    DEFER_TRANSPORTS = %i[auto fetch stream].freeze

    # The current identity-token payload version (issue #111), stamped into every
    # signed token under the "v" key. It exists so the NEXT breaking shape change
    # (a rename, per-token expiry, a nonce) can upgrade tokens already in flight
    # instead of breaking every open page at deploy. A token minted before this
    # existed carries no "v" — treated as version 0 (today's shape). Bump this and
    # register a register_token_upgrader(old_version) when you change the shape.
    TOKEN_VERSION = 1

    # The ActiveSupport::Notifications namespace for the gem's hot-path events
    # (issue #107): action.phlex_reactive, render.phlex_reactive,
    # broadcast.phlex_reactive. APM tools (AppSignal, Datadog, Skylight)
    # auto-subscribe to `*.phlex_reactive` and get component-level visibility.
    # Payloads carry NAMES/outcome/sizes ONLY — never the token, params, or state.
    INSTRUMENTATION_NAMESPACE = "phlex_reactive"

    # What a component-aware around_action wrapper sees (issue #112). Frozen: a
    # wrapper OBSERVES the resolved action — it must not mutate the context to
    # widen invokability (the token verify, component resolution, default-deny,
    # and schema coercion have already run and are not negotiable here).
    #   * component    — the resolved, identity-rebuilt component instance
    #   * action_name  — the declared action Symbol about to run
    #   * params       — the SCHEMA-COERCED params (dropped keys already gone)
    #   * request      — the ActionDispatch::Request (remote_ip, headers, ...)
    ActionContext = Data.define(:component, :action_name, :params, :request)

    class << self
      # The message verifier used to sign/verify component identity tokens.
      # Defaults to a purpose-scoped verifier derived from secret_key_base.
      # Override to use a dedicated key.
      attr_writer :verifier

      # The controller class used to render components with a full Rails view
      # context (url helpers, CSRF, i18n) during re-renders and broadcasts.
      # Defaults to ActionController::Base. Set to your ApplicationController if
      # components rely on app-level helpers or Current attributes.
      attr_writer :renderer

      # The controller the reactive ActionsController inherits from, given as a
      # String (resolved lazily to avoid load-order issues). Defaults to
      # "ActionController::Base"; set to "ApplicationController" to inherit your
      # app's auth/CSRF/Current. If you do, ensure the action path isn't
      # force-redirected for logged-out users when you have public components.
      attr_writer :base_controller_name

      # Exception classes the action endpoint renders as 403. Append your
      # authorization library's error (Pundit::NotAuthorizedError,
      # ActionPolicy::Unauthorized, ...).
      attr_accessor :authorization_errors

      # The path the action endpoint is mounted at. Default "/reactive/actions".
      # Set before boot if it collides with an app route. The client runtime
      # reads it from a <meta name="phlex-reactive-action-path"> tag if present,
      # falling back to this default.
      attr_writer :action_path

      def action_path
        @action_path ||= "/reactive/actions"
      end

      # Diagnostic endpoint error bodies + dropped-param logging. When true, an
      # endpoint failure (400/403/404) carries a plain-text explanation body
      # (the client already console.errors it) and param coercion warn-logs
      # every dropped key with its bracketed path and reason. Statuses never
      # change with the flag, and the endpoint's warn log fires regardless.
      #
      # Defaults LAZILY to Rails.env.local? — that's development AND test — so
      # production stays opaque unless you opt in. The `defined?` guard (not
      # `||=`) makes an explicit `= false` stick even in dev/test.
      attr_writer :verbose_errors

      def verbose_errors
        return @verbose_errors if defined?(@verbose_errors)

        defined?(::Rails.env) && ::Rails.env.local?
      end

      # Attach the opt-in LogSubscriber (issue #107) so each hot-path event is
      # debug-logged as one compact line (`[reactive] Counter#increment ok
      # (3.1ms)`). Default OFF — the events still fire for APMs regardless; this
      # only controls the gem's own log lines. The engine reads it at boot and
      # attaches exactly once. Set true in an initializer to see the lines.
      attr_writer :log_events

      def log_events
        return @log_events if defined?(@log_events)

        false
      end

      # Turnkey APM integration (issue #207). Set to a Symbol (:appsignal,
      # :sentry, :datadog), a custom adapter object (responding to
      # record_action/record_error), or nil (the default — off). A Symbol
      # resolves to a built-in adapter LAZILY, at engine attach time, so load
      # order doesn't matter; a set-but-undetectable SDK logs ONE warning at boot
      # and no-ops (the pgbus optionality invariant applied to APMs — no vendor
      # SDK is ever a hard dependency). When set and available, each reactive
      # action is named `Component#action` in the APM (not one blurry
      # ActionsController#create), and an action-body error is reported to the
      # tracker with component/action tags. Default nil.
      attr_accessor :apm

      # Client debug mode (issue #108): the "devtools-lite" lens on the reactive
      # round trip. When true, reactive_attrs (and so reactive_root) stamps
      # data-reactive-debug="true" on the root, and the generic controller
      # console.groups every dispatch — action, param/collected NAMES (never
      # values), request encoding, HTTP status, the response's stream actions +
      # targets, whether a token refresh arrived (never the token VALUE), and the
      # round-trip ms. Default OFF (the initializer template suggests
      # Rails.env.development?); zero cost when off (one nil-check per dispatch, no
      # attr, no string building). The `defined?` guard (not `||=`) makes an
      # explicit `= false` stick even where a truthy default might otherwise apply.
      attr_writer :debug

      def debug
        return @debug if defined?(@debug)

        false
      end

      # verify_authorized (issue #168): the default-ON runtime guard. When true,
      # an action that completes without any authorization call raises
      # AuthorizationNotVerified inside its transaction (fail-closed — the
      # mutation rolls back). Default ON is a deliberate, pre-1.0 breaking change:
      # a forgotten authorize! becomes a loud 500, not a silent hole. Opt out per
      # component with `skip_verify_authorized`, mark a bespoke check with
      # `mark_authorized!`, or turn it off globally here. The `defined?` guard
      # (not `||=`) makes an explicit `= false` stick.
      attr_writer :verify_authorized

      def verify_authorized
        return @verify_authorized if defined?(@verify_authorized)

        true
      end

      # The method names verify_authorized's interceptor wraps to detect an
      # authorization call (issue #168). Defaults to the common set across
      # authorization libraries — Pundit (`authorize`), CanCanCan (`authorize!`),
      # ActionPolicy (`authorize!`/`allowed_to?`). Set in an initializer to match
      # your app's helper. `mark_authorized!` always counts, regardless of this
      # list. The `defined?` guard makes an explicit override (including a
      # narrower list) stick.
      attr_writer :authorization_methods

      def authorization_methods
        return @authorization_methods if defined?(@authorization_methods)

        %i[authorize! authorize allowed_to?]
      end

      # Register an app-defined param type (issue #109). The block receives the
      # raw client value and returns the coerced value — or Phlex::Reactive::
      # ParamSchema::DROP to reject it (the keyword default then applies, keeping
      # the drop-don't-fabricate contract). Register in an INITIALIZER: the
      # registry is frozen after boot (freeze_param_types!), so a runtime
      # registration raises, and a schema referencing the type is validated at
      # declaration.
      #
      #   # config/initializers/phlex_reactive.rb
      #   Phlex::Reactive.param_type(:money) do |v|
      #     /\A\d+(\.\d{1,2})?\z/.match?(v.to_s) ? BigDecimal(v) : Phlex::Reactive::ParamSchema::DROP
      #   end
      #   # then: action :charge, params: { amount: :money }
      def param_type(name, &block)
        raise ::ArgumentError, "Phlex::Reactive.param_type requires a block" unless block

        if param_types_frozen?
          raise Error, "Phlex::Reactive.param_type(#{name.inspect}) called after boot — the param-type " \
                       "registry is frozen once the app is initialized. Register custom param types in an " \
                       "initializer (config/initializers/phlex_reactive.rb)."
        end

        param_types[name.to_sym] = block
      end

      # The param-type registry: Symbol => callable(value) -> coerced | DROP.
      # Seeded lazily with the built-ins; ParamSchema.compile validates every
      # declared type symbol against it, and #coerce dispatches through it.
      def param_types
        @param_types ||= Phlex::Reactive::ParamSchema.built_in_types.dup
      end

      # A declared type symbol is known iff it's a registry key. ParamSchema
      # asks this at compile so an unknown symbol raises loudly at declaration.
      def param_type?(name)
        param_types.key?(name.to_sym)
      end

      # Freeze the registry so no further param_type registration is accepted —
      # the initializer-only contract. Called by the engine's after_initialize.
      # Idempotent.
      def freeze_param_types!
        param_types.freeze
        @param_types_frozen = true
      end

      def param_types_frozen?
        @param_types_frozen ||= false
      end

      # Drop the registry back to the built-ins and unfreeze it. For tests that
      # register a temporary type; never called in production.
      def reset_param_types!
        @param_types = Phlex::Reactive::ParamSchema.built_in_types.dup
        @param_types_frozen = false
      end

      # Register (with a schema Hash) OR read (bare name) a NAMED param schema
      # (issue #184) — a reusable, boot-declared schema so sibling components stop
      # duplicating verbatim constants that drift. Follows the param_type contract:
      # register in an INITIALIZER (the registry freezes after boot).
      #
      #   # config/initializers/phlex_reactive.rb
      #   Phlex::Reactive.param_schema :todo, title: :string, done: :boolean
      #   # then: action :save, params: :todo
      #   # compose:  action :bulk, params: { **Phlex::Reactive.param_schema(:todo), note: :string }
      #
      # Reading an unknown name raises, listing the registered ones. The stored
      # schema is frozen; the reader returns it (compose with ** for a new Hash).
      def param_schema(name, schema = nil)
        return fetch_param_schema(name) if schema.nil?

        if param_schemas_frozen?
          raise Error, "Phlex::Reactive.param_schema(#{name.inspect}) called after boot — the param-schema " \
                       "registry is frozen once the app is initialized. Register named schemas in an " \
                       "initializer (config/initializers/phlex_reactive.rb)."
        end

        param_schemas[name.to_sym] = deep_freeze_schema(schema.transform_keys(&:to_sym))
      end

      def param_schemas
        @param_schemas ||= {}
      end

      def param_schema?(name)
        param_schemas.key?(name.to_sym)
      end

      def freeze_param_schemas!
        param_schemas.freeze
        @param_schemas_frozen = true
      end

      def param_schemas_frozen?
        @param_schemas_frozen ||= false
      end

      # Drop the named-schema registry and unfreeze it (tests only).
      def reset_param_schemas!
        @param_schemas = {}
        @param_schemas_frozen = false
      end

      private

      # Deep-freeze a registered schema so a nested Hash/Array (a nested-param
      # schema like { address: { street: :string } }) can't be mutated through the
      # memoized object fetch_param_schema returns — a top-level freeze alone leaves
      # inner structures writable, poisoning the shared registry entry. Symbolizes
      # nested keys too so composed-in nested schemas stay canonical.
      def deep_freeze_schema(value)
        case value
        when Hash then value.to_h { |k, v| [k.to_sym, deep_freeze_schema(v)] }.freeze
        when Array then value.map { deep_freeze_schema(it) }.freeze
        else value
        end
      end

      # Resolve a registered named schema, raising a guided error (listing the
      # registered names) for an unknown one — the action macro calls this to turn
      # `params: :todo` into the schema Hash.
      def fetch_param_schema(name)
        param_schemas.fetch(name.to_sym) do
          known = param_schemas.keys.sort.join(", ")
          raise ::ArgumentError,
            "Phlex::Reactive.param_schema(#{name.inspect}) is not registered. " \
            "Registered schemas: #{known.empty? ? "(none)" : known}."
        end
      end

      public

      # Emit an `<event>.phlex_reactive` ActiveSupport::Notifications event around
      # a block, yielding the mutable payload so a rescue can finalize the outcome
      # (issue #107). ASN.instrument is cheap when nothing is subscribed (the hot
      # paths depend on this — proven by the render bench), so this wraps the
      # render/broadcast/action paths unconditionally. The payload must carry
      # NAMES/outcome/sizes ONLY — never token/params/state.
      def instrument(event, payload = {}, &)
        ::ActiveSupport::Notifications.instrument("#{event}.#{INSTRUMENTATION_NAMESPACE}", payload, &)
      end

      # Register a COMPONENT-AWARE around_action wrapper (issue #112). The block
      # is folded into the endpoint BETWEEN with_connection_id and the action's
      # transaction — so it sees the resolved component instance, the declared
      # action name, and the coerced params (an ActionContext), and a rejection
      # NEVER opens a transaction. This is the seam for audit logging,
      # component-aware rate limiting, and assertions; the base controller
      # (base_controller_name) remains the seam for HTTP-layer concerns (auth,
      # CSRF, coarse per-IP rate limiting) that don't need the resolved action.
      #
      #   Phlex::Reactive.around_action do |ctx, &action|
      #     RateLimiter.check!(ctx.request.remote_ip, ctx.action_name) # raise -> 403
      #     result = action.call
      #     AuditLog.record!(actor: Current.user, action: ctx.action_name)
      #     result   # <- REQUIRED: return the continuation's value
      #   end
      #
      # CONTRACT — each wrapper MUST return `action.call`'s value. The endpoint
      # type-checks the action's return for a Phlex::Reactive::Response; a wrapper
      # that returns its logger's result instead silently downgrades every reply
      # to the implicit self-replace. Wrappers nest in registration order with the
      # LAST-registered outermost. Register in an initializer.
      def around_action(&block)
        raise ::ArgumentError, "Phlex::Reactive.around_action requires a block" unless block

        around_actions << block
      end

      # The registered around_action wrappers, oldest first. The endpoint folds
      # them so the last-registered runs outermost; an empty stack is the default
      # hot path (the controller short-circuits with `return yield`).
      def around_actions
        @around_actions ||= []
      end

      # Drop all registered around_action wrappers. For test isolation (the
      # shipped hook — specs registering a temporary wrapper reset around every
      # example); never called in production.
      def reset_around_actions!
        @around_actions = []
      end

      # Register a block called when a reactive action body raises a
      # previously-uncaught error (issue #207) — the DIY escape hatch for a tracker
      # the gem ships no adapter for, usable WITHOUT choosing an `apm` Symbol. The
      # block receives (error, context) where context is the name-only event payload
      # ({ component:, action:, outcome: :error }). It runs INSIDE the endpoint's
      # error handling, just before the exception is re-raised — so Rails' own error
      # reporting still fires afterward. Register in an initializer.
      #
      #   Phlex::Reactive.on_action_error do |error, ctx|
      #     Honeybadger.notify(error, context: { component: ctx[:component], action: ctx[:action] })
      #   end
      def on_action_error(&block)
        raise ::ArgumentError, "Phlex::Reactive.on_action_error requires a block" unless block

        on_action_error_hooks << block
      end

      # The registered on_action_error hooks, oldest first.
      def on_action_error_hooks
        @on_action_error_hooks ||= []
      end

      # Drop all registered on_action_error hooks. Test isolation; never in production.
      def reset_on_action_error!
        @on_action_error_hooks = []
      end

      # The name-only keys forwarded to error reporters (issue #207). Deliberately
      # NOT the whole event hash: ActiveSupport::Notifications mutates the SAME hash
      # during error unwinding, adding :exception / :exception_object — a reporter
      # that RETAINS the hash would later observe those, breaking the name-only
      # contract. report_error forwards a fresh slice of just these keys.
      ERROR_CONTEXT_KEYS = %i[component action outcome].freeze

      # Report a previously-uncaught action-body error to the resolved APM adapter
      # AND every registered on_action_error hook (issue #207). Called by the
      # endpoint's error seam just before it re-raises. Each reporter is wrapped in
      # its own rescue so a broken reporter can NEVER turn one 500 into a different
      # 500 (or swallow the original — the endpoint re-raises regardless). `context`
      # is the mutable event payload; we forward a NAME-ONLY SNAPSHOT (a fresh Hash
      # of ERROR_CONTEXT_KEYS) so a reporter that retains it never picks up the
      # :exception keys ASN adds to the live hash afterward. Best-effort and
      # side-effect only: the return value is ignored.
      def report_error(error, context)
        snapshot = context.slice(*ERROR_CONTEXT_KEYS)
        adapter = @resolved_apm_adapter
        # Each reporter runs through safely_report on its OWN — one broken reporter
        # (a raising adapter or hook) never prevents the others, and never turns one
        # 500 into a different 500. safely_report takes the reporter as a block arg,
        # so there's no nested-block ambiguity.
        safely_report { adapter.record_error(error, snapshot) } if adapter
        on_action_error_hooks.each { report_hook(it, error, snapshot) }
        nil
      end

      # Run one on_action_error hook through safely_report. Extracted so the
      # per-hook isolation reads as one call (no nested reporter block in the loop).
      def report_hook(hook, error, context)
        safely_report { hook.call(error, context) }
      end

      # The APM adapter resolved at engine attach time (issue #207), or nil. Held so
      # report_error can reach record_error without re-running detection per request.
      # Set by APM.attach!; nil when no APM is configured or the SDK was absent.
      attr_accessor :resolved_apm_adapter

      def verifier
        @verifier ||= default_verifier
      end

      def renderer
        @renderer ||= defined?(::ActionController::Base) ? ::ActionController::Base : nil
      end

      # Build an off-request view context whose controller has a REAL `request`.
      #
      # A bare `controller.new.view_context` (the naive off-request context) has
      # `request == nil`, so any request-dependent helper raises
      # `undefined method 'env' for nil` — form_authenticity_token,
      # protect_against_forgery?, and host-aware URL helpers all read
      # `request.env` (issue #42). We replicate exactly what
      # ActionController::Renderer#render does to set up its mock request — build
      # an ActionDispatch::Request from the renderer's env (which derives the host
      # from the routes' default_url_options), bind the routes, and attach it —
      # then return the controller's view context instead of rendering a template.
      # The result keeps the 0.4.0 render_in speedup (no renderer.render
      # machinery) while restoring the request those helpers need.
      def request_bound_view_context(controller_class)
        ar_renderer = controller_class.renderer
        request = ::ActionDispatch::Request.new(ar_renderer.send(:env_for_request))
        request.routes = controller_class._routes

        instance = controller_class.new
        instance.set_request!(request)
        instance.set_response!(controller_class.make_response!(request))

        # Issue #232: during a reactive request the endpoint threads the actor's
        # protocol/host/port via with_url_options; merge them over this
        # instance's defaults so absolute URL helpers in a reply render the
        # REQUESTING host. View contexts delegate url_options to their
        # controller (ActionView::RoutingUrlFor), so this one override covers
        # every helper spelling. Off-request (thread-local nil — jobs, console,
        # broadcasts) returns super's frozen memo untouched: zero-alloc, byte-
        # identical URLs. Defined on the singleton because this instance is
        # MEMOIZED per thread — its request (and super's @_url_options) never
        # changes, so the per-call merge is the only per-request seam.
        def instance.url_options
          overrides = Phlex::Reactive.current_url_options
          overrides ? super.merge(overrides) : super
        end

        instance.view_context
      end

      # --- Deferred reply segments (issue #165) --------------------------

      # Lifetime (seconds) of a defer token. It only needs to cover the
      # reply→fetch gap (or reply→job→SSE on the push lane), so it stays short:
      # a leaked defer token is a render oracle for exactly one component
      # identity until this expires. nil resets to the default.
      attr_writer :defer_token_ttl

      def defer_token_ttl
        @defer_token_ttl ||= 120
      end

      # The path the defer endpoint is mounted at (the pull lane's target).
      # Default "/reactive/defer"; set before boot if it collides.
      attr_writer :defer_path

      def defer_path
        @defer_path ||= "/reactive/defer"
      end

      # How deferred segments reach the actor: :auto (push iff capable, else
      # pull), :fetch (always pull), :stream (push; degrades to pull with a
      # warning when the capability is absent). Validated at assignment — a
      # typo'd transport must fail at the initializer, not silently at reply
      # time. nil resets to the default.
      def defer_transport
        @defer_transport ||= :auto
      end

      def defer_transport=(value)
        value = value&.to_sym
        unless value.nil? || DEFER_TRANSPORTS.include?(value)
          raise ::ArgumentError,
            "Phlex::Reactive.defer_transport must be one of #{DEFER_TRANSPORTS.map(&:inspect).join(", ")} " \
            "(got #{value.inspect})"
        end

        @defer_transport = value
      end

      # The ActiveJob queue the push lane's DeferredRenderJob runs on. Default
      # "default"; point it at a fast queue in production — a deferred segment
      # is a UX-latency render, and letting it starve behind heavy jobs defeats
      # the point. nil resets to the default.
      attr_writer :defer_job_queue

      def defer_job_queue
        @defer_job_queue ||= "default"
      end

      # Signs a defer payload (issue #165): same shape + version stamp as the
      # identity token, but purpose-scoped to DEFER_PURPOSE and expiring after
      # defer_token_ttl. verify/verify_defer are therefore mutually exclusive
      # by construction — see the DEFER_PURPOSE comment.
      # SECURITY (the leaked-token exchange): the defer endpoint re-renders the
      # real component, whose root carries a fresh NON-expiring identity (action)
      # token — so a leaked defer token replayed by ANOTHER actor within its TTL
      # would hand that actor a permanent action token for the same identity.
      # The purpose is therefore ALSO scoped to the minting actor's binding (the
      # session id, via with_defer_binding), so a defer token minted under
      # binding A fails verification under binding B — the exchange can't cross
      # actors. Unbound (no session — the ActionController::Base default) is the
      # documented today-behavior; `authorize!` in the action stays the real
      # authority in every case.
      # Sign a defer token. `unbound: true` (the reactive_lazy channel) mints
      # under the PLAIN DEFER_PURPOSE, never the /binding suffix — because a
      # lazy shell renders during the PAGE render, on a fresh visit where the
      # session doesn't exist yet (Rails establishes it DURING that response),
      # so it can't be bound; and it lives in the actor's own page, a small leak
      # surface. reply.defer tokens (the default) mint under the current actor's
      # binding — they live in an action HTTP response that can transit proxies/
      # logs, the real cross-infrastructure leak vector. See docs/security +
      # the README defer security note. `authorize!` in the action is the real
      # authority for the harvested-action-token step in both cases.
      def sign_defer(payload, unbound: false)
        purpose = unbound ? DEFER_PURPOSE : defer_purpose
        verifier.generate(payload.merge("v" => TOKEN_VERSION), purpose:, expires_in: defer_token_ttl)
      end

      # Returns the verified, version-upgraded defer payload, or nil when the
      # token is tampered, expired, carries the wrong purpose (an action token
      # OR a BOUND token minted under a DIFFERENT actor binding), or a version
      # this code doesn't understand — all fail closed through the endpoint's
      # InvalidToken → 400 path. Tries the current-binding purpose first (the
      # reply.defer, actor-bound case), then falls back to the plain
      # DEFER_PURPOSE (the unbound lazy case) — so an unbound lazy token
      # resolves under ANY binding, while a bound token minted under session-A
      # still fails under session-B (it was signed with /session-A, which
      # matches NEITHER /session-B nor the plain purpose).
      def verify_defer(token)
        payload = verifier.verified(token, purpose: defer_purpose)
        payload ||= verifier.verified(token, purpose: DEFER_PURPOSE) if current_defer_binding
        payload && upgrade_token(payload)
      end

      # The purpose string for the CURRENT actor's defer tokens: the base
      # DEFER_PURPOSE, plus the binding when one is present. Binding is folded
      # into the PURPOSE (not the payload) so it's part of the signature's
      # domain separation — a mismatched binding is a verification failure, not
      # a value the endpoint must remember to compare.
      def defer_purpose
        binding = current_defer_binding
        binding ? "#{DEFER_PURPOSE}/#{binding}" : DEFER_PURPOSE
      end

      # The acting client's defer binding during a request, or nil. Set by the
      # ActionsController from defer_binding_for(request) — threaded exactly
      # like current_connection_id.
      def current_defer_binding
        Thread.current[:phlex_reactive_defer_binding]
      end

      def with_defer_binding(binding)
        previous = Thread.current[:phlex_reactive_defer_binding]
        Thread.current[:phlex_reactive_defer_binding] = binding.presence
        yield
      ensure
        Thread.current[:phlex_reactive_defer_binding] = previous
      end

      # Resolve a request to its defer binding: the id of an ALREADY-PERSISTED
      # session, else nil. The `exists?` gate is load-bearing — a bare
      # `session.id` LAZILY generates an id even for an empty, never-written
      # session, and that id is NOT persisted (no Set-Cookie), so two requests
      # for the same read-only page get DIFFERENT lazy ids and a bound token
      # minted on one is rejected on the other. Only a persisted session (an
      # authenticated app wrote one at login) has a stable id across the mint
      # (page render / action) and the verify (defer endpoint) — exactly the
      # case where cross-actor exchange is the real threat. A read-only page
      # with no session mints + verifies UNBOUND consistently (the TTL +
      # `authorize!` remain the bound). Tolerant of a store that lazily raises:
      # degrade to nil (unbound), never a 500. Override to bind to your own
      # actor identity (a stable user id, an API-token digest) — recommended for
      # a token-authenticated API with no cookie session.
      def defer_binding_for(request)
        session = request.session
        return nil unless session.respond_to?(:exists?) && session.exists?

        session.id&.to_s
      rescue StandardError
        nil
      end

      # --- pgbus capability gates (issue #165) ---------------------------
      # Runtime capability detection, never `defined?(Pgbus)` alone or a
      # version string (the core optionality invariant): pgbus < 0.9.2 also
      # defines ::Pgbus, so the Streams gate probes the ACTUAL keyword.

      # Necessary but NOT sufficient — the Streams entrypoint exists.
      def pgbus?
        return false unless defined?(::Pgbus)

        ::Pgbus.respond_to?(:stream)
      end

      # The reactive-Streams capability: Stream#broadcast accepts :exclude
      # (the pgbus >= 0.9.2 shape). This is the gate that prevents
      # `ArgumentError: unknown keyword :exclude` on an old pgbus.
      def pgbus_streams?
        return false unless pgbus?
        return false unless defined?(::Pgbus::Streams::Stream)

        ::Pgbus::Streams::Stream.instance_method(:broadcast)
          .parameters.any? { |_type, name| name == :exclude }
      rescue ::NameError
        false
      end

      # Everything the defer PUSH lane needs at runtime: streams-capable pgbus,
      # server-side signed-src minting (SignedName.sign — the element's src is
      # built off-request), and ActiveJob to run the render off the request
      # thread. Anything missing → the pull lane (which is always available).
      def defer_push_capable?
        return false unless pgbus_streams?
        return false unless defined?(::Pgbus::Streams::SignedName) &&
                            ::Pgbus::Streams::SignedName.respond_to?(:sign)

        defined?(::ActiveJob::Base) ? true : false
      end

      # --- Async-action lifecycle / settles (issue #248) -----------------

      # Lifetime (seconds) of a settle's FALLBACK pull token. Distinct from
      # defer_token_ttl (120) because a settle waits on a background JOB, which
      # can sit behind a staggered fan-out for minutes — where a defer only has
      # to cover the reply->fetch gap. nil resets to the default.
      attr_writer :settle_token_ttl

      def settle_token_ttl
        @settle_token_ttl ||= 900
      end

      # Window (ms) the AGGREGATE settle streams coalesce on — the count
      # companion, the empty-state toggle, any companion refresh. They are
      # idempotent replaces of stable targets, so a 177-row fan-out collapses to
      # a handful of them instead of 177. The ROW streams are never coalesced.
      # Needs pgbus with zoolutions/pgbus#465 on the peers path; without it the
      # window is simply ignored. nil resets to the default.
      attr_writer :settle_coalesce_window_ms

      def settle_coalesce_window_ms
        @settle_coalesce_window_ms ||= 50
      end

      # Can reply.pending mint a settle handle at all? A settle has NO pull
      # fallback — the client cannot poll "is the job done yet" — so it needs
      # the defer PUSH lane (durable pgbus one-shot stream + ActiveJob). A
      # forced defer_transport of :fetch is therefore also a no.
      #
      # False does NOT break anything: reply.pending degrades to a plain
      # enqueue (no pending markers, no handle, reactive_settle no-ops in the
      # job) — today's behavior, never a permanently pending row.
      def settle_capable?
        defer_push_capable? && defer_transport != :fetch
      end

      # DOM id of the host-app container a Response#flash appends into.
      # Default "flash"; override to match your layout's flash region.
      def flash_target
        @flash_target ||= "flash"
      end

      attr_writer :flash_target

      # Global effects opt-in (issue #215). nil (the default) = OFF: no root
      # attrs are emitted anywhere, the wire is byte-identical to pre-effects,
      # and the client interceptor sees nothing to do. Setting it is the
      # opt-in AND the app-wide default set — refined per component with
      # `reactive_effects` and per call with `effect:` (most specific wins):
      #
      #   Phlex::Reactive.effects = true   # { enter: :fade, exit: :fade, update: :highlight }
      #   Phlex::Reactive.effects = { enter: :slide, update: :highlight }
      #
      # Stored pre-normalized (wire strings), validated at WRITE time — a
      # typo'd effect name raises here, not at render time.
      def effects
        defined?(@effects) ? @effects : nil
      end

      def effects=(value)
        @effects = Phlex::Reactive::Effects.normalize_config(value)
        @effects_generation = effects_generation + 1
      end

      # Monotonic write counter for effects= — the cache key half that lets
      # each component class memoize its RESOLVED effect attrs (reactive_attrs
      # is the token-signing hot path) without ever serving a stale config.
      def effects_generation
        @effects_generation ||= 0
      end

      # A user-visible flash rendered on every endpoint rescue path (issue #100).
      # Default nil = today's behavior (a bare head, or the verbose_errors
      # plain-text diagnostic). Set a lambda ->(kind) { "message" } (kind is
      # :tampered/:unknown_class/:not_reactive_class/:forbidden/:not_found) and
      # the ActionsController ALSO renders a turbo-stream flash into flash_target
      # — at the SAME status it returns today (statuses never change). Composes
      # with verbose_errors: the turbo-stream flash wins the response body, the
      # diagnostic still goes to the log.
      attr_accessor :error_flash

      # A CALLABLE that builds a flash component from STRING flash content (issue
      # #182). Given (level, content), it returns a Phlex component the gem renders
      # in place of the built-in <div class="reactive-flash reactive-flash--{level}">
      # wrapper — so the APP owns the kwarg mapping (no hardcoded new(level:,
      # content:) contract that collides with a real app's flash component):
      #
      #   Phlex::Reactive.flash_component = ->(level, content) { MyFlash.new(level:, message: content) }
      #
      # Default nil (the built-in wrapper). Phlex component content passed to
      # reply.flash always renders verbatim and bypasses this.
      attr_reader :flash_component

      # Reject a bare Class (the pre-#182 contract) with the exact lambda rewrite —
      # the gem no longer guesses the component's kwargs.
      def flash_component=(callable)
        if callable.is_a?(Class)
          raise ArgumentError,
            "Phlex::Reactive.flash_component is now a callable (issue #182) — " \
            "flash_component = ->(level, content) { #{callable}.new(level:, content:) }"
        end

        @flash_component = callable
      end

      # Render a Phlex component to HTML with a full (off-request) view context.
      # Uses phlex-rails' #render_in against the memoized view context — a direct
      # component.call that skips ActionController's renderer.render machinery
      # (~2x faster, ~half the allocations), with the same HTML and full helper
      # access (dom_id/url_for/t/csrf). Used for a Phlex component embedded as
      # Response#with content.
      def render(component)
        # A machinery render (issue #165): a reactive_lazy component embedded
        # in a Response/flash renders its REAL template — the lazy shell is
        # for the page-embedded initial mount only.
        Phlex::Reactive::Defer.with_real_render { component.render_in(off_request_view_context) }
      end

      # Module-level broadcast (issue #185) — the same broadcast_to as the class
      # form, for a BUILT component payload, so a NON-Streamable target (a count
      # badge, any plain Phlex component) broadcasts WITHOUT hand-rolling the raw
      # channel + render, and IS instrumented:
      #
      #   Phlex::Reactive.broadcast_to(@list, :todos, update: TodoCount.new(list: @list), target: "todos-count")
      #   Phlex::Reactive.broadcast_to(user, :alerts, replace: NotificationsBadge.new(user:))
      #
      # Container verbs (update:/append:/prepend:) take any component; self-targeting
      # verbs (replace:/remove:) require a Streamable payload (its #id is the target)
      # — a plain component gets a guided error steering to update:. Shares the one
      # broadcast implementation with the class-level form.
      def broadcast_to(*streamables, morph: false, target: nil, exclude: nil, visible_to: nil, each: nil,
                       effect: nil, **verb)
        name, payload = Phlex::Reactive::Streamable.extract_module_broadcast_verb(verb)
        component = name == :js ? nil : payload
        keys = each ? each.map { Array(it) } : [streamables]
        # The owner is the payload's class when Streamable (for js ops + instrument),
        # else Streamable itself (a plain component still instruments via the shared
        # path). A nil payload (a bare state-backed default) isn't supported here —
        # the module form is for BUILT component payloads.
        owner = payload.is_a?(Phlex::Reactive::Streamable) ? payload.class : Phlex::Reactive::Streamable
        Phlex::Reactive::Streamable.broadcast_component(
          owner, name, payload, component, keys, morph:, target:, exclude:, visible_to:, effect:
        )
      end

      # A Turbo::Streams::TagBuilder bound to an off-request view context, used
      # to build standalone streams not tied to a specific component's id — a
      # Response flash append, a reactive_collection row removal, a count
      # companion update, an also() companion. Cached PER THREAD alongside
      # the context it's bound to (see off_request_view_context for why
      # per-thread). Renamed from flash_builder (issue #113): the builder does
      # far more than flashes, so the name misled. flash_builder stays a
      # permanent alias below so the engine's to_prepare and app code keep working.
      def stream_builder
        off_request_view_context_cache[:builder]
      end

      # The off-request view context for the current thread, built once and
      # reused for both the stream builder and standalone component renders.
      # Cached PER THREAD, not per process: an ActionView context carries mutable
      # output_buffer/view_flow state (render_in's capture swaps it), so sharing
      # one instance across threads can interleave content on a threaded server.
      # Rebuilt when the renderer object changes or the generation is bumped
      # (reset_stream_builder! / Rails code reload), so a reloaded controller is
      # never served stale.
      def off_request_view_context
        off_request_view_context_cache[:view_context]
      end

      # Invalidate the per-thread context + builder for ALL threads by bumping
      # the generation; each thread rebuilds lazily on next use. Registered on
      # Rails' reloader by the engine; also used by specs. Thread-safe (an
      # integer bump, no shared structure to tear down). Renamed from
      # reset_flash_builder! (issue #113); the old name stays a permanent alias
      # below so the engine's to_prepare hook keeps working.
      def reset_stream_builder!
        @off_request_view_context_generation = off_request_view_context_generation + 1
      end

      # Issue #182: the pre-#113 aliases are removed (they contradicted the
      # clean-break rule — two names for one thing). Each raises a guided error
      # naming the real method. The engine (to_prepare) already uses the new names.
      def flash_builder
        raise NoMethodError,
          "Phlex::Reactive.flash_builder was removed in issue #182 — use stream_builder"
      end

      def reset_flash_builder!
        raise NoMethodError,
          "Phlex::Reactive.reset_flash_builder! was removed in issue #182 — use reset_stream_builder!"
      end

      def off_request_view_context_generation
        @off_request_view_context_generation ||= 0
      end

      private

      def off_request_view_context_cache
        cache = Thread.current[:phlex_reactive_off_request_view_context]
        current = renderer
        generation = off_request_view_context_generation

        unless cache && cache[:renderer].equal?(current) && cache[:generation] == generation
          view_context = request_bound_view_context(current)
          cache = {
            view_context: view_context,
            builder: ::Turbo::Streams::TagBuilder.new(view_context),
            renderer: current,
            generation: generation
          }
          Thread.current[:phlex_reactive_off_request_view_context] = cache
        end
        cache
      end

      public

      def base_controller_name
        @base_controller_name ||= "ActionController::Base"
      end

      def base_controller
        base_controller_name.constantize
      end

      # Returns the verified, version-upgraded payload hash, or nil if the token
      # is invalid (bad signature/purpose) OR carries a version this code doesn't
      # understand. The single verify choke point (issue #111): after the
      # signature check we run upgrade_token so an older-shape payload is migrated
      # to the current shape before from_identity ever sees it.
      def verify(token)
        payload = verifier.verified(token, purpose: IDENTITY_PURPOSE)
        payload && upgrade_token(payload)
      end

      # Signs a payload hash into an identity token, stamping the current
      # TOKEN_VERSION (issue #111). The "v" key is the ONLY thing added — a
      # from_identity that ignores unknown keys is unaffected.
      def sign(payload)
        verifier.generate(payload.merge("v" => TOKEN_VERSION), purpose: IDENTITY_PURPOSE)
      end

      # Migrate a verified payload from whatever version it was signed at up to
      # TOKEN_VERSION (issue #111). Runs the registered upgraders oldest → current,
      # then stamps the payload to the current version. Contract:
      #   * no "v"  → version 0 (the shape from before versioning existed). With no
      #     v0 upgrader registered this is a pure passthrough — introducing
      #     versioning invalidates NOTHING already in flight.
      #   * v == current → returned as-is (the hot path — one integer compare).
      #   * v  > current → nil. A rolled-back deploy verifying a token minted by
      #     NEWER code must not guess the newer shape; returning nil fails closed
      #     through the endpoint's existing `|| raise(InvalidToken)` → 400.
      def upgrade_token(payload)
        version = payload.fetch("v", 0)
        # "v" is inside the signed blob, so only our own key could produce a
        # malformed one — but fail closed rather than 500 on the comparison
        # (String vs Integer) or silently treat a negative "v" as legacy.
        return nil unless version.is_a?(::Integer) && version >= 0
        return payload if version == TOKEN_VERSION
        return nil if version > TOKEN_VERSION

        upgrade_from(payload, version)
      end

      # Register an upgrader that rewrites a payload signed at `from_version` into
      # the shape of `from_version + 1` (issue #111). Register in load order at
      # boot when you bump TOKEN_VERSION; the block receives the payload hash and
      # returns the migrated hash (the "v" stamp is applied by upgrade_token, so
      # the block only reshapes the data). Example, for a future count → n rename:
      #
      #   Phlex::Reactive.register_token_upgrader(0) do |payload|
      #     payload.merge("s" => { "n" => payload.dig("s", "count") })
      #   end
      def register_token_upgrader(from_version, &block)
        raise ::ArgumentError, "register_token_upgrader requires a block" unless block

        token_upgraders[Integer(from_version)] = block
      end

      # from_version => callable(payload) -> migrated payload. Sparse: an entry
      # exists only for a version that actually changed shape.
      def token_upgraders
        @token_upgraders ||= {}
      end

      # Drop all registered upgraders. For tests that register a temporary one.
      def reset_token_upgraders!
        @token_upgraders = {}
      end

      # The acting client's SSE connection id during an action, or nil. Set by
      # the ActionsController from the X-Pgbus-Connection header. A component
      # action passes `exclude: Phlex::Reactive.current_connection_id` (or the
      # `reactive_connection_id` helper) to suppress the actor's own broadcast
      # echo.
      def current_connection_id
        Thread.current[:phlex_reactive_connection_id]
      end

      def with_connection_id(connection_id)
        previous = Thread.current[:phlex_reactive_connection_id]
        Thread.current[:phlex_reactive_connection_id] = connection_id.presence
        yield
      ensure
        Thread.current[:phlex_reactive_connection_id] = previous
      end

      # The acting request's url_options during a reactive request, or nil
      # (issue #232). Set by the ActionsController (the action AND defer
      # endpoints) so absolute URL helpers in a reply-rendered component —
      # image_tag on an Active Storage attachment being the everyday case —
      # carry the REQUESTING host/port/protocol instead of the process default
      # (the ActiveStorage::SetCurrent move). The memoized off-request view
      # context merges this over its defaults per call (see
      # request_bound_view_context); nil (jobs, console, plain broadcasts)
      # leaves the defaults untouched — byte-identical to before.
      def current_url_options
        Thread.current[:phlex_reactive_url_options]
      end

      # Thread `options` for the block, restoring the previous value after.
      # `nil` CLEARS the actor options — the broadcast render uses this to keep
      # a broadcast fired inside an action on process defaults (subscribers can
      # be on different hosts; "URLs in broadcast-rendered components must be
      # host-relative" is the broadcast contract).
      def with_url_options(options)
        previous = Thread.current[:phlex_reactive_url_options]
        Thread.current[:phlex_reactive_url_options] = options.presence
        yield
      ensure
        Thread.current[:phlex_reactive_url_options] = previous
      end

      # The url_options trio derived from a live request. `port` is optional_port
      # — nil on the default port — and is INCLUDED even when nil so a
      # default-port request clears any configured default port rather than
      # inheriting it (the merge must own the whole trio).
      def url_options_for(request)
        { protocol: request.protocol, host: request.host, port: request.optional_port }
      end

      # The controller a correctly-mounted action path resolves to. Used by the
      # route guard below.
      ACTIONS_CONTROLLER = "phlex/reactive/actions"

      # True when a POST to `path` resolves to the gem's ActionsController. A host
      # catch-all route (match "*path", ...) appended above the engine's route
      # SHADOWS it, so every reactive POST 404s and none of the controller runs —
      # the opaque "is the endpoint even mounted?" failure (issue #26). A false
      # here is the signal. Returns false (not raise) when nothing matches.
      def action_route_ok?(path = action_path)
        return false unless defined?(::Rails) && ::Rails.application

        # At after_initialize (when the boot guard runs) the host's routes may not
        # be drawn yet, so recognize_path would see an incomplete set and report a
        # false shadow. Force-load routes first (idempotent — no-op if already
        # loaded), so the check is correct whether it runs at boot or at runtime.
        ensure_routes_loaded
        recognized = ::Rails.application.routes.recognize_path(path, method: :post)
        recognized[:controller] == ACTIONS_CONTROLLER
      rescue ActionController::RoutingError, ActiveRecord::RecordNotFound
        false
      end

      # Log a clear warning (once, at boot) when the action path doesn't resolve
      # to the gem controller — pointing at the catch-all shadow rather than
      # leaving an adopter to guess. Called from the engine's after_initialize.
      def warn_unless_action_route_mounted!(path: action_path, logger: default_logger)
        return if action_route_ok?(path)
        return unless logger

        logger.warn(
          "[phlex-reactive] POST #{path} does not resolve to #{ACTIONS_CONTROLLER}. " \
          "A host catch-all route (e.g. match \"*path\", ...) likely shadows it, so reactive " \
          "actions will 404. Exempt #{path.delete_prefix("/")} from the catch-all, or set " \
          "Phlex::Reactive.action_path to an unshadowed path. See the README integration section."
        )
      end

      private

      # Materialize the route set if it hasn't been drawn yet (the engine appends
      # POST /reactive/actions when routes are drawn, which may be after the boot
      # guard's after_initialize). Idempotent; tolerant of older Rails.
      def ensure_routes_loaded
        reloader = ::Rails.application.routes_reloader
        if reloader.respond_to?(:execute_unless_loaded)
          reloader.execute_unless_loaded
        elsif ::Rails.application.respond_to?(:reload_routes_unless_loaded)
          ::Rails.application.reload_routes_unless_loaded
        end
      end

      def default_logger
        ::Rails.logger if defined?(::Rails) && ::Rails.respond_to?(:logger)
      end

      # Run a reporter (APM adapter or on_action_error hook) so a raise inside it
      # NEVER escapes report_error (issue #207) — the endpoint must re-raise the
      # ORIGINAL action-body error, not a reporter's failure. A broken reporter is
      # warn-logged so it's diagnosable, then swallowed.
      def safely_report
        yield
      rescue => e # rubocop:disable Style/RescueStandardError
        default_logger&.warn("[phlex-reactive] apm/on_action_error reporter raised: #{e.class}: #{e.message}")
      end

      # Walk the upgrader chain from `version` up to TOKEN_VERSION, applying each
      # registered upgrader in turn (issue #111). A gap in the chain (a version
      # bumped with no shape change, so no upgrader registered) is a no-op step —
      # the payload passes through unchanged to the next version. Only stamp the
      # current "v" if an upgrader ACTUALLY reshaped the payload: a versionless
      # (v0) token with no upgraders registered — today's case — is returned
      # byte-identical, so introducing versioning invalidates nothing in flight.
      # Runs only for a genuinely old token (the v == current hot path already
      # returned in upgrade_token), so this is off the render path.
      def upgrade_from(payload, version)
        upgraded = false
        version.upto(TOKEN_VERSION - 1) do
          upgrader = token_upgraders[it]
          next unless upgrader

          payload = upgrader.call(payload)
          upgraded = true
        end
        upgraded ? payload.merge("v" => TOKEN_VERSION) : payload
      end

      def default_verifier
        unless defined?(::Rails) && ::Rails.application
          raise Error, "Phlex::Reactive.verifier is unset and Rails.application is unavailable; " \
                       "set Phlex::Reactive.verifier = ActiveSupport::MessageVerifier.new(secret)"
        end

        ::Rails.application.message_verifier(IDENTITY_PURPOSE)
      end
    end

    self.authorization_errors = []
  end
end

loader = Zeitwerk::Loader.new
loader.tag = "phlex-reactive"
# Root is lib/ so files map to the Phlex::Reactive namespace
# (lib/phlex/reactive/foo.rb -> Phlex::Reactive::Foo).
lib = File.expand_path("..", __dir__)
loader.push_dir(lib)
# js.rb defines JS and component/dsl.rb defines Component::DSL (acronyms), not
# the default-inflected `Js`/`Dsl`. mcp.rb defines MCP (issue #168).
loader.inflector.inflect("js" => "JS", "dsl" => "DSL", "mcp" => "MCP", "apm" => "APM")
# The gem-name shim (`require "phlex-reactive"`) is a plain require, not a
# managed file.
loader.ignore("#{lib}/phlex-reactive.rb")
# version.rb defines VERSION (a constant, not a `Version` class) and is required
# above — Zeitwerk must not try to load it.
loader.ignore("#{lib}/phlex/reactive/version.rb")
# Rails generators are discovered and loaded by Rails' own generator system,
# not the app autoloader. Their path/constant scheme
# (generators/phlex/reactive/... defining Phlex::Reactive::Generators::...)
# deliberately doesn't follow Zeitwerk's rules, so the loader must ignore them.
loader.ignore("#{lib}/generators")
# The RSpec matchers file (issue #110) defines RSpec::Matchers, not a
# Phlex::Reactive::TestHelpers::Matchers constant, so it doesn't follow
# Zeitwerk's naming — test_helpers.rb requires it explicitly (only when RSpec is
# present), and the loader must ignore it.
loader.ignore("#{lib}/phlex/reactive/test_helpers/matchers.rb")
# The system/browser test helpers (issue #201) are Capybara-only — a dev/test
# dependency, never a runtime one. test_helpers.rb requires this file explicitly
# only when Capybara is present, so the loader must ignore it (otherwise an
# eager-load in production would define browser helpers with no Capybara).
loader.ignore("#{lib}/phlex/reactive/test_helpers/system.rb")
# The MCP diagnostic tool tree (issue #168) subclasses the OPTIONAL `mcp` gem's
# constants (MCP::Tool) at class-definition time, so the whole mcp/ subdirectory
# must stay out of the autoloader — Phlex::Reactive::MCP.load! requires it in
# dependency order only when the gem is present. mcp.rb itself (the load! entry
# point) references no gem constant at load time, so Zeitwerk autoloads it
# normally (inflected MCP above); only the gem-dependent subtree is ignored.
loader.ignore("#{lib}/phlex/reactive/mcp")
# The engine is required explicitly below (only when Rails is present) and must
# not be eager-loaded before that.
loader.do_not_eager_load("#{__dir__}/reactive/engine.rb")
# The defer push-lane job subclasses ActiveJob::Base, which is NOT a gem
# dependency — eager-loading it in an app without ActiveJob would raise at
# boot. The constant autoloads on first reference, which only happens behind
# Phlex::Reactive.defer_push_capable? (that gate requires ActiveJob::Base).
loader.do_not_eager_load("#{__dir__}/reactive/deferred_render_job.rb")
loader.setup

require "phlex/reactive/engine" if defined?(Rails::Engine)
