# Lode map

The index of this repository's durable memory. Read this first; it beats a directory listing. Every file describes the system as it is now, with the rationale; `../CHANGELOG.md` records what changed.

- `summary.md` — what phlex-reactive is and the three invariants every change is measured against
- `terminology.md` — the words this repo uses (identity token, draft token, defer vs settle, handle, anchor, ops chain, companion, actor vs peer…)
- `practices.md` — practices learned from the code and from review that `../.claude/rules/` does not state: capability probes, failing at declaration time, enumerate-once, caching on the render path, threading request state, escaping
- `workflow.md` — the profile the shared `/lode:*` workflow skills read: commands, layers, shapes, constraints, CI, flake sources, conflict rules
- `plans/README.md` — where plans live

## Subsystems

- `core-and-config/summary.md` — `Phlex::Reactive` and the engine: the Zeitwerk loader's exclusions, identity and defer token signing with the version upgrade path, the whole settings surface, the four capability gates, off-request rendering, the route guard, instrumentation
- `component/summary.md` — the include stack, the twelve-registry inheritance semantic, `Identity`, lazy mounts, every declaration macro, the view helpers, `ParamSchema`'s drop-don't-fabricate table, `ShowConditions`, `JS` and `Effects`
- `endpoint/summary.md` — `ActionsController#create` and `#deferred` step by step, the around-action fold, the rescue-order table, the two token-refresh guards, `Stream`'s metadata, `Response` vs `Reply`, `Authorization`
- `streaming/summary.md` — `Streamable`: the `#id` contract, `render_in` and the per-thread view context, every stream builder, `broadcast_to`'s one-verb rule and its transport options, and `Collections`' shared decisions
- `async-and-defer/summary.md` — why a settle exists, the pull and push lanes, `reply.defer`, the one-shot stream key, `DeferredRenderJob`, `reply.pending` → `Pending` → `Settles`/`Settle`
- `client-runtime/summary.md` — the five authored modules, the per-file build and its two drift guards, the bare-specifier rule, the wire, the custom turbo-stream actions, the controller's invariants, the overridable seams
- `tooling/summary.md` — `Doctor`, `Inspector`, the MCP diagnostic server, the APM adapters, the three generators, the test helpers and matchers
- `testing-and-ci/summary.md` — the five suites, the server x transport matrix, pgbus in tests, the five CI jobs and their quirks, release and deploy
- `docs-site/summary.md` — the docs-kit app under `docs/`: page-to-behaviour map, its own gates, the `path: ".."` pin, the deploy

## Review rules (`review/`)

Accepted review findings rewritten as rules about the system, each verified against the current code and carrying the spec that proves it. `/lode:gate` reads every file here before reviewing a diff; `/lode:learn` adds to them.

- `review/async-actions.md` — no `settle_token_ttl`, materialize once, reject a misspelled keyword, one subscription per anchor, attributable pending cleanup, best-effort peers, the peer replace path, row kwargs to peers, dom-id Strings
- `review/collections.md` — resolve the size once, edge-trigger the empty state, a replace moves no boundary, bind the container as `token_component`, accept a dom-id String everywhere
- `review/client-runtime.md` — gate the root too, the effect reentrancy token, all-blank vs single-blank legs, deep-freeze op payloads, and two *Not a bug* entries on the connect-time gate posture and the legacy show arm
- `review/observability.md` — snapshot the reporter context, stable built-in adapter instances, probe the SDK's arity, never change what propagates
- `review/release-and-changelog.md` — validate before anything destructive, count the lockfile pins, text-edit not re-resolve, one block per changelog section
- `review/docs-and-changelog.md` — name the exceptions to a "nothing leaves the browser" claim, document real ordering, remove a setting everywhere at once, keep the demo's controls working
- `review/testing.md` — restore every global, capture-then-restore a shared adapter, guard ordering indexes, and two *Not a bug* entries on the confirm teardown and lexical constant lookup

## Not memory

- `tmp/` — git-ignored: gate diffs and reports, handovers, scratch
