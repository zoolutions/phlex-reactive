# Testing and CI

Five suites, two of them browser-driven, one of them JavaScript. All the Ruby ones drive `spec/dummy`, a minimal Rails app with nine models and 71 example components.

## The suites

| Suite | Path | Files | Boots | Proves |
|---|---|---|---|---|
| Unit | `spec/phlex/**` | 58 | nothing, or a stubbed verifier | identity signing, the DSL, the registries, the capability gates, `ParamSchema`, `JS`, `Effects`, `Collections` |
| Request | `spec/requests/**` | 43 | the dummy app | the endpoint: token verify, default-deny, coercion, 400/403/404, `reply.*`, broadcast payloads |
| System | `spec/system/**` | 55 | dummy + Capybara/Playwright | the real browser loop — click to morph, no reload, rapid-click races, live SSE delivery |
| Generators | `spec/generators/**` | 3 | Rails' generator harness | the three generators' output |
| JavaScript | `spec/javascript/**` | 52 | bun, no browser | the client runtime's units, run with `bun test spec/javascript` |

`bundle exec rake` is `spec` + `rubocop`, where `spec` is the pattern `spec/{phlex,requests}/**/*_spec.rb` — the fast suite. The system suite is deliberately NOT in the default task; invoke it with `rake spec:system`.

## What the browser suite runs

It serves the **vendored minified** client from `spec/dummy/public/vendor/`, not the authored source. Production ships minified, so a minifier-induced bug — a mangled name breaking a Stimulus lifecycle hook, a dropped export — would otherwise ship untested. `spec/phlex/vendored_controller_sync_spec.rb` names the five files that must stay byte-identical to their `*.min.js` twins and prints the exact `rake build:js && cp …` re-sync command in its failure message; `rake build:js_check` is the same guard from the other side, comparing a fresh build against the index.

Two real servers, two transports, run as a 2x2:

- **server**: `puma` (sync, thread pool) or `falcon` (async, fiber-per-request), via `CAPYBARA_SERVER`. No webrick — it is not a real server. `Thread.current` is fiber-local in Ruby, which is what makes the `with_*` request-state pairs safe under Falcon; the Falcon cells are the proof.
- **transport**: `cable` (Action Cable over SQLite) or `pgbus` (Postgres SSE), via `TRANSPORT`. The pgbus cells additionally prove real cross-tab delivery and actor-echo exclusion over live SSE.

`rake spec:system_servers` runs both servers locally; `rake spec:system_matrix` runs the full 2x2 and **skips the pgbus cells with a clear note when `pg_isready` fails**, so the cable cells still prove the round trip on a machine with no Postgres. `rake pgbus:prepare_test_db` (via `spec/support/prepare_pgbus_db.rb`) boots the dummy under `TRANSPORT=pgbus`, loads the schema and installs pgbus's vendored PGMQ — no `CREATE EXTENSION`, so a plain `postgres:18` image works.

## pgbus in tests

pgbus is a dev/test dependency with `require: false` and a Ruby >= 3.3 floor (the gem's own runtime floor is 3.4). The default suite needs no Postgres. A pgbus-specific spec guards with `defined?(Pgbus)` or a tag and asserts BOTH paths — pgbus present and the capability-gate fallback. The regression guard for the `ArgumentError: unknown keyword :exclude` class of bug is a double shaped like old pgbus: a `broadcast` whose signature has no `:exclude`.

## Fixtures

`spec/fixtures/show_predicate_vectors.json` is the shared parity fixture: the same predicate vectors run through Ruby's `ShowConditions.match?` and through the client's evaluator, so the two cannot drift. `spec/fixtures/files/` holds the upload fixtures (`receipt.txt`, `page1.txt`, `page2.txt`).

## CI (`.github/workflows/main.yml`)

Triggers on `push` to `main` and on every `pull_request`. Five jobs:

| Job | Cells | Runs |
|---|---|---|
| `lint` | 1 (Ruby 4.0) | `bundle exec rubocop`, then `gem build phlex-reactive.gemspec --strict` |
| `test` | Ruby 3.4, 4.0 | `bundle exec rspec spec/phlex spec/requests spec/generators` |
| `bench` | 1 (Ruby 3.4) | `rake bench:micro` and `rake bench:request`, uploaded as an artifact — **report-only, never a hard fail** |
| `site` | puma, falcon | the `docs/` app's own request and system suites; `rake lint` on the puma cell only |
| `system` | server x transport = 4 | `bun test spec/javascript` (cable cells), `rake build:js_check` (puma+cable only), the pgbus DB prep on pgbus cells, then `rspec spec/system`; failure screenshots uploaded |

All three matrix jobs (`test`, `site`, `system`) set `fail-fast: false`, so one red cell does not hide the others; `lint` and `bench` are single cells with no matrix.

Two CI quirks worth knowing before diagnosing a failure:

- The `site` job sets `BUNDLE_FROZEN: "false"`. The docs app depends on the gem by `path: ".."` and the gemspec lists files with `git ls-files`, so every commit changes the file list and the path gem's gemspec digest never matches a previously-committed lock. Frozen mode would fail with "the gemspecs for path gems changed" on every PR.
- The docs app's lint gate is `bundle exec rake lint`, not bare `rubocop`. The gem's ancestor `.rubocop.yml` excludes `docs/**/*`, so a bare run there inspects zero files and passes vacuously; the rake task passes the file list explicitly.

## Release and deploy

`bin/release` is the front door (`list`, `--dry-run`, `patch|minor|major|X.Y.Z`, `--force`); it refuses anything but a clean, up-to-date `main` and hands off to `rake release[X.Y.Z]`. That task bumps `version.rb`, rewrites the `phlex-reactive (X.Y.Z)` pin in both tracked lockfiles with a text edit, commits, pushes `main` and publishes the GitHub Release. `release.yml` then publishes to RubyGems by trusted publishing (OIDC + Sigstore) — never `gem push` by hand — and `deploy-docs.yml` ships the docs site on the same `release: published` event, through the shared `zoolutions/docs-kit` deploy workflow.

The release task's ordering is itself a rule; see [`../review/release-and-changelog.md`](../review/release-and-changelog.md).

Related: [`../client-runtime/summary.md`](../client-runtime/summary.md), [`../docs-site/summary.md`](../docs-site/summary.md), [`../workflow.md`](../workflow.md).
