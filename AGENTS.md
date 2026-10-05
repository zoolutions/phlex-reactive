# phlex-reactive

Project instructions for every agent: Claude Code (`CLAUDE.md` imports this file), Grok, Cursor,
Copilot, Codex read it directly. Claude-only extras (commands, rules) live under `.claude/`.

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
rake build:js                                 # Rebuild the minified client (.min.js + .map) after editing core.js or a feature
rake build:js_check                           # CI drift guard: committed .min.js must match a fresh build
bin/release [patch|minor|major|X.Y.Z] [-n]    # Cut a release (list / --dry-run are read-only); drives rake release
```

Command output is condensed by rtk (PreToolUse hook). It already rewrites `bundle exec rspec`,
`bundle exec rubocop`, `bun test`, and `bun run` on its own; `.rtk/filters.toml` extends it to
`rake bench` / `rake bench:*` (the noisy version banner + warmup/calculating separators). Every
edit to it needs `rtk trust --yes` + `rtk verify`. Write commands in hook-rewritable shapes: no
`for`/subshell wrappers, no `| head` on rtk-handled commands, `bundle exec rubocop` not `bin/rubocop`.

### Editing the client runtime (`core.js` / `features/*.js` / `confirm.js` / `compute.js` / `inspect.js`)

The client's source is a **core** (`core.js`: the controller) plus **feature
modules** (`features/<name>.js`), and it ships as TWO entries (issue #275):

| Entry | Built from | What it is |
|---|---|---|
| `phlex/reactive/reactive_controller` | `reactive_controller.js`, a few lines that import the core and every feature and register them | the DEFAULT: one bundled file, nothing fetched on demand, features connect inside `connect()` |
| `phlex/reactive/core` | `core.js` alone | opt-in: imports a feature when a root on the page needs it |

Behaviour goes in `core.js` or a feature, never in `reactive_controller.js`.
The JS suite and the browser suite run on the default entry; the opt-in path
has its own tests (the cold reset seam in JS, `rake spec:system_split` in the
browser).

The gem ships the **minified** build, and the browser suite runs that same
minified build (the dummy vendors it). So a source edit is a THREE-file change:

```bash
rake build:js                                 # regenerate every .min.js + .map from source
cp app/javascript/phlex/reactive/reactive_controller.min.js \
   spec/dummy/public/vendor/reactive_controller.js   # re-sync the vendored copies: the default bundle,
cp app/javascript/phlex/reactive/core.min.js \
   spec/dummy/public/vendor/core.js                  # the core, and features/<name>.js (same for confirm/compute/inspect)
bun test spec/javascript                      # JS unit suite
bundle exec rake spec:system_split            # the browser specs that matter on the split client
```

An edit to `core.js` or a feature changes BOTH `reactive_controller.min.js`
(the bundle) and its own file. A NEW feature is named in five places that must
agree — `ENTRIES` in `scripts/build_client.js`, `CLIENT_FEATURES` in
`lib/phlex/reactive/engine.rb`, the core's feature table (a literal
`import()`), the default entry's imports and `registerReactiveFeature` calls,
and a ceiling in `spec/javascript/bundle_budget.test.js` — plus a pin in each
dummy layout's import map. `spec/phlex/engine_client_pin_spec.rb` (the lists
and the layouts) and the budget test (the ceilings) fail when they don't.

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

**Models.** Sessions run on `opus` (Opus 5.5) with `fable` (Fable 5.1) as the advisor (`.claude/settings.json`). Fable is spent where judgment matters most: `/plan` runs on Fable, the advisor is consulted at decision points (before choosing an approach, a schema or public API, a migration, a dependency, anything irreversible, and when a failure repeats), and the `fable-validator` agent checks every finished implementation before its pull request opens (`/lfg`, Phase 6.5). Commands pin their tier by alias, never by full model ID: `opus` for orchestration, security, full PR review and the reasoning-heavy specialists (`/lfg`, `/architect`, `/security`, `/review-pr`, `/github-review-pr`, `/tdd`, `/perf`); `sonnet` for the prescriptive pattern-following passes (`/github-review-comments`, `/github-review-failures`); `haiku` for mechanical scans. Every spawned agent names its `model:`; one that does not runs on `sonnet` (`CLAUDE_CODE_SUBAGENT_MODEL`), never on the session's model. Plan mode cannot take a model of its own: it runs on Opus and asks the advisor.

## Architecture

```
Layer 4: Client runtime    app/javascript/phlex/reactive/core.js + features/*.js (ONE generic Stimulus controller; shipped bundled as reactive_controller, or split as core)
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

## Screenshots on PRs and issues (always)

`gh` ≥ 2.99 uploads images and videos itself. A change to the docs site
(`docs/`) or a demo/example component ships with before/after pictures **on the
PR**, attached from the terminal. Never a local path, a base64 blob, or
"screenshot available on request".

```bash
gh pr create --attach './after.png#Sidebar collapsed on mobile' --title … --body …   # picture in hand already
gh pr comment <n> --attach './after.png#Sidebar collapsed on mobile' --body 'Before/after for the docs page.'
gh pr comment <n> --attach ./before.png --attach ./after.png   # repeat the flag, up to 50 files
gh issue comment <n> --attach ./repro.mp4                       # video renders as a player
```

- Quote the whole argument: the alt text has spaces and bare `<`/`>` would redirect. `<file>#<alt text>`
  sets the alt text; without it the filename is used. A body that already
  references the file (`![alt](./after.png)`) gets that reference rewritten to the uploaded
  asset, so images can sit inline; unreferenced attachments are appended at the end.
- `create`, `edit` and `comment` all take `--attach` (all three landed in gh 2.99). Attach at create time when
  the picture already exists; comment when it comes later, as it does after a verification run.
- rtk condenses the reply to `ok commented #<n>`; the comment URL is
  `gh pr view <n> --json comments --jq '.comments[-1].url'`.
- Capture with `agent-browser screenshot <file>` against the dummy app (`bin/dev` in `docs/`,
  or `spec/dummy`) or the Playwright MCP `browser_take_screenshot`. Save under the scratchpad,
  never in the repo.
- No `--attach` flag means an old `gh`: `brew upgrade gh`.

## Labels

Every pull request carries exactly one `type` label and at least one `area`
label from `.github/labels.yml` — never a `status` label. `/plan` labels the
issue, `/lfg` copies the issue's `type` and `area` labels onto the PR (never
`plan` or another status label). Without an issue, the type comes from the
change's conventional-commit prefix and the areas from
`bin/labels infer $(git diff --name-only origin/main...HEAD)`. Labels change in
the manifest and reach GitHub with `bin/labels sync`, never through the UI.
Rules: `.github/LABELS.md`. `bin/labels` + `.github/LABELS.md` are the shared
labels kit (canonical copy in docs-kit): never edit them in place.

## More Documentation

See `.claude/` and `docs/`:
- `.claude/commands/` — slash command definitions
- `.claude/rules/` — coding style, git workflow, testing, performance, agents
- `docs/` — published site (architecture, security, broadcasting, transport-pgbus, testing, performance, examples)
