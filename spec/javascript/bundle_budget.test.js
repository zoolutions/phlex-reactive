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

// Raised from 1,100 for window-bound (hotkey) capture, issue #303.
const EARLY_GZIP_BUDGET = 1300
// How far a ceiling may sit above the real size: the rounding it is set with.
const SLACK = 250

// The DEFAULT bundle. Before the split the one file was 22,272 B (a32937b).
// The split left it at 26,132 B — 3,860 B more. Issue #305 builds it with
// __SPLIT__ false: the runtime imports every feature statically and calls it
// directly, so the loader, the feature table and the hand-over fold away
// (24,675 B, 1,457 B recovered). Issue #306 (the cache: shell fallback) adds
// 87 B: 24,762 B.
//
// BUDGET OUTCOME (issue #305; the rest is #310): the target is TARGET_BUNDLE_GZIP, 22,700 B (the
// pre-split size plus a loader's worth). It is reported on every run, and is
// the ratchet itself when met. What the flag cannot recover is how the
// features are WRITTEN as modules — per-root state records where the
// controller had private fields, exported wrappers, the `core` handle — not
// the boundary between them and the runtime. Issue #303 (replaying
// window-bound hotkeys) adds 214 B on that 24,762 B baseline: 24,976 B. The
// ratchet below sits 24 B above the real size (inside SLACK): room for a
// fix in flight, not for a feature. Issue #297 (a select's reset state)
// adds 44 B: 25,020 B, and the ratchet moves by the 20 B it needs. Issue
// #298 (one unsaved-changes prompt per visit) adds 17 B: 25,037 B. Skipping
// a disabled <optgroup>'s options in the reset state (#297) adds 11 B: 25,048 B.
// Merged on top of #300, #292/#294 and #301 (which used the 24 B of slack):
// 25,067 B. Issue #299 (a nested row serialized like a real submit, incl. a
// <fieldset disabled> ancestor via :disabled) adds 24 B: 25,091 B. Issues
// #295/#296 (effects settle: hidden-tab legs exit, descendant end events)
// add 46 B: 25,137 B. Issue #319 (bulk selection: the checked: term,
// reactive_enable/select_all/count with their MutationObserver, and
// js.submit's submitter:, review fixes included) adds 796 B: 25,933 B. Issue
// #310 claws bytes back.
const BUNDLE_GZIP_CEILING = 24_925
const TARGET_BUNDLE_GZIP = 22_700
// The split core (the runtime + the import table). The monolith was 22,272 B;
// phase 1 (the loader) brought it to 22,787 B, phase 2 (persist + editors
// out) to 21,233 B, phase 3 (defer / lazy out) to 19,740 B, phase 4 (effects
// and dismiss, dirty tracking and the paste gate, the latency simulator out)
// to 18,536 B, phase 5 (the form bindings, compute, the hint engine, the
// diagnostics and the debug trace out) to 12,383 B.
//
// BUDGET OUTCOME (issue #275): the maintainer's target for the core is
// TARGET_CORE_GZIP, 10,240 B. The honest moves left the core 2,143 B over it, so the ratchet below is the real size rounded up to the next 250 B, and the target is printed in the report; the PR body's Budget outcome section has the gap and the remaining options.
// Issue #303 (replaying window-bound hotkeys, shared runtime code) adds 210 B: 12,688 B.
// Issue #319 (the submit op's submitter:, the bindings marker for the group
// bindings) adds 129 B: 12,817 B.
const CORE_GZIP_CEILING = 12_850
const FEATURE_GZIP_CEILINGS = {
  // Issue #319 (bulk selection) took it from 5,360 B to 5,967 B; its review
  // fixes to 6,015 B.
  "features/bindings": 6_050,
  "features/defer": 3_000,
  "features/compute": 2_250,
  "features/hints": 1_000,
  "features/effects": 1_750,
  "features/persist": 3_250,
  "features/form": 1_250,
  "features/devtools": 1_750,
}
// Phase 5: 12,383 B core + 5,360 + 2,846 + 2,084 + 1,024 + 1,693 + 3,210 + 1,015 + 1,589 B of
// features = 31,204 B. Issue #305 (the default entry's static path) costs the
// core 84 B: 12,467 + 18,821 = 31,288 B. Issue #306 (a cache: shell's refused
// URL falls back to a GET; no __materialize POST without a token) adds 97 B:
// 31,385 B. Issue #303 (window-bound hotkeys, in the core) adds 215 B: 31,600 B.
// The backlog fixes (#292-#301, #295/#296) together use the 150 B of room and
// 37 B more: 31,787 B. Issue #319 (bulk selection, in the core and bindings)
// adds 781 B: 32,568 B.
const SPLIT_TOTAL_GZIP_CEILING = 32_027
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
      `  default bundle (everything, one file): ${bundle.gzip} B gzip — ${bundle.gzip <= TARGET_BUNDLE_GZIP ? "target met" : `${bundle.gzip - TARGET_BUNDLE_GZIP} B over the ${TARGET_BUNDLE_GZIP} B target (ratchet ${BUNDLE_GZIP_CEILING})`}`,
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
  // (12,203 B since issue #305 took the loader out of the bundle.)
  expect(sizeOf(BUNDLE).gzip - sizeOf("core").gzip).toBeGreaterThan(12_000)
})

// Issue #305: the default entry is built with __SPLIT__ false, so nothing of
// the opt-in entry's loader may be in it — no import(), no feature table, no
// wait for a module. Each mark is checked against core.min.js too, so a mark
// that stops meaning anything fails here instead of passing vacuously.
const LOADER_MARKS = {
  "an import()": /\bimport\(/,
  "the feature table": /\["persist",\[/,
  "the loader's no-import fallback": /this entry has no way to import it/,
  "the feature import timeout": /phlex-reactive-feature-timeout/,
}

test("the default bundle carries no import() and no feature lookup table", () => {
  const bundle = readFileSync(builtPath(BUNDLE), "utf8")
  const core = readFileSync(builtPath("core"), "utf8")
  for (const [what, mark] of Object.entries(LOADER_MARKS)) {
    expect({ what, inCore: mark.test(core) }).toEqual({ what, inCore: true })
    expect({ what, inBundle: mark.test(bundle) }).toEqual({ what, inBundle: false })
  }
})

test("every feature module has a ceiling, and stays under it", () => {
  expect(Object.keys(FEATURE_GZIP_CEILINGS).sort()).toEqual([...FEATURES].sort())
  for (const name of FEATURES) expectRatchet(sizeOf(name).gzip, FEATURE_GZIP_CEILINGS[name])
})

test("the split core and its features together do not grow past their ratchet", () => {
  expectRatchet(splitTotal(), SPLIT_TOTAL_GZIP_CEILING)
})
