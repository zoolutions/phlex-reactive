// The client's byte budget (issue #275).
//
// The gem ships one minified file per module; the browser pays their gzipped
// size. The client has TWO entries, and an app loads one of them:
//
//   reactive_controller    the DEFAULT: the runtime and every feature in
//                          ONE file. Every page with a reactive root loads
//                          all of it, and nothing later.
//   core                   opt-in: the runtime alone. It then imports
//                          features/<name> on a page that uses one.
//
// This file REPORTS every built module and holds these lines:
//
//   early.min.js           the one module every page loads eagerly — its own
//                          budget, asserted since issue #273.
//   reactive_controller    a no-growth RATCHET on the default bundle.
//   core                   a RATCHET that each phase of #275 lowered to the
//                          size it reached, as code moved out to features;
//                          now the final size (see BUDGET OUTCOME below).
//   features/<name>        a ceiling each; a feature without one fails.
//   SPLIT TOTAL            core + every feature: what a page on the split
//                          client downloads if it uses everything. Moving code
//                          into its own file costs bytes (it compresses worse
//                          alone), so this line keeps the sum honest while
//                          the core shrinks.
//
// TARGET_CORE_GZIP is the maintainer's target for the core — 10,240 B. It is
// reported against on every run, and is the ratchet itself when met.
//
// Sizes are of the COMMITTED build (rake build:js_check guards that it matches
// a fresh one), gzipped at level 9 by bun's zlib. Another gzip (the CLI, a
// CDN) lands within about half a percent of these numbers, not on them.
//
// Run with: bun test spec/javascript
import { test, expect } from "bun:test"
import { existsSync, readdirSync, readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { gzipSync } from "node:zlib"

const root = join(dirname(fileURLToPath(import.meta.url)), "../..")
const srcDir = join(root, "app/javascript/phlex/reactive")

// Every module the build emits, read from the build script itself so a new
// entry (a feature module) is reported without anyone editing this file.
const buildScript = readFileSync(join(root, "scripts/build_client.js"), "utf8")
const ENTRIES = [...buildScript.match(/const ENTRIES = \[([^\]]*)\]/)[1].matchAll(/"([^"]+)"/g)].map(([, name]) => name)
const BUNDLE = buildScript.match(/const BUNDLE = "([^"]+)"/)[1]
const SPLIT = buildScript.match(/const SPLIT = "([^"]+)"/)[1]
const MODULES = [BUNDLE, SPLIT, ...ENTRIES]
const FEATURES = ENTRIES.filter((name) => name.startsWith("features/"))

const EARLY_GZIP_BUDGET = 1100
// How far a ceiling may sit above the real size: the rounding it is set with.
const SLACK = 250

// The DEFAULT bundle. Before the split the one file was 22,272 B (a32937b).
// It is now the runtime + every feature bundled: 26,132 B — 3,860 B more,
// the price of each feature being a module of its own with a table to find it
// by. Phase 3 left it at 24,789 B, phase 4 at 24,851 B.
const BUNDLE_GZIP_CEILING = 26_250
// The split core (the runtime + the import table). The monolith was 22,272 B;
// phase 1 (the loader) brought it to 22,787 B, phase 2 (persist + editors
// out) to 21,233 B, phase 3 (defer / lazy out) to 19,740 B, phase 4 (effects
// and dismiss, dirty tracking and the paste gate, the latency simulator out)
// to 18,536 B, phase 5 (the form bindings, compute, the hint engine, the
// diagnostics and the debug trace out) to 12,326 B.
//
// BUDGET OUTCOME (issue #275): the maintainer's target for the core is
// TARGET_CORE_GZIP, 10,240 B. The honest moves left the core 2,086 B over it, so the ratchet below is the real size rounded up to the next 250 B, and the target is printed in the report; the PR body's Budget outcome section has the gap and the remaining options.
const CORE_GZIP_CEILING = 12_500
const FEATURE_GZIP_CEILINGS = {
  "features/bindings": 5_500,
  "features/defer": 3_000,
  "features/compute": 2_250,
  "features/hints": 1_250,
  "features/effects": 1_750,
  "features/persist": 3_250,
  "features/form": 1_250,
  "features/devtools": 1_750,
}
// Phase 5: 12,326 B core + 5,360 + 2,846 + 2,084 + 1,024 + 1,693 + 3,210 + 1,015 + 1,589 B of
// features = 31,147 B.
const SPLIT_TOTAL_GZIP_CEILING = 31_250
// The maintainer's target for the core. Asserted as the ratchet when met.
const TARGET_CORE_GZIP = 10 * 1024

const builtPath = (name) => join(srcDir, `${name}.min.js`)

function sizeOf(name) {
  const bytes = readFileSync(builtPath(name))
  return { name, min: bytes.length, gzip: gzipSync(bytes, { level: 9 }).length }
}

const splitTotal = () => ["core", ...FEATURES].reduce((sum, name) => sum + sizeOf(name).gzip, 0)

function expectRatchet(actual, ceiling) {
  expect(actual).toBeLessThanOrEqual(ceiling)
  // A ceiling left far above the real size would let it regrow unnoticed.
  expect(ceiling - actual).toBeLessThan(SLACK)
}

test("every client module has a committed minified build", () => {
  expect(BUNDLE).toBe("reactive_controller")
  expect(SPLIT).toBe("core")
  expect(ENTRIES).toContain("early")
  for (const name of MODULES) expect(existsSync(builtPath(name))).toBe(true)
})

test("no minified build exists that the build script does not emit", () => {
  const built = readdirSync(srcDir, { recursive: true })
    .filter((file) => file.endsWith(".min.js"))
    .map((file) => file.slice(0, -".min.js".length))

  expect(built.sort()).toEqual([...MODULES].sort())
})

test("reports the gzipped size of every module", () => {
  const sizes = MODULES.map(sizeOf)
  const core = sizeOf("core")
  const bundle = sizeOf(BUNDLE)
  const row = ({ name, min, gzip }) => `  ${`${name}.min.js`.padEnd(32)} ${String(min).padStart(7)} B  ${String(gzip).padStart(6)} B gzip`
  // process.stdout, not console.log: other test files swap `console` for a stub.
  process.stdout.write(
    `${[
      "[phlex-reactive] client bundle sizes",
      ...sizes.map(row),
      `  default bundle (everything, one file): ${bundle.gzip} B gzip`,
      `  split total (core + ${FEATURES.length} features): ${splitTotal()} B gzip — ${splitTotal() - bundle.gzip} B more than the bundle`,
      `  split core target: ${TARGET_CORE_GZIP} B gzip — ${core.gzip <= TARGET_CORE_GZIP ? "met" : `${core.gzip - TARGET_CORE_GZIP} B over (ratchet ${CORE_GZIP_CEILING})`}`,
    ].join("\n")}\n`,
  )

  for (const { gzip } of sizes) expect(gzip).toBeGreaterThan(0)
})

test("early.min.js stays within its eager budget", () => {
  expect(sizeOf("early").gzip).toBeLessThanOrEqual(EARLY_GZIP_BUDGET)
})

test("the default bundle does not grow past its ratchet", () => {
  expectRatchet(sizeOf(BUNDLE).gzip, BUNDLE_GZIP_CEILING)
})

test("the split core does not grow past its ratchet", () => {
  expectRatchet(sizeOf("core").gzip, CORE_GZIP_CEILING)
})

test("the split core is smaller than the default bundle by at least what moved out", () => {
  // The point of the split: a page that uses no feature downloads less.
  expect(sizeOf(BUNDLE).gzip - sizeOf("core").gzip).toBeGreaterThan(13_500)
})

test("every feature module has a ceiling, and stays under it", () => {
  expect(Object.keys(FEATURE_GZIP_CEILINGS).sort()).toEqual([...FEATURES].sort())
  for (const name of FEATURES) expectRatchet(sizeOf(name).gzip, FEATURE_GZIP_CEILINGS[name])
})

test("the split core and its features together do not grow past their ratchet", () => {
  expectRatchet(splitTotal(), SPLIT_TOTAL_GZIP_CEILING)
})
