// Builds the minified, production client runtime from the commented source.
//
//   bun run scripts/build_client.js      # or: rake build:js
//
// The authored source under app/javascript/phlex/reactive/*.js is the artifact
// developers read and the JS test suite imports directly — it is intentionally
// comment-dense (the source IS the documentation). Browsers, though, should not
// pay for ~86 KB of comments on every page load, so the gem also ships a
// minified twin of each module (about a fifth of the source) with a
// linked sourcemap so devtools still shows the real code.
//
// Why per-file minify, NOT a single bundle:
//   The three modules are pinned SEPARATELY in the import map so an app can
//   override the seams — `import { setConfirmResolver } from
//   "phlex/reactive/confirm"`. Bundling would inline confirm/compute into the
//   controller and break those overrides. So each entry is minified on its own
//   and the cross-module imports (@hotwired/stimulus, phlex/reactive/confirm,
//   phlex/reactive/compute) stay EXTERNAL — emitted verbatim as bare specifiers
//   that resolve through the import map, exactly like the source does.
//
// The output is DETERMINISTIC (bun derives the sourcemap debugId from content),
// so the committed .min.js/.min.js.map never churn between builds — that's what
// lets us check them in and gate CI on `git diff --exit-code`.

import { rm } from "node:fs/promises"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const root = join(dirname(fileURLToPath(import.meta.url)), "..")
const srcDir = join(root, "app/javascript/phlex/reactive")

// The modules that ship to the browser. Order is cosmetic (build log only).
// A "features/<name>" entry is a feature module (issue #275): the controller
// imports it on demand, by the bare specifier phlex/reactive/features/<name>.
// lib/phlex/reactive/engine.rb (CLIENT_FEATURES) pins and precompiles the same
// names; spec/phlex/engine_client_pin_spec.rb fails when the two lists differ.
const ENTRIES = ["reactive_controller", "early", "confirm", "confirm_predicate", "compute", "inspect", "features/persist"]

// Kept external so a minified module imports its sibling by the SAME bare
// specifier the source uses — the import map (engine.rb pins) maps each to its
// own .min.js. Bundling any of these would break app-level overrides.
const EXTERNAL = [
  "@hotwired/stimulus",
  "phlex/reactive/confirm",
  "phlex/reactive/confirm_predicate",
  "phlex/reactive/compute",
  // Every feature module: the controller's import("phlex/reactive/features/…")
  // must stay a real dynamic import of its own file, never be inlined.
  "phlex/reactive/features/*",
]

// Remove stale artifacts first so a renamed/removed entry can't leave a ghost.
for (const name of ENTRIES) {
  await rm(join(srcDir, `${name}.min.js`), { force: true })
  await rm(join(srcDir, `${name}.min.js.map`), { force: true })
}

const result = await Bun.build({
  entrypoints: ENTRIES.map((name) => join(srcDir, `${name}.js`)),
  outdir: srcDir,
  // Entries live in more than one directory (features/): anchor the output
  // layout on the source directory so features/persist.js lands beside it.
  root: srcDir,
  minify: true,
  sourcemap: "linked",
  external: EXTERNAL,
  naming: "[dir]/[name].min.[ext]",
})

if (!result.success) {
  for (const log of result.logs) console.error(log)
  process.exit(1)
}

for (const output of result.outputs) {
  console.log(`  ${output.path.replace(`${root}/`, "")}  ${output.size} bytes`)
}
