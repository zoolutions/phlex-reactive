# phlex-reactive

Reactive [Phlex](https://www.phlex.fun) components for Rails — Livewire-style
actions and live cross-tab updates, without writing Stimulus controllers or
hand-picking Turbo Stream targets.

## Tech Stack

- **Ruby**: >= 3.4 | **Rails**: >= 7.1
- **Rendering**: phlex-rails (Phlex 2)
- **Transport**: turbo-rails (Turbo Streams); [pgbus](https://github.com/zoolutions/pgbus) optional for Postgres SSE
- **Client**: one generic Stimulus controller (no per-feature JS)
- **Autoloading**: zeitwerk
- **Testing**: RSpec + Capybara/Playwright (via `spec/dummy`)
- **Linting**: RuboCop (`rubocop`) — all new cops on; teaches modern Ruby (e.g. `it` block param)

## Critical Rules

### Never Do
1. **NO hand-picked Turbo Stream targets** — a component self-targets via its stable `#id`
2. **NO shipping component STATE to the client** — the DOM carries a *signed identity* (`{c, gid}` or `{c, state}`), never raw state
3. **NO trusting client input for authorization** — the signature proves the token is ours, NOT that this user may act; authorize inside the action
4. **NO undeclared actions** — only methods declared with `action :name` are invokable (default-deny)
5. **NO raw mass assignment** — action params pass through the declared schema (`params: { x: :integer }`)
6. **NO hard dependency on pgbus** — broadcasts route through `Turbo::StreamsChannel`; phlex-reactive must work on Action Cable OR pgbus
7. **NO `dom_id` (Phlex render-time helper) inside `#id`** — `#id` runs before render; use `Streamable#dom_id` (delegates to `ActionView::RecordIdentifier`)
8. **NO bare `**on(...)` merged with another `data:`/`class:`** — use Phlex `mix(on(:x), data: {...})` or the extra hash clobbers `on`'s `data:`

### Always Do
1. **TDD**: Write tests BEFORE implementation (RED → GREEN → REFACTOR)
2. **Authorize every mutating action** — `authorize! @record, :update?` (register the error in `Phlex::Reactive.authorization_errors`)
3. **Declare a param schema** for any action that takes input
4. **Re-render through a real view context** — go through `Phlex::Reactive.renderer` / the controller, never a fabricated context (dom_id/url_for/t()/csrf must work)
5. **Capability-detect pgbus features at runtime** — probe the actual keyword (`broadcast.parameters` includes `:exclude`), never `defined?(Pgbus)` alone or a version string
6. **Degrade gracefully** — every pgbus-only feature must no-op or fall back when pgbus is absent
7. **Control the reply via the return value** — return a `Phlex::Reactive::Response` (`replace`/`update`/`remove`/`redirect`/`with`, chain `.flash(level, content)` / `.stream(...)`) to govern the actor's HTTP reply; returning anything else keeps the implicit single replace. See the README "Controlling the action's reply" section and `lib/phlex/reactive/response.rb`.
8. **Measure performance, don't guess** — any hot-path change (render, token signing, param coercion, broadcast, client dispatch) ships with a same-machine before/after from `rake bench` (or `/perf`). No speedup claim without a measured baseline. Report throughput AND allocations; distinguish a method-level win from a request-level one. See `.claude/rules/performance.md` and the performance page (`docs/app/views/docs/pages/performance.rb`).

## Commands

```bash
bundle exec rspec spec/phlex spec/requests   # Fast suite (unit + request + broadcast)
bundle exec rspec spec/system                # Browser suite (Playwright; Puma default, CAPYBARA_SERVER=falcon for the async server)
bundle exec rake spec:system_servers         # Browser suite under BOTH real servers (puma + falcon)
bundle exec rubocop                          # Lint (rubocop -A to autocorrect)
bundle exec rake                             # spec + rubocop
bundle exec rake bench                        # Performance micro-benches (render, token, coerce_params)
bundle exec rake bench:request                # End-to-end request-cycle bench (derailed)
rake build:js                                 # Rebuild the minified client (.min.js + .map) after editing reactive_controller.js
rake build:js_check                           # CI drift guard: committed .min.js must match a fresh build
bin/release [patch|minor|major|X.Y.Z] [-n]    # Cut a release (list / --dry-run are read-only); drives rake release
```

### Editing the client runtime (`reactive_controller.js` / `confirm.js` / `compute.js` / `inspect.js`)

The gem ships the **minified** build, and the browser suite runs that same
minified build (the dummy vendors it). So a source edit is a THREE-file change:

```bash
rake build:js                                 # regenerate the .min.js + .map from source
cp app/javascript/phlex/reactive/reactive_controller.min.js \
   spec/dummy/public/vendor/reactive_controller.js   # re-sync the vendored copy (same for confirm/compute/inspect)
bun test spec/javascript                      # JS unit suite
```

Commit the source, the rebuilt `.min.js`/`.map`, AND the re-synced vendored copy
together. Two guards enforce it: `rake build:js_check` (committed min build matches
a fresh build) and `spec/phlex/vendored_controller_sync_spec.rb` (vendored copy is
byte-identical to the shipped `.min.js`). Its failure message prints the exact
re-sync command.

## Slash Commands

| Command | Purpose |
|---------|---------|
| `/plan` | Fable-powered planning → GitHub issue or `docs/plans/` markdown (read-only; execute with `/lfg`) |
| `/lfg` | Full autonomous workflow: branch → understand → explore → plan → TDD → verify → PR |
| `/tdd` | Enforce RED → GREEN → REFACTOR |
| `/perf` | Benchmark the branch vs main (same-machine before/after) and keep perf docs in sync |
| `/architect` | Coordinate a change across the component → endpoint → client layers |
| `/security` | Security audit (signed identity, default-deny, params, CSRF, connection-id) |
| `/review-pr` | Review a PR for pattern compliance |
| `/github-review-pr` | Full PR pass: fix CI failures, then resolve review comments (in that order) |
| `/github-review-failures` | Fix failing CI checks until green |
| `/github-review-comments` | Process unresolved PR review comments |

Commands pin a model tier via frontmatter aliases: `haiku` for mechanical/config
work, `sonnet` for the prescriptive pattern-following passes (`/github-review-comments`,
`/github-review-failures`), `opus` for orchestration, security, review synthesis,
and the reasoning-heavy specialists (`/lfg`, `/architect`, `/security`, `/review-pr`,
`/github-review-pr`, `/tdd`, `/perf`). Fable is pinned only on `/plan` — read-only
planning that hands execution to cheaper models; otherwise choose it per-session
with `/model` for architecture and the hardest debugging. Use the tier alias,
never a full model ID, so commands track the latest model in each tier. When
spawning subagents for mechanical work (file finding, pattern scans), pass a
cheaper model explicitly rather than letting them inherit the session model.

## Architecture

```
Layer 4: Client runtime    app/javascript/phlex/reactive/reactive_controller.js (ONE generic Stimulus controller)
Layer 3: Endpoint          app/controllers/phlex/reactive/actions_controller.rb (verify token → run action → render the returned Response, else re-render)
Layer 2: Component mixin    lib/phlex/reactive/component.rb (reactive_record/reactive_state, action, reactive_attrs, on)
Layer 1: Streamable mixin   lib/phlex/reactive/streamable.rb (#id, replace/append/..., broadcast_*_to, to_stream_replace, to_stream_remove)
Layer 1: Response           lib/phlex/reactive/response.rb (replace/update/remove/redirect/with, flash, stream)
Layer 0: Core + config      lib/phlex/reactive.rb (verifier, renderer, base_controller_name, authorization_errors, action_path, flash_target)
         Engine             lib/phlex/reactive/engine.rb (mounts the endpoint, pins the client controller)
```

## The mental model

> A component owns a stable DOM `id`. Everything — a click, a form change, a
> background broadcast — reduces to **"render this component into that id."**

Client interactivity (`Component`) and server-pushed live updates (`Streamable`)
converge on ONE re-render unit. See `docs/architecture.md`.

## Security model

- **Signed identity, not state**: the DOM holds a `MessageVerifier`-signed
  `{c, gid}` (record-backed) or `{c, state}` (state-backed). Tampering the class,
  record, or state fails verification → 400.
- **Default-deny actions**: only `action :name` methods run; 403 otherwise.
- **You authorize**: the signature is not authorization. Call your authorizer in
  the action; register its exception in `Phlex::Reactive.authorization_errors`.
- **Schema-coerced params**: only declared params reach the method, each cast.
- **CSRF + auth** come from `Phlex::Reactive.base_controller_name`.
- See `docs/security.md` for the full threat model + checklist.

## pgbus: optional transport, runtime-detected

phlex-reactive does **not** depend on pgbus in the gemspec. Broadcasts go through
`Turbo::StreamsChannel`, which pgbus patches to route over Postgres SSE. pgbus
0.9.2+ adds reactive Streams primitives (`exclude:`, `broadcast_render`, typed
`event:`, `coalesce:`, auto-presence, `msg_id`). phlex-reactive adopts them via a
**runtime capability gate**, not a dependency:

```ruby
# Necessary but NOT sufficient — pgbus < 0.9.2 also defines ::Pgbus.
Phlex::Reactive.pgbus?         # defined?(::Pgbus) && ::Pgbus.respond_to?(:stream)
# The gate that prevents `ArgumentError: unknown keyword :exclude` on old pgbus:
Phlex::Reactive.pgbus_streams? # capability probe: broadcast.parameters includes :exclude
```

Branch on `pgbus_streams?`. With pgbus absent or too old, fall back to the plain
`Turbo::StreamsChannel` path (today's behavior). The Action-Cable-or-pgbus
optionality is a core invariant — never break it.

## Testing

- `spec/dummy/` is a minimal Rails app (models + example components) that the
  request and system specs drive.
- Unit specs mock/avoid the DB; request specs boot the dummy; system specs use
  Capybara + Playwright. The browser suite runs under two REAL servers — Puma
  (default) and Falcon (`CAPYBARA_SERVER=falcon`); CI runs both in a matrix, and
  `rake spec:system_servers` runs both locally. (No webrick — not a real server.)
- pgbus-dependent specs run only on Ruby ≥ 3.3 (pgbus's floor) and guard with
  `defined?(Pgbus)`. phlex-reactive's own runtime floor is Ruby 3.4.
- See `docs/testing.md`.

## Performance

phlex-reactive is benchmarked, not assumed. The hot paths are the re-render
(`render_component` → phlex-rails `render_in` against a memoized view context),
token signing (`reactive_token`), and param coercion. Key facts:

- **Render goes through `render_in`, not `renderer.render`** — ~2× faster, ~half
  the allocations, byte-identical HTML. The off-request view context + Turbo
  `TagBuilder` are memoized per class and reset on Rails code reload
  (`config.to_prepare`).
- **The render win matters most for broadcasts** (no HTTP to amortize against).
  A broadcast call renders ONCE and all subscribers of that stream share the
  payload; the cost is per CALL — N-key fan-out = N renders (per-viewer
  `visible_to:` content is the irreducible render-per-viewer case). At the
  full-request level the Rails stack + DB dominate — don't expect a render
  optimization to move request throughput.
- **Measure before you change.** `rake bench` (micro) and `rake bench:request`
  (end-to-end); `/perf` captures a same-machine before/after against `main`. The
  CI `bench` job is run-and-report (artifact), never a hard fail.
- **Cache correctness:** key any hot-path memo on what can change (renderer
  identity), reset on reload, never cache values that rotate (CSRF token, pgbus
  connection id are read live).
- See the performance page (`docs/app/views/docs/pages/performance.rb`) and
  `.claude/rules/performance.md`.

## More Documentation

See `.claude/` and `docs/`:
- `.claude/commands/` — slash command definitions
- `.claude/rules/` — coding style, git workflow, testing, performance, agents
- `docs/` — published site (architecture, security, broadcasting, transport-pgbus, testing, performance, examples)
