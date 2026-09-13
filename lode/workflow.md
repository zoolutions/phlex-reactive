# Workflow profile

Everything the shared workflow skills (`/lode:lfg`, `/lode:review-pr`, `/lode:finish-prs`, `/lode:debug-flaky`, `/lode:tdd`, `/lode:plan`) need to know about this repository that is not already in `../CLAUDE.md`, `../.claude/rules/` or the rest of `lode/`.

## Commands

| Purpose | Command | Notes |
|---|---|---|
| fast loop (one file) | `bundle exec rspec <file>` (e.g. `bundle exec rspec spec/phlex/reactive/pending_spec.rb`) | no services |
| full suite | `bundle exec rake` (= `rspec spec/{phlex,requests}` + `rubocop`) | no network, no services; **safe in two worktrees at once** — the dummy's test database is SQLite `:memory:`, so nothing is shared between processes |
| browser suite | `bundle exec rspec spec/system` (`CAPYBARA_SERVER=puma\|falcon`) | needs Playwright and a free port; **NOT safe in parallel** — it binds a server port, and `TRANSPORT=pgbus` additionally uses one named local database (`phlex_reactive_pgbus_test`) after `rake pgbus:prepare_test_db` |
| every server x transport | `bundle exec rake spec:system_matrix` | skips the pgbus cells with a note when `pg_isready` fails |
| JS suite | `bun test spec/javascript` | one bun process for all 52 files |
| lint | `bundle exec rubocop` (`-A` to autocorrect) | all new cops on |
| one CI cell locally | `CAPYBARA_SERVER=falcon TRANSPORT=cable bundle exec rspec spec/system` | mirrors one `system` matrix cell |
| docs build / check | `cd docs && bundle exec rake lint && bundle exec rspec` | **`rake lint`, never bare `rubocop`** — the gem's ancestor `.rubocop.yml` excludes `docs/**/*`, so a bare run inspects zero files |
| client rebuild | `rake build:js`, then `rake build:js_check` | needs bun |
| run the app | `cd docs && bin/dev` (the demo site) or `rake dummy:server` (the dummy, PORT=3010) | |
| benchmarks | `rake bench` (micro), `rake bench:request` (derailed), `rake bench:client` (bun) | |
| release | `bin/release [patch\|minor\|major\|X.Y.Z] [-n]` | `list` and `--dry-run` are read-only |

## Branches and PRs

- Default branch: `main`
- Work branches: `issue-<n>-<slug>` when the work has an issue (the dominant pattern in merged history), otherwise `feature/*`, `fix/*`, `refactor/*`, `ci/*`, `chore/*`. All rooted off fresh `origin/main`. `.claude/rules/git-workflow.md` lists only the prefixed forms
- Commits: conventional (`feat:`, `fix:`, `refactor:`, `perf:`, `docs:`, `test:`, `chore:`, `ci:`); the body says WHY. Scopes map to the architecture: `streamable`, `component`, `controller`, `client`, `engine`, `docs`, `ci`
- PR body sections, in order: Summary, Test plan / Test coverage, **Deviations & judgment calls**, Gate. The deviations section is mandatory — it is where the judgment calls made mid-implementation are audited, and "the plan held completely" is a valid body for it
- Write the PR body to a file and pass `--body-file`; a single-quoted heredoc passes backticks through verbatim, so never escape them
- Merge policy: squash on `main` after green and approval. Never force-push a published branch — merge `main` forward into it
- Attribution: **no** `Co-Authored-By: Claude`, no "Generated with" line. Add only the `Claude-Session:` trailer the session's own instructions specify
- Releases land DIRECTLY on `main` via `bin/release`, not through a PR

## Layers

| Layer | Files | Edit rule |
|---|---|---|
| Client runtime | `app/javascript/phlex/reactive/{reactive_controller,confirm,confirm_predicate,compute,inspect}.js` | owned here — but a source edit is a THREE-file change (source, rebuilt `.min.js` + `.map`, re-synced vendored twin) |
| Generated client | the same directory's `*.min.js` and `*.min.js.map` | **generated — never hand-edit or hand-merge.** Fix the source and `rake build:js` |
| Vendored twins | the five files in `spec/phlex/vendored_controller_sync_spec.rb`'s map under `spec/dummy/public/vendor/` | generated — `cp` from the rebuilt `.min.js`. Everything ELSE in that directory (stimulus, turbo, trix, lexxy, the dummy's reducers) is hand-written or third-party: merge it like source |
| Endpoint | `app/controllers/phlex/reactive/actions_controller.rb` | owned here; the only controller in the gem |
| Component mixin | `lib/phlex/reactive/component.rb` + `component/{dsl,helpers,identity,lazy,registry}.rb`, `client_bindings.rb` | owned here |
| Streaming | `lib/phlex/reactive/{streamable,collections}.rb` | owned here |
| Reply surface | `lib/phlex/reactive/{response,reply,stream}.rb` | owned here |
| Async | `lib/phlex/reactive/{defer,deferred_render_job,pending,settle,settles}.rb` | owned here |
| Core + engine | `lib/phlex/reactive.rb`, `engine.rb` | owned here |
| Tooling | `doctor.rb`, `inspector*`, `mcp/`, `apm/`, `lib/generators/`, `lib/tasks/` | owned here |
| Docs site | `docs/` | owned here, but a **separate app** — run its commands from inside `docs/`, with its own bundle |
| Lockfiles | `Gemfile.lock`, `docs/Gemfile.lock`, `bun.lock`, `docs/bun.lock` | generated — never hand-merge; take the base's and re-run the installer |

## Shapes

Check a change against these before calling it done; a reviewer will name the one you forgot.

- **pgbus absent, pgbus present but < 0.9.2, pgbus current.** Every pgbus feature needs the capability-probe gate AND its fallback asserted.
- **Both real servers.** Puma (threads) and Falcon (fibers) — `Thread.current` is fiber-local, so anything using the `with_*` request-state pairs must be proven under both.
- **Both transports.** Action Cable and Postgres SSE.
- **A record-backed component AND a state-backed one**, plus the draft case: an unsaved or nil record mints a token with no `gid`.
- **A collection delta at its boundaries**: 0→1 and 1→0 for the empty state, plus a size resolver that is nil.
- **A row identified by a record AND by a bare dom-id String** — every removal path accepts both.
- **An action with no params, with declared params, and with an undeclared/misspelled key** (which must be dropped, never fabricated).
- **`verbose_errors` on and off** — the diagnostic branches early-return when it is off.
- **A client-only component** (`include ClientBindings` alone, no `#id`, no token) as well as a full reactive one.
- **An op mixed onto the reactive ROOT**, not only onto a descendant.
- **A reply that does not re-render self** — `streams`, `with`, the collection verbs, `pending` — which still has to roll the token forward.
- **Ruby 3.4 and 4.0**, the two CI cells.

## Constraints

Suggestions that are wrong in this repository. Push back on sight.

| Suggestion | Why it is wrong here |
|---|---|
| "Hand-edit the `.min.js` / the vendored copy to match" | They are build outputs. Fix the source, `rake build:js`, re-sync. `build:js_check` and the sync spec exist to catch the hand edit |
| "Add pgbus (or an APM SDK, or `mcp`) to the gemspec" | Optionality is a core invariant. Every one of these is runtime-probed and degrades |
| "Gate on `defined?(::Pgbus)` / a version string" | pgbus < 0.9.2 also defines `::Pgbus`. Probe the keyword you are about to pass |
| "Wire the morph listener unconditionally so a later-introduced trigger is gated" | Every sibling gate decides once at `connect()`; see `review/client-runtime.md` |
| "Extend the legacy flat show-attribute arm with the new predicates" | It is scheduled for deletion and no Ruby version ever emitted those attributes; see `review/client-runtime.md` |
| "Restore the original `window.confirm` in the bun teardown" | There is no pristine value to capture and it would break the lazy delegation the next file needs; see `review/testing.md` |
| "Assert exactly two lockfile pins in the release task" | A lockfile with no CHECKSUMS section legitimately has one; see `review/release-and-changelog.md` |
| "Use `bundle lock --local` to bump the release pin" | A full re-resolve trips over constraints unrelated to this gem |
| "Run bare `rubocop` in `docs/`" | The ancestor config excludes `docs/**/*`; it inspects zero files and passes vacuously |
| "Use Phlex's `dom_id` helper in `#id`" | `#id` runs BEFORE render; use `Streamable#dom_id`, which delegates to `ActionView::RecordIdentifier` |
| "Include `Turbo::Streams::ActionHelper`" | It pulls in `ActionView::Helpers::TagHelper`, which overrides Phlex's internal `tag` and breaks rendering |
| "Pass `exclude:` straight to `Turbo::StreamsChannel`" | turbo-rails swallows unknown kwargs into its render locals, silently dropping the actor-echo suppression |
| "Claim a speedup without a measured baseline" | Any hot-path change ships with a same-machine before/after from `rake bench` |

## Docs

- User-facing docs live in `docs/app/views/docs/pages/`; a page is routed and in the nav ONLY through its entry in `docs/app/models/doc.rb`. The behaviour-to-page map is in [`docs-site/summary.md`](docs-site/summary.md)
- The README is the long-form twin and repeats most of that content; grep it for any sentence you change on a page
- Changelog: `CHANGELOG.md`, under `## [Unreleased]`, `### Added` before `### Fixed`, one block per section — merge into the existing block, never append a second
- A change to a setting, a verb, a wire attribute or a client op always updates its docs page AND the README AND the CHANGELOG in the same PR
- Files that pin a version and drift after a release: `Gemfile.lock` and `docs/Gemfile.lock` (both pin `phlex-reactive (X.Y.Z)` in two places). `rake release` rewrites both; after any manual `VERSION` move, re-run it or edit the pins the same way

## CI

- Workflows: `main.yml` (push to `main` + every PR — jobs `lint`, `test`, `bench`, `site`, `system`), `release.yml` (`release: published` → RubyGems trusted publishing), `deploy-docs.yml` (`release: published` → the docs site via `zoolutions/docs-kit`'s reusable deploy)
- Matrix: `test` on Ruby 3.4 and 4.0; `site` on puma and falcon; `system` on server (puma/falcon) x transport (cable/pgbus) = 4 cells. `fail-fast: false` on all three matrix jobs
- Cells that differ from local: the pgbus cells get a `postgres:18` service and run `rake pgbus:prepare_test_db` first; `bun test spec/javascript` runs only on the cable cells; `rake build:js_check` runs only on puma+cable; the `site` job runs with `BUNDLE_FROZEN: "false"`
- Fetch a failure: `gh run view --job <id> --log-failed`; the `system` job also uploads `capybara-screenshots-<server>-<transport>` on failure
- "Green" means every cell of all five jobs **except `bench`**, which is run-and-report and uploads an artifact — it is never a hard fail
- Shared or rate-limited services: none in CI — each pgbus cell gets its own `postgres:18` service container, so PRs need not run one at a time. **Locally** the pgbus cells share one named database, so do not run two of them at once

## Flake sources

- **The browser suite's async morph.** A snapshot assertion taken immediately after a click races the round trip. Use the waiting matchers (`have_css(..., text:)`, `have_field(with:)`, `wait_for_reactive`) as the barrier — never `sleep`.
- **Falcon's fiber-per-request model** against anything caching a view context or holding request state. The per-thread view-context cache and the `with_*` save/restore pairs are the answer; a new cache that is per-process rather than per-thread shows up here first.
- **pgbus SSE timing** — the broadcast-before-subscribe race is closed by `since-id="0"` on a fresh one-shot key plus `durable: true`. A "the shimmer never resolved" flake is usually a key or durability regression, not the network.
- **Shared process state in the bun suite** — a global left installed by an earlier file (see `review/testing.md`).
- **A shared ActiveJob adapter** left switched by an earlier example.
- **Playwright browser install / port binding** in CI, which is environmental, not a code flake.

## Conflicts

| File | Rule |
|---|---|
| `app/javascript/phlex/reactive/*.min.js`, `*.min.js.map` | never hand-merge. Resolve the SOURCE `.js` semantically, then `rake build:js` |
| the five vendored twins under `spec/dummy/public/vendor/` | never hand-merge. `cp` each rebuilt `.min.js` over its twin. The rest of that directory is ordinary source |
| `CHANGELOG.md` | union under `## [Unreleased]` — keep BOTH sides' bullets, most recent first, WITHOUT duplicating the `### Added` / `### Fixed` subheads |
| `lib/phlex/reactive/version.rb` | releases land directly on `main`, so an ordinary feature branch never edits this. A conflict means the branch bumped it deliberately (a release-prep PR) — keep the branch's bump. If the intent is not obvious from the branch's own commits, stop and ask |
| `Gemfile.lock`, `docs/Gemfile.lock` | take the base's file, then `bundle install` in the gem root or in `docs/`. Never hand-edit a lockfile |
| `bun.lock`, `docs/bun.lock` | take the base's, then `bun install` in that directory |
| `docs/app/models/doc.rb`, `spec/dummy/config/routes.rb` and any other route file | append-only registries, base order first — each side's entries must all survive |
| `spec/fixtures/show_predicate_vectors.json` | union the vectors; both sides' cases are parity proofs |
| fixtures / dummy components | add a second component rather than merging two shapes into one |

After resolving, run the gates scoped to what the conflict touched, BEFORE pushing the merge: `bundle exec rubocop`, `bundle exec rspec spec/phlex spec/requests`, plus `bun test spec/javascript && rake build:js_check` if client artifacts were involved and `cd docs && bundle exec rake lint && bundle exec rspec` if `docs/` was.

## Verification

- The manual check a user of this change would do: `cd docs && bin/dev`, open the page that demonstrates the behaviour, and drive it in a browser with a second tab open to see the broadcast half. For a CLI-shaped change, `bin/rails phlex_reactive:doctor` in the dummy or the docs app
- Stress iterations for a flake proof: **50** runs of the single example under the cell that showed it (both server values when the suspicion is concurrency)
- A hot-path change ships a same-machine before/after from `rake bench` — throughput AND allocations, and say whether the win is method-level or request-level
- Where evidence goes: `lode/tmp/` (git-ignored) unless the PR needs an auditable trail, in which case it goes in the PR body

Related: [`lode-map.md`](lode-map.md), [`practices.md`](practices.md), [`../.claude/rules/`](../.claude/rules/).
