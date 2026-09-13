# The docs site (`docs/`)

A self-contained Rails app under `docs/` with its own bundle, RuboCop, RSpec and bun lockfile, deployed to https://phlex-reactive.zoolutions.llc. It is both the published documentation and the **demo app** — it depends on the gem by `path: ".."`, so every example page on the site is a live reactive component the site's own system suite drives in a browser. A showcase that cannot rot silently is the point.

## Shape

It is a [docs-kit](https://github.com/zoolutions/docs-kit) site: a Phlex/daisyUI chrome where every page is a `DocsUI::Page` subclass and the sidebar, table of contents, search and Markdown twin come free. The authoring contract is `docs/AGENTS.md`; the short version is that you never hand-write HTML or daisyUI markup, you compose `DocsUI::` helpers.

Pages live in `docs/app/views/docs/pages/` (29 files) and are routed only through `Doc::REGISTRY` in `docs/app/models/doc.rb` (29 entries, one per page class). **A page with no registry line is neither routed nor in the nav**, so scaffold with the generator rather than adding a file by hand:

```bash
cd docs && bin/rails g docs_kit:page "Title" --group=Guide
```

which writes the page class and injects its registry line in one idempotent step.

## Which page documents what

| Behaviour | Page |
|---|---|
| `action`, `on`, the dispatch descriptors, params | `actions_events.rb` |
| the mental model, the two mixins, the re-render unit | `architecture.rb` |
| signed identity, default-deny, the threat model | `security.rb` |
| `broadcast_to`, `each:`, `exclude:`, collections | `broadcasting.rb` |
| the pgbus transport and its capability gates | `transport_pgbus.rb` |
| `reply.defer`, `reactive_lazy`, the two lanes | `deferred_rendering.rb` |
| `reply.pending`, `reactive_settle`, the handle | `async_actions.rb` |
| the enter/exit/update vocabulary | `effects.rb` |
| the suites, the helpers, the matchers | `testing.rb` |
| the hot paths and the benchmark contract | `performance.rb` |
| instrumentation events and the APM adapters | `observability.rb` |
| doctor, inspector, the MCP server, the generators | `tooling.rb` |
| everything else | the `example_*.rb` pages, one live demo each |

A behaviour change updates its page in the same PR. A setting that is *removed* is removed from the config, the README, the page and the CHANGELOG together, each carrying a short note on why it is absent — `settle_token_ttl` is the worked example.

## Its own gates

```bash
cd docs && bundle exec rake lint     # RuboCop with an explicit file list
cd docs && bundle exec rspec         # views, requests and system specs (40 files)
cd docs && bin/dev                   # run it locally
```

`rake lint` rather than bare `rubocop` is not a preference: the gem's ancestor `.rubocop.yml` excludes `docs/**/*`, so a bare run in that directory inspects zero files and passes vacuously. The rake task passes `app/**/*.rb spec/**/*.rb Rakefile config.ru` explicitly to defeat the inherited exclude.

CI runs the site under both real servers in the `site` job of `main.yml`, with `rake lint` on the puma cell only.

## The `path: ".."` pin

`docs/Gemfile.lock` pins `phlex-reactive (X.Y.Z)` in two places — the PATH source spec and the CHECKSUMS block — and so does the root `Gemfile.lock` (tracked since #246, because the root `Gemfile` says `gemspec`). Both carry the version string, so a version bump that misses them leaves a committed lockfile stale and the Release workflow's frozen install refuses it. `rake release` therefore rewrites the pin in both with a text edit; see [`../review/release-and-changelog.md`](../review/release-and-changelog.md) for why it is an edit and not a re-resolve.

The `site` CI job sets `BUNDLE_FROZEN: "false"` for a different reason: the gemspec lists files with `git ls-files`, so every commit changes the file list and the path gem's digest never matches a previously-committed lock.

## Deploy

`deploy-docs.yml` fires on `release: published` (and `workflow_dispatch`), delegating to the shared `zoolutions/docs-kit/.github/workflows/deploy.yml`. So the docs go live with the gem. `image`/`service` are the REPO name (`phlex-reactive`, not `-docs`) so the pushed ghcr package auto-links to this repo and `GITHUB_TOKEN` can push and pull it without a PAT; they must match `service:`/`image:` in `docs/config/deploy.yml` and the Dockerfile `LABEL`. The caller must grant `packages: write` — a reusable workflow can narrow the permissions it is given but never escalate them, and the repo default is read-only.

Plans live in `docs/plans/`; see [`../plans/README.md`](../plans/README.md).

Related: [`../testing-and-ci/summary.md`](../testing-and-ci/summary.md), [`../review/docs-and-changelog.md`](../review/docs-and-changelog.md).
