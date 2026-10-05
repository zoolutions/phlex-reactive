// The client's byte budget (issue #275).
//
// The gem ships one minified file per module; the browser pays their gzipped
// size. This file REPORTS every built module and holds two lines:
//
//   early.min.js           the one module every page loads eagerly — its own
//                          budget, asserted since issue #273.
//   reactive_controller    a RATCHET: the core may not grow past where the
//                          split has brought it. Each phase of #275 lowers
//                          CORE_GZIP_CEILING to the size it reached.
//
// TARGET_CORE_GZIP is where the split is heading. It is reported against, NOT
// asserted — the hard assert lands with the final phase of #275.
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
const MODULES = [...buildScript.match(/const ENTRIES = \[([^\]]*)\]/)[1].matchAll(/"([^"]+)"/g)].map(([, name]) => name)

const EARLY_GZIP_BUDGET = 1100
// Phase 1 of #275 (loader scaffold, nothing moved yet): 22,787 B — the
// monolith's 22,272 B plus 515 B of loader.
const CORE_GZIP_CEILING = 23_000
// NOT asserted yet — see the header.
const TARGET_CORE_GZIP = 8 * 1024

const builtPath = (name) => join(srcDir, `${name}.min.js`)

function sizeOf(name) {
  const bytes = readFileSync(builtPath(name))
  return { name, min: bytes.length, gzip: gzipSync(bytes, { level: 9 }).length }
}

test("every client module has a committed minified build", () => {
  expect(MODULES).toContain("reactive_controller")
  expect(MODULES).toContain("early")
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
  const core = sizes.find(({ name }) => name === "reactive_controller")
  const row = ({ name, min, gzip }) => `  ${`${name}.min.js`.padEnd(32)} ${String(min).padStart(7)} B  ${String(gzip).padStart(6)} B gzip`
  // process.stdout, not console.log: other test files swap `console` for a stub.
  process.stdout.write(
    `${[
      "[phlex-reactive] client bundle sizes",
      ...sizes.map(row),
      `  core target (not asserted yet): ${TARGET_CORE_GZIP} B gzip — ${core.gzip - TARGET_CORE_GZIP} B to go`,
    ].join("\n")}\n`,
  )

  for (const { gzip } of sizes) expect(gzip).toBeGreaterThan(0)
})

test("early.min.js stays within its eager budget", () => {
  expect(sizeOf("early").gzip).toBeLessThanOrEqual(EARLY_GZIP_BUDGET)
})

test("the core does not grow past the ratchet", () => {
  expect(sizeOf("reactive_controller").gzip).toBeLessThanOrEqual(CORE_GZIP_CEILING)
})

test("the ratchet is tight: lower it when the core shrinks", () => {
  // A ceiling left far above the real size would let the core regrow
  // unnoticed. 250 B of slack is the rounding the ceiling is set with.
  expect(CORE_GZIP_CEILING - sizeOf("reactive_controller").gzip).toBeLessThan(250)
})
