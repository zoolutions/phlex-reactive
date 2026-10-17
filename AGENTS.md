# phlex-reactive

Project instructions for every agent: Claude Code (`CLAUDE.md` imports this file), Grok, Cursor,
Copilot, Codex read it directly. Claude-only extras (plugin settings, commands) live under `.claude/`.

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
8. **Measure performance, don't guess** — any hot-path change (render, token signing, param coercion, broadcast, client dispatch) ships with a same-machine before/after from `rake bench` (or `/ruby-gem:perf`). No speedup claim without a measured baseline. Report throughput AND allocations; distinguish a method-level win from a request-level one. See the Performance section below and the performance page (`docs/app/views/docs/pages/performance.rb`).

## Commands

```bash
bundle exec rspec spec/phlex spec/requests   # Fast suite (unit + request + broadcast)
bundle exec rspec spec/system                # Browser suite (Playwright; Puma default, CAPYBARA_SERVER=falcon for the async server)
bundle exec rake spec:system_servers         # Browser suite under BOTH real servers (puma + falcon)
bundle exec rubocop                          # Lint (rubocop -A to autocorrect)
bundle exec rake                             # spec + rubocop
bundle exec rake bench                        # Performance micro-benches (render, token, coerce_params)
bundle exec rake bench:request                # End-to-end request-cycle bench (derailed)
bundle exec rake bench:browser                # Client connect/disconnect + heap soak in headless Chromium (trust this over happy-dom)
rake build:js                                 # Rebuild the minified client (.min.js + .map) after editing runtime.js, an entry or a feature
rake build:js_check                           # CI drift guard: committed .min.js must match a fresh build
bin/release [patch|minor|major|X.Y.Z] [-n]    # Cut a release (list / --dry-run are read-only); drives rake release
```

Command output is condensed by rtk (PreToolUse hook). It already rewrites `bundle exec rspec`,
`bundle exec rubocop`, `bun test`, and `bun run` on its own; `.rtk/filters.toml` extends it to
`rake bench` / `rake bench:*` (the noisy version banner + warmup/calculating separators). Every
edit to it needs `rtk trust --yes` + `rtk verify`. Write commands in hook-rewritable shapes: no
`for`/subshell wrappers, no `| head` on rtk-handled commands, `bundle exec rubocop` not `bin/rubocop`.

### Editing the client runtime (`runtime.js` / `core.js` / `features/*.js` / `confirm.js` / `compute.js` / `inspect.js`)

The client's source is a shared **runtime** (`runtime.js`: the controller)
plus **feature modules** (`features/<name>.js`), and it ships as TWO entries
(issue #275), each built with the runtime inside it:

| Entry | Built from | What it is |
|---|---|---|
| `phlex/reactive/reactive_controller` | `reactive_controller.js` + `runtime.js` (built with `__SPLIT__` false: imports every feature statically) + `features/*.js` | the DEFAULT: one bundled file, nothing fetched on demand, features connect inside `connect()`. It contains no `import()` |
| `phlex/reactive/core` | `core.js` (where each feature module lives, and what only a client that waits for one needs) + `runtime.js` | opt-in: imports a feature when something on the page needs it |

The features are `persist`, `defer`, `form`, `bindings`, `compute`, `sortable`,
`drag`, `presence`, `countdown`, `effects`, `hints` and `devtools` (`CLIENT_FEATURES` in `lib/phlex/reactive/engine.rb`
is the list; the runtime's table gives each its marker check). The split is
complete for these; `runtime.js` is what both entries are built with.
Behaviour goes in `runtime.js` or a feature, never in `reactive_controller.js`.
Code that only the opt-in client can run — an `import()`, what to record or
hold back while a module is on its way — goes in `core.js`, so the default
file does not carry it. The runtime itself is built twice (issue #305): with
`__SPLIT__` false for the default entry (it imports each feature statically and
calls it directly — no table, no loader) and true for the core. A place in
`runtime.js` that reaches a feature reads the BARE `__SPLIT__` in an `if`/`else`
or a ternary, never `if (!__SPLIT__) return` followed by the split code: bun
folds the first, but keeps whatever the second references (and with it the
table). The budget test asserts the default file has no `import()` and no table. The JS suite and the browser suite run on the default
entry; the opt-in path has its own tests (the cold reset seam in JS, with
`core.js` imported, and `rake spec:system_split` in the browser).

The gem ships the **minified** build, and the browser suite runs that same
minified build (the dummy vendors it). So a source edit is a THREE-file change:

```bash
rake build:js                                 # regenerate every .min.js + .map from source
cp app/javascript/phlex/reactive/reactive_controller.min.js \
   spec/dummy/public/vendor/reactive_controller.js   # re-sync the vendored copies: the default bundle,
cp app/javascript/phlex/reactive/core.min.js \
   spec/dummy/public/vendor/core.js                  # the opt-in entry (same for confirm/compute/inspect),
cp app/javascript/phlex/reactive/features/persist.min.js \
   spec/dummy/public/vendor/features/persist.js      # and EVERY feature: features/<name>.min.js -> features/<name>.js
bun test spec/javascript                      # JS unit suite (__SPLIT__ true: the opt-in shape)
bun test --define __SPLIT__=false spec/javascript   # …and as the shipped default entry (CI runs both)
bundle exec rake spec:system_split            # the browser specs that matter on the split client
```

An edit to `runtime.js` changes BOTH entries; an edit to a feature changes
`reactive_controller.min.js` (the bundle) and its own file. A NEW feature is
named in seven places that must agree — `ENTRIES` in `scripts/build_client.js`,
`CLIENT_FEATURES` in `lib/phlex/reactive/engine.rb`, the runtime's feature
table (its marker check), the runtime's static imports and `__SPLIT__`-false
call sites (issue #305), `core.js` (its literal `import()`), the default
entry's imports and `registerReactiveFeature` calls, and a ceiling in
`spec/javascript/bundle_budget.test.js`. (The dummy layouts pin whatever
`CLIENT_FEATURES` lists.) `spec/phlex/engine_client_pin_spec.rb` (the lists
and the layouts) and the budget test (the ceilings) fail when they don't.
A browser spec that is only true on the split client is tagged
`:split_client`; `rake spec:system_split` picks up every file with that tag.

Commit the source, the rebuilt `.min.js`/`.map`, AND the re-synced vendored copy
together. Two guards enforce it: `rake build:js_check` (committed min build matches
a fresh build) and `spec/phlex/vendored_controller_sync_spec.rb` (vendored copy is
byte-identical to the shipped `.min.js`). Its failure message prints the exact
re-sync command.

## Workflow

- **Verify:** `bundle exec rubocop` · `bundle exec rbs -I sig validate` · `bundle exec rspec spec/phlex spec/requests spec/generators` · client edit: `rake build:js`, re-sync vendored copies, `bun test spec/javascript` (also `--define __SPLIT__=false`), `rake build:js_check` · `docs/**`: `cd docs && bundle exec rake lint && bundle exec rspec`
- **Specs:** fast loop `bundle exec rspec <file>`; full suite `bundle exec rake`, browser `bundle exec rspec spec/system` (`rake spec:system_servers`, `rake spec:system_split`); two worktrees at once: yes, pgbus-transport system cells need their own Postgres (`DATABASE_URL`)
- **CI:** required `Lint`, `Ruby 3.4`, `Ruby 4.0`, four `System (puma|falcon / cable|pgbus)`, both `conformance / …`, `cubic · AI code reviewer`; `Benchmarks`, `kino smoke`, `Demo site` not required; full suite on the PR; failure report: artifact `capybara-screenshots-<server>-<transport>`
- **Review bot:** cubic
- **Merge:** squash — `gh pr merge <PR> --squash --delete-branch`
- **PR contract:** `## Summary` (`Closes #N`), `## Test plan`; labels per `## Labels`; scopes `streamable` `component` `controller` `client` `engine` `docs` `ci`; docs site or demo change: before/after screenshots; hot-path change: the before/after bench
- **Conflicts:** `CHANGELOG.md` — both sides' bullets under `[Unreleased]`, no duplicate subheads; `version.rb` — main's (only `bin/release` bumps it); `Gemfile.lock` `docs/Gemfile.lock` — main's + `bundle install`; `app/javascript/phlex/reactive/*.min.js{,.map}` and their `spec/dummy/public/vendor/` twins (map in `spec/phlex/vendored_controller_sync_spec.rb`) — never by hand: resolve the source, `rake build:js`, re-sync; `docs/app/models/doc.rb`, route files — both lines, main's first
- **Worktree setup:** `bundle install` · `bun install --frozen-lockfile` (also `docs/`); no undo step
- **Release:** `bin/release <v>` (never `gem push`; `bin/release`, `rakelib/release.rake` and `release.yml`'s shared jobs are the docs-kit kit, byte-identical across gems); changelog `CHANGELOG.md`, heading `## [X.Y.Z] - YYYY-MM-DD` under `## [Unreleased]`; no prep step; lockfiles `Gemfile.lock` `docs/Gemfile.lock`; docs `deploy-docs.yml` on release; no human step
- **Main health:** `gh run list --workflow main.yml --branch main --event push --limit 1 --json conclusion,headSha`
- **Upstream:** libraries we own `zoolutions/*`; no scrub terms
- **Bench:** `bundle exec rake bench`, one `bundle exec rake bench:one[<name>]`; hot paths `AGENTS.md → Performance`; CI runs no bench

## Agent commands

Plugins (`.claude/settings.json`): `/flow:lfg`, `/flow:plan`, `/flow:follow-through`, `/flow:finish-prs`,
`/flow:github-review-pr` (`-failures`, `-comments`), `/flow:review-pr`, `/flow:tdd`, `/flow:debug-flaky`,
the `flow:fable-validator` agent; `/ruby-gem:release`, `/ruby-gem:perf`. Local (`.claude/commands/`):
`/architect` (component → endpoint → client), `/security` (signed identity, default-deny, params, CSRF,
connection-id).

**Models.** Sessions run on `opus` with `fable` as the advisor (`.claude/settings.json`); consult it
before choosing an approach, a schema or public API, a migration, a dependency, anything
irreversible, and when a failure repeats. Every spawned agent names its `model:`; one that does not
runs on `sonnet` (`CLAUDE_CODE_SUBAGENT_MODEL`), never on the session's model.

**Reviewing and fixing.** Beyond the Never Do list: pgbus events do not bubble, so listen on the
element, not `document`; no secret in `reactive_state` (use `reactive_record` and read server-side);
existing components must keep working verbatim. Fix at the earliest point, never a `rescue`/`&.`:
a double-applied broadcast is the actor echo (dedup by id); `unknown keyword :exclude` is the
capability gate; a stale token under rapid clicks is the request queue and token threading;
`HelpersCalledBeforeRenderError` in `#id` is `Streamable#dom_id`.

## Architecture

```
Layer 4: Client runtime    app/javascript/phlex/reactive/runtime.js + features/*.js (ONE generic Stimulus controller; shipped bundled as reactive_controller, or split as core)
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
  `defined?(Pgbus)`. phlex-reactive's own runtime floor is Ruby 3.4. Assert BOTH paths: pgbus
  present and the capability-gate fallback (an "old pgbus" double whose `broadcast` lacks
  `:exclude` guards the `ArgumentError`). The default suite needs no Postgres; pgbus is
  `require: false`.
- Layers, cheapest first: unit `spec/phlex`, request `spec/requests` (endpoint, broadcasts),
  system `spec/system`. 100% for identity sign/verify (tamper, wrong key/purpose), the action
  endpoint (default-deny, coercion, authz 403) and the capability gate; 80% elsewhere.
- Browser specs: `data-testid` selectors (not glyph text); waiting matchers as the barrier for the
  async morph, never a snapshot right after a click; prove "no reload" with a `window.__marker`; a
  round trip must pass under Puma (sync) AND Falcon (async). Each system example runs under a
  watchdog (`spec/system/support/example_timeout.rb`): 90 s, `it "…", timeout: 120`,
  `SYSTEM_EXAMPLE_TIMEOUT=…`, `0` disables.
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
  (end-to-end); `/ruby-gem:perf` captures a same-machine before/after against `main`. The
  CI `bench` job is run-and-report (artifact), never a hard fail. A new hot path gets
  `benchmark/micro/<name>.rb` on the shared `BenchSupport` harness (`rake bench` globs it).
- **Report throughput AND allocations** (i/s, obj/call; retained > 0 per render is a leak), say
  whether the win is method-level or request-level, and say "within noise" when it is. If numbers
  moved, update the performance page and add a `perf:` CHANGELOG entry.
- **Cache correctness:** key any hot-path memo on what can change (renderer
  identity), reset on `config.to_prepare`, never cache values that rotate (CSRF token, pgbus
  connection id are read live).
- **Never** optimize a path the bench shows is cold, trade a security or correctness invariant
  (signed identity, default-deny, coercion, pgbus optionality) for speed, or rewrite the nested-param
  coercion (#16/#21/#24) for a marginal allocation win.
- **Hot paths:**

| Path | Where |
|------|-------|
| Component re-render | `lib/phlex/reactive/streamable.rb` (`render_component`, `to_stream_replace`, `turbo_stream_builder`) |
| Token signing | `lib/phlex/reactive/component/identity.rb` (`reactive_token`), `lib/phlex/reactive/component/helpers.rb` (`on`, `reactive_attrs`) |
| Param coercion | `app/controllers/phlex/reactive/actions_controller.rb` (`coerce_params` and friends) |
| Broadcast render | `lib/phlex/reactive/streamable.rb` (`broadcast_*_to`) |
| Client dispatch, connect | `app/javascript/phlex/reactive/runtime.js`, `features/*.js` |

- See the performance page (`docs/app/views/docs/pages/performance.rb`).

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
label from `.github/labels.yml` — never a `status` label. `/flow:plan` labels the
issue, `/flow:lfg` copies the issue's `type` and `area` labels onto the PR (never
`plan` or another status label). Without an issue, the type comes from the
change's conventional-commit prefix and the areas from
`bin/labels infer $(git diff --name-only origin/main...HEAD)`. Labels change in
the manifest and reach GitHub with `bin/labels sync`, never through the UI.
Rules: `.github/LABELS.md`. `bin/labels` + `.github/LABELS.md` are the shared
labels kit (canonical copy in docs-kit): never edit them in place.

## More Documentation

See `.claude/` and `docs/`:
- `.claude/commands/` — the local slash commands (`/architect`, `/security`)
- `docs/` — published site (architecture, security, broadcasting, transport-pgbus, testing, performance, examples)
