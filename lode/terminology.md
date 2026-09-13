# Terminology

The words this repository uses. Where a word names a constant or method, the definition is the code.

## The round trip

- **reactive component** — a Phlex component that `include Phlex::Reactive::Component`. Gets `Streamable` (id + streams + broadcasts), `ClientBindings` (the declaration DSL + view helpers), `Identity` (the token) and `Lazy` in that order (`component.rb`).
- **client-only component** — `include Phlex::Reactive::ClientBindings` instead: the same DSL and helpers with NO `Streamable` and NO `Identity`, so no `#id` is required and the root is tokenless. The server-action macros (`action`, `reactive_record`, `reactive_state`) raise at class-definition time on one (`Component::DSL#require_server_actions!`).
- **identity token / signed identity** — the `MessageVerifier` payload on the root's `data-reactive-token-value`: `{"c" => class name}` plus `"gid"` (a persisted record's GlobalID) and/or `"s"` (the declared `reactive_state` ivars), stamped `"v" => TOKEN_VERSION`. Built by `Component::Identity#reactive_identity_payload`, signed by `Phlex::Reactive.sign`.
- **draft token** — the same payload with NO `gid`, minted for an unsaved (`persisted? == false`) or nil record. `from_identity` omits the record kwarg so the component's `initialize` default seeds a fresh draft.
- **defer token** — the same payload signed under `DEFER_PURPOSE` with `defer_token_ttl` (120s default). Disjoint from an action token by purpose, so neither can be redeemed at the other's endpoint.
- **defer binding** — the persisted session id folded into a defer token's PURPOSE string (`Phlex::Reactive.defer_purpose`), so a token minted under one actor fails verification under another. Unbound (no persisted session) is a documented, supported state.
- **`act`** — the wire name of the action in the POST body. Not `action`: that is a reserved Rails routing param.
- **default-deny** — only a declared `action` is invokable (server), only an allowlisted op name/attribute runs (client). Both sides enforce independently.

## Replies and streams

- **reply** — `Component::Helpers#reply` returns a `Phlex::Reactive::Reply` bound to the component; each verb builds and returns the frozen `Phlex::Reactive::Response` the endpoint reads. `Reply` is not a `Response` and does not subclass one.
- **`Stream`** — an `ActiveSupport::SafeBuffer` subclass that IS the `<turbo-stream>` bytes but also carries `rx_action`, `rx_target`, `rx_renders_root?` and a `rx_carries_token?` flag computed once from the bytes. The endpoint reads fields instead of regexing markup.
- **token refresh** — the endpoint guarantees the reply carries a fresh token: either a stream that re-renders the root (`Stream::SELF_RENDER_ACTIONS` = replace / update / `reactive:token`) or the tiny inert `to_stream_token` stream.
- **companion** — an element re-rendered alongside the subject: `reply.also(component)` (a replace at its own `#id`) or `reply.also(target => content)` (an inner-HTML update of that id).
- **count companion / empty-state** — the `count:` and `empty:` members of a `reactive_collection`; every row add/remove also refreshes the count and toggles the empty state at the 0↔1 boundary (`Collections`).
- **actor / peer** — the actor is the client that made the request and gets the HTTP reply; peers are every other subscriber of the stream. `exclude: reactive_connection_id` suppresses the actor's own broadcast echo.

## Async

- **defer (`reply.defer`, `reactive_lazy`)** — take a render off the actor's critical path. Two lanes: **pull** (`:fetch` — the client POSTs the defer token to `/reactive/defer`) and **push** (`:stream` — a pgbus durable one-shot stream plus `DeferredRenderJob`). `:auto` picks push iff `defer_push_capable?`.
- **settle (`reply.pending` → `reactive_settle`)** — mark targets pending, let the app's own job report the outcome. Push lane only: a settle has no pull fallback, because the client cannot poll "is the job done yet".
- **handle** — `Pending::Handle`, the JSON-round-trippable record of a settle (shared stream key, container class + identity payload, anchor id, collection, target ids, peers, connection id). It rides ActiveJob metadata via `Settles#serialize`.
- **anchor** — the container component's DOM id: the settle's subscription target and teardown target.
- **one-shot stream key** — a `prdefer_`-prefixed random key sized to pgbus's live queue-name budget; one PGMQ queue per key, reclaimed by pgbus's orphan sweep.

## Client vocabulary

- **op / ops chain** — `Phlex::Reactive::JS`, an immutable builder of declarative DOM commands (17 chainable verbs) serialized to `[[name, args], …]`. Ephemeral UI: any server re-render resets what they toggled.
- **`@root`** — `JS::ROOT_SENTINEL`, "the component's own root element" in an op target.
- **conditions / DNF groups** — the one `if:` / `if_any:` / `unless:` language `ShowConditions` compiles to an array of groups (terms AND within a group, groups OR) and evaluates identically in Ruby and in JS.
- **effect** — an enter/exit/update animation name (`fade`, `slide`, `scale`, `highlight`, `shake`), `:random`, `false`, or custom `{ during:, from:, to: }` legs; opt-in globally, per component and per call.
- **vendored client** — the five files under `spec/dummy/public/vendor/` named in `spec/phlex/vendored_controller_sync_spec.rb`'s map (`reactive_controller.js`, `confirm.js`, `confirm_predicate.js`, `compute.js`, `inspect.js`), each byte-identical to the built `*.min.js` so the browser suite exercises the minified code production ships. The rest of that directory (stimulus, turbo, trix, lexxy, the dummy's own reducers) is vendored third-party or hand-written and no guard covers it.
