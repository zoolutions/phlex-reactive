// Client micro-benchmark entry point (issue #116) — the bun-runnable harness
// behind `rake bench:client`. It benches the client DISPATCH hot path named in
// .claude/rules/performance.md — #extractToken, #collectFields, recompute —
// through the controller's PUBLIC surface only (no __bench exports; no
// app/javascript/ edits, so the vendored-sync rule is never tripped).
//
//   bun run benchmark/client/index.bench.js
//   rake bench:client            # captures tmp/benchmarks/client.txt
//
// Each *.bench.js module registers its benches with mitata's bench()/group() on
// import; run() executes them all. `throw: true` is DELIBERATE: a crashed bench
// must fail the task (the Rakefile keys on the process exit status), never pass
// silently — mitata swallows bench errors by default, so we opt into throwing.
// `colors: false` keeps the saved report clean ASCII.

import { run } from "mitata"

// Importing a module registers its benches (side effect). Order = display order.
await import("./extract_token.bench.js")
await import("./collect_fields.bench.js")
await import("./recompute.bench.js")
await import("./run_ops.bench.js")

await run({ colors: false, throw: true })
