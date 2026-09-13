# Core and configuration

`lib/phlex/reactive.rb` (the `Phlex::Reactive` singleton) plus `lib/phlex/reactive/engine.rb`. Everything the rest of the gem reads for configuration, identity signing, capability detection and per-request state lives here.

## Boot

`lib/phlex-reactive.rb` is the gem-name shim; `lib/phlex/reactive.rb` is the real entry. It `require_relative`s `reactive/version` up front (the file defines `VERSION`, a constant, not a `Version` class) and then sets up a Zeitwerk loader rooted at `lib/`. The loader keeps eight paths out of its normal handling — six `loader.ignore` calls and two `loader.do_not_eager_load`s — each commented in place:

| Path | Why it is ignored / not eager-loaded |
|---|---|
| `lib/phlex-reactive.rb` | the plain-require gem-name shim |
| `lib/phlex/reactive/version.rb` | defines `VERSION`, not `Version` — `eager_load_all` would raise `Zeitwerk::NameError` |
| `lib/generators` | Rails' generator system owns discovery; the path/constant scheme is deliberately non-Zeitwerk |
| `test_helpers/matchers.rb`, `test_helpers/system.rb` | define `RSpec::Matchers` / need Capybara; `test_helpers.rb` requires each only when the dependency is present |
| `mcp/` | the subtree subclasses the OPTIONAL `mcp` gem's constants at class-definition time; `MCP.load!` requires it in dependency order |
| `engine.rb`, `deferred_render_job.rb` | `do_not_eager_load` — the engine is required only when `Rails::Engine` is defined; the job subclasses `ActiveJob::Base`, which is not a dependency |

Inflections: `js` → `JS`, `dsl` → `DSL`, `mcp` → `MCP`, `apm` → `APM`.

`Engine` (`isolate_namespace Phlex::Reactive`) then does five things: appends `POST action_path` → `actions#create` and `POST defer_path` → `actions#deferred`; adds `app/javascript` and `app/assets/stylesheets` to the asset paths and precompiles the five `*.min.js` + maps + `effects.css`; pins those five modules into an importmap app (only `inspect` with `preload: false` — it is a console-loaded debugging tool); resets the memoized view contexts on every `to_prepare`; and, in `after_initialize`, warns about a shadowed route, attaches the `LogSubscriber` when `log_events`, attaches the APM adapter when `apm` is set, and freezes both the param-type and named-schema registries.

## Identity tokens

`sign`/`verify` are the single choke points. `sign` merges `"v" => TOKEN_VERSION` (currently 1) and generates under `IDENTITY_PURPOSE`; `verify` verifies and then runs `upgrade_token` so an older payload is migrated before `from_identity` sees it. `upgrade_token`'s contract is the interesting part:

- no `"v"` → version 0, the pre-versioning shape. With no upgrader registered this is a pure passthrough, so introducing versioning invalidated nothing in flight.
- `v == TOKEN_VERSION` → returned as-is (the hot path: one integer compare).
- `v > TOKEN_VERSION` → **nil**, so a rolled-back deploy fails closed through the endpoint's `|| raise(InvalidToken)` → 400 rather than guessing a newer shape.
- a non-Integer or negative `"v"` → nil for the same reason.

`register_token_upgrader(from_version)` fills a sparse `from_version => callable` map; `upgrade_from` walks it and only re-stamps `"v"` when an upgrader actually reshaped the payload.

Defer tokens are a second family: `sign_defer` / `verify_defer` under `DEFER_PURPOSE` with `defer_token_ttl` (120s). The purposes are disjoint BY SIGNATURE, so an action token posted to the defer endpoint fails and a defer token can never invoke an action. `defer_purpose` additionally folds the current actor's binding into the purpose string, so a leaked `reply.defer` token cannot be exchanged by another actor for a fresh, non-expiring action token. `defer_binding_for(request)` returns the id of an ALREADY-PERSISTED session (`session.respond_to?(:exists?) && session.exists?` — a bare `session.id` lazily generates an id that is never persisted, so two requests for the same read-only page would disagree) and degrades to nil on any store error. `sign_defer(unbound: true)` is the `reactive_lazy` case: a lazy shell renders during the page render, before a session exists.

## Configuration surface

Writers with lazy defaults. Six readers guard with `defined?(@x)` rather than `||=` — `verbose_errors`, `log_events`, `debug`, `verify_authorized`, `authorization_methods` and `effects` — because their defaults are truthy or their false value is meaningful, so an explicit `= false` (or a narrower list) has to stick. Every other reader is a plain `@x ||= default`, which is safe only because none of those defaults is `false` or `nil`:

| Setting | Default | Notes |
|---|---|---|
| `verifier` | `Rails.application.message_verifier(IDENTITY_PURPOSE)` | raises a guided error outside Rails |
| `renderer` | `ActionController::Base` when it is defined, else nil | the controller a view context is built from |
| `base_controller_name` | `"ActionController::Base"` | String, resolved lazily by `base_controller` |
| `action_path` / `defer_path` | `/reactive/actions` / `/reactive/defer` | read before boot by the engine's route append |
| `authorization_errors` | `[]` | rendered as 403 by both endpoints |
| `verbose_errors` | `Rails.env.local?` | diagnostic bodies + dropped-param logging + render-time `on(:typo)` + the client's zero-target op warning |
| `verify_authorized` | `true` | default-ON; see `endpoint/summary.md` |
| `authorization_methods` | `%i[authorize! authorize allowed_to?]` | what the interceptor wraps |
| `debug` | `false` | stamps `data-reactive-debug` so the client console-groups each dispatch |
| `log_events` | `false` | the gem's own log lines; the events fire for APMs regardless |
| `apm` | `nil` | Symbol, custom adapter object, or nil |
| `effects` | `nil` (off) | normalized and validated at WRITE time; bumps `effects_generation` |
| `error_flash` | `nil` | `->(kind) { message }`; renders a flash on every endpoint rescue path |
| `flash_component` | `nil` | a CALLABLE `(level, content)`; a bare Class raises with the lambda rewrite |
| `flash_target` | `"flash"` | the container `Response#flash` appends into |
| `defer_transport` | `:auto` | validated at assignment against `DEFER_TRANSPORTS` |
| `defer_token_ttl` / `defer_job_queue` | `120` / `"default"` | |
| `settle_coalesce_window_ms` | `50` | applies to a settle's AGGREGATE peer streams only |

There is deliberately **no `settle_token_ttl`** — see `../review/async-actions.md`.

Registries frozen by the engine's `after_initialize`, so registration is initializer-only: `param_type(name) { }` (custom coercions, returning `ParamSchema::DROP` to reject) and `param_schema(name, hash)` (reusable named schemas, deep-frozen so a nested schema cannot be mutated through the memoized reader). `reset_param_types!` / `reset_param_schemas!` exist for tests.

Hooks, each with a `reset_*!` for test isolation: `around_action` (folded by the endpoint so the LAST registered runs outermost) and `on_action_error`.

## Capability gates

```
pgbus?              defined?(::Pgbus) && ::Pgbus.respond_to?(:stream)          # necessary, NOT sufficient
pgbus_streams?      + Pgbus::Streams::Stream#broadcast takes :exclude          # the >= 0.9.2 probe
defer_push_capable? + Pgbus::Streams::SignedName.respond_to?(:sign) + ActiveJob::Base
settle_capable?     defer_push_capable? && defer_transport != :fetch
```

`pgbus_streams?` is the gate that prevents `ArgumentError: unknown keyword :exclude` on an old pgbus, and it probes the actual keyword because pgbus < 0.9.2 also defines `::Pgbus`.

## Rendering off-request

`request_bound_view_context(controller_class)` replicates what `ActionController::Renderer#render` does to build its mock request — an `ActionDispatch::Request` from the renderer's env, routes bound, `set_request!` + `set_response!` — then returns the controller's `view_context` instead of rendering a template. That is what makes `form_authenticity_token`, `protect_against_forgery?` and host-aware URL helpers work off-request. The instance's singleton `url_options` merges `Phlex::Reactive.current_url_options` over its memo, so a reply renders absolute URLs for the REQUESTING host while an off-request caller (job, console, broadcast) gets the frozen memo untouched.

`off_request_view_context` and `stream_builder` come from one per-thread cache keyed on `renderer.equal?` plus `off_request_view_context_generation`; `reset_stream_builder!` bumps the generation for all threads. `flash_builder` / `reset_flash_builder!` are gone and raise a `NoMethodError` naming the replacement.

`Phlex::Reactive.broadcast_to` is the module-level twin of the class-level form for a BUILT, possibly non-Streamable payload; both share `Streamable.broadcast_component`.

## Route guard

`action_route_ok?` force-loads the route set (it may run before the host's routes are drawn) and asks `recognize_path(path, method: :post)` whether it reaches `"phlex/reactive/actions"`. A host catch-all appended above the engine's route shadows it and every reactive POST 404s with nothing to see; `warn_unless_action_route_mounted!` turns that into one boot-time log line naming the catch-all.

## Instrumentation

`instrument(event, payload, &)` wraps `ActiveSupport::Notifications.instrument("#{event}.phlex_reactive", …)`, yielding the mutable payload so a rescue can finalize `:outcome`. Four events: `action`, `defer`, `render`, `broadcast`. **Payloads carry names, outcome and sizes only — never the token, params or state.** `report_error(error, context)` forwards a fresh `context.slice(*ERROR_CONTEXT_KEYS)` (`:component, :action, :outcome`) to the resolved APM adapter and every `on_action_error` hook, each wrapped in `safely_report` so a broken reporter can never replace the original 500.
