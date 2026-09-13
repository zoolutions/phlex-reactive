# The endpoint: ActionsController, Response, Stream, Authorization

`app/controllers/phlex/reactive/actions_controller.rb` (the only controller in the gem), `response.rb`, `reply.rb`, `stream.rb`, `authorization.rb`.

It inherits from `Phlex::Reactive.base_controller` — `ActionController::Base` by default, an app's `ApplicationController` when the app wants its auth/CSRF/Current. `wrap_parameters false`: the JSON body's keys collide with Rails' reserved routing params, which is also why the action travels as `act`.

## `#create` — the action round trip

```
with_url_options(url_options_for(request))      # the ACTOR's protocol/host/port
  with_defer_binding(defer_binding_for(request))  # so reply.defer tokens are actor-bound
    instrument("action", event)                   # ONE event, outcome set on every exit path
      create_action(event)
```

`create_action` in order: `verified_payload` (`verify` or raise `InvalidToken`) → `resolve_component` (must `safe_constantize` AND include `Phlex::Reactive::Component`; the two failures carry distinct diagnostics) → look the action up in the FROZEN `reactive_actions` hash, and 403 when absent (default-deny) → `from_identity` → `coerce_params` → instrument the class for `verify_authorized` → `run_action` → `render turbo_stream: response_streams(result, component)`.

`run_action` nests deliberately:

```
with_connection_id(request.headers["X-Pgbus-Connection"])   # so a broadcast in the action can exclude the actor's echo
  with_around_actions(...)                                   # OUTSIDE the transaction: a rejection never opens one
    transaction_wrapper                                      # ActiveRecord::Base.transaction when AR is defined
      Authorization.with_tracking                            # open the window
        component.public_send(action, **coerced)
        Authorization.verify!                                # INSIDE the transaction: unverified rolls back
```

`with_around_actions` short-circuits with a bare `yield` on an empty stack (one `Array#empty?` check on the default request). Otherwise it builds a frozen `ActionContext(component, action_name, params, request)` — with a `coerced.dup.freeze`, because the same hash is splatted into the action and a wrapper mutating it would defeat the schema-coercion guarantee — and folds the stack so the FIRST-registered wraps the action and the LAST-registered runs outermost. **Every wrapper must return `action.call`'s value**; one that returns its logger's result instead silently downgrades the reply to the implicit self-replace.

### Error paths

Rescue order is load-bearing; each sets `event[:outcome]` first.

| Raised | Outcome | HTTP |
|---|---|---|
| `AuthorizationNotVerified` | `:unverified` | tagged, then **re-raised** — a developer error, so a 500 an error tracker sees |
| `InvalidToken` | `:invalid_token` | 400; `event[:component]` stays nil (the name came from an unverified token) |
| `ActiveRecord::RecordNotFound` | `:not_found` | 404 |
| a registered `authorization_errors` class | `:unauthorized` | 403 |
| anything else | `:error` | observed by `report_action_error`, then **re-raised unchanged** |

`report_action_error` tags the outcome, calls `Phlex::Reactive.report_error`, and renders the `error_flash` at `:internal_server_error` so the actor sees a flash for a crash — every step guarded so the observation path can never replace the error the caller is about to re-raise.

`reactive_error(status, message, kind:)` never changes the STATUS with any flag, only the body: an `error_flash` turbo-stream wins, else the `verbose_errors` plain-text diagnostic, else a bare `head`. The warn log fires in every environment first, so a misbehaving client is debuggable from the server log alone. `error_flash_stream` degrades to nil when the configured lambda raises, so one failure never becomes a 500.

### Params

`coerce_params` builds the collector only under `verbose_errors`, peels one `reactive_scope` level via `unwrap_scope` (only when the component declares a scope AND the raw params carry that single key mapping to a nested params/hash), and coerces through the action's compiled schema. `log_dropped_params` emits ONE warn line naming every dropped key with a reason, and `shape_hint` adds the `#16`/`#21` hint when a dropped segment matches a declared key at a different nesting level — searching exactly one level, hash or array-of-hash.

## `#deferred` — the pull lane's render leg

Same `with_url_options` / `with_defer_binding` wrapper, instrumenting `defer`. It verifies the purpose-scoped, short-TTL defer token (an action token is rejected BY SIGNATURE), rebuilds the component, and returns `to_stream_replace(morph: payload["m"] == "morph")` — the morph mode rides inside the SIGNED payload so the client cannot flip it. **No action runs and no transaction opens: this is a read.** A component that answers `render? == false` gets a 204 (keep content, clear pending). The rescue chain mirrors `create_action`'s minus the `AuthorizationNotVerified` clause (no action runs, so nothing can be unverified) and minus the action name in its messages.

## Token-refresh guards

The client reads its next signed token out of the response body, so the endpoint's real invariant is "a fresh `data-reactive-token-value` is present", not "some stream targets self". `response_streams` enforces it in two guards:

- **Guard 1 (target-scoped)** — `carries_token_for?`: does one of the streams already refresh THIS component's token by re-rendering its own root? A `Stream` answers structurally via `rx_refreshes_token_for?` (carries a token AND renders the root AND same target AND a `SELF_RENDER_ACTIONS` action); a raw string falls back to the legacy opening-tag regex. A sibling's replace targets a different id and does not count; an appended child row carries its OWN token but does not render the container's root, so the container still refreshes (without this the list was add-once-only).
- **Guard 2 (global)** — for a `render_self?` reply: does ANY stream carry a token? Deliberately un-scoped, because scoping it would regress update/morph of self on an aliased id. When none does, a reply with a `subject_component` gets a full self-replace prepended, and a companion-only `reply.with` gets a token-ONLY refresh appended instead — so a live input is never clobbered by a forced replace.

Deferred and pending segments are appended LAST, after every render and op stream, because Turbo applies in document order and because this runs after `run_action` returned — i.e. after the transaction COMMITTED, so a rolled-back action can never leak a directive or a pending marker.

A redirect is `<turbo-stream action="reactive:visit" data-url="…">` at 200, NOT an HTTP 3xx — the client hard-bails on `response.redirected`, which still correctly catches real auth/CSRF redirects.

## `Stream`

An `ActiveSupport::SafeBuffer` subclass carrying `rx_action`, `rx_target`, `rx_renders_root?` and `rx_carries_token?`. The subclassing is verified against actionpack/turbo-rails behaviour: `render turbo_stream: [s1, s2]` only ever does `plain_string << s`, which needs `#to_str`, so the bytes on the wire are byte-identical to raw TagBuilder output.

`rx_carries_token?` is ONE `include?(TOKEN_ATTR)` scan at BUILD time — **ground truth from the bytes, never inferred from the action**. `renders_root` is set structurally by the builder that knows its own semantics; `append`/`prepend` set it false because they insert children.

Metadata loss is a feature: `dup`/`+` keep the class and ivars; `gsub`, interpolation and `*` return a plain String, which is exactly when the object is no longer a structurally-known stream — and the endpoint's `is_a?(Stream) && rx_action` guard routes every such loss to the safe legacy regex path. **Never `+`/`gsub`/`<<` a built `Stream` and keep using it as one; re-`wrap` the result.**

## `Response` and `Reply`

`Response` is an immutable, frozen value object; every chainable verb returns a NEW one. `Reply` (from `Component::Helpers#reply`) is NOT a Response and does not subclass one — each verb calls a `Response.build_*` class method with the bound component as the subject and returns the real Response. The ten former public `Response.<verb>` class methods raise a guided rewrite naming `reply.<verb>`.

Three component slots explain the endpoint's behaviour:

- `subject_component` — set by `replace`/`morph`/`update`; the component a self-targeting builder re-rendered. It does NOT trip `refresh_token?`; it exists so `#js`'s target defaults to the bound root.
- `token_component` — set by `streams`, the collection verbs and `pending`; a reply that does NOT re-render self but still needs its token rolled forward. Without it a collection is add-once-only.
- `render_self?` — false for `remove`, `redirect`, the collection verbs, `streams` and `pending`.

Verbs: `replace`/`morph`/`update` (self), `remove` (bare = self; with `from:` = a collection row), `append`/`prepend` (`to:` required), `redirect(url)`, `with(*strings)`, `streams(*strings)`, `defer`, `pending`. Chainables: `.stream`, `.flash`, `.also`, `.js`, `.defer`, `.pending`. `reply.also` dispatches on ARGUMENT TYPE — a Streamable component is a replace at its own `#id`, `target => content` pairs are inner-HTML updates — and refuses both forms in one call or neither.

Content resolution is one contract everywhere (`render_html`): a Phlex component renders through the configured renderer (auto-escaped); anything else is `to_s`'d and handed to Turbo's TagBuilder, which escapes a plain String and passes an `html_safe` one verbatim. `js_ops_json` rejects an empty chain (a dead `reactive:js` stream) and re-applies the attribute allowlist to a raw list.

## `Authorization`

`verify_authorized` is default-ON. `instrument!(component_class)` prepends a module wrapping every configured `authorization_methods` name the class defines (public or private, own or inherited) with `super` then `mark!` — so a DENIAL, which raises, never marks and still propagates to the 403 path. It is idempotent per class OBJECT via an ivar, so a Zeitwerk reload re-instruments naturally. `Module#prepend` is bound explicitly through `MODULE_PREPEND` because `Streamable` defines a class method `prepend(target:, model:)` that shadows it.

`with_tracking` opens a fresh window that starts UNMARKED regardless of an outer mark. `verify!` is a no-op when the feature is off, when the action or whole component declares `skip_verify_authorized`, or when anything marked; otherwise it raises `AuthorizationNotVerified` naming the component#action and all three remedies. `mark_authorized!` (a component helper) always counts.

Related: `../component/summary.md`, `../streaming/summary.md`, `../async-and-defer/summary.md`.
