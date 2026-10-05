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
// TWO KINDS OF OUTPUT (issue #275):
//
//   Per-file modules — every entry in ENTRIES is minified ON ITS OWN, and what
//   it imports stays EXTERNAL: emitted verbatim as a bare specifier that the
//   import map (the engine's pins) resolves to that module's own .min.js.
//   That is how an app overrides a seam — `import { setConfirmResolver } from
//   "phlex/reactive/confirm"` — and how the opt-in phlex/reactive/core reaches
//   a feature module on demand. And it is why the specifiers are bare, never
//   relative: Propshaft serves each file under its own digest, and a relative
//   sibling import inside a digested file 404s (issue #57).
//
//   The default bundle — reactive_controller.min.js is ONE file: the core and
//   every feature module, bundled. It is what `phlex/reactive/reactive_controller`
//   has always meant: import one module, get the whole client, nothing fetched
//   later. What is bundled is only OUR OWN code that an app has no reason to
//   replace. The override seams (confirm, confirm_predicate, compute) and
//   Stimulus stay external in the bundle exactly as in the per-file modules,
//   so an app's `setConfirmResolver` still reaches the one registry the bundle
//   reads, and there is still no relative import for Propshaft to trip over.
//
// The output is DETERMINISTIC for the bun pinned in .bun-version (bun derives
// the sourcemap debugId from content), so the committed .min.js/.min.js.map
// never churn between builds — that's what lets us check them in and gate CI
// on `git diff --exit-code`.

import { rm } from "node:fs/promises"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const root = join(dirname(fileURLToPath(import.meta.url)), "..")
const srcDir = join(root, "app/javascript/phlex/reactive")

// The per-file modules. Order is cosmetic (build log only).
// "core" is the opt-in controller without its features; a "features/<name>"
// entry is a feature module the core imports on demand, by the bare specifier
// phlex/reactive/features/<name>. lib/phlex/reactive/engine.rb
// (CLIENT_FEATURES) pins and precompiles the same names;
// spec/phlex/engine_client_pin_spec.rb fails when the two lists differ.
const ENTRIES = ["core", "early", "confirm", "confirm_predicate", "compute", "inspect", "features/persist", "features/defer"]

// The default bundle: core + every feature in one file.
const BUNDLE = "reactive_controller"

// The seams an app may override, and Stimulus: external in EVERY output.
const SEAMS = ["@hotwired/stimulus", "phlex/reactive/confirm", "phlex/reactive/confirm_predicate", "phlex/reactive/compute"]

// External in the per-file modules only: the core's
// import("phlex/reactive/features/…") must stay a real dynamic import of the
// feature's own file. (The bundle inlines both, resolving them through
// tsconfig.json's paths.)
const EXTERNAL = [...SEAMS, "phlex/reactive/core", "phlex/reactive/features/*"]

// Remove stale artifacts first so a renamed/removed entry can't leave a ghost.
for (const name of [...ENTRIES, BUNDLE]) {
  await rm(join(srcDir, `${name}.min.js`), { force: true })
  await rm(join(srcDir, `${name}.min.js.map`), { force: true })
}

// The core's `export function __…ForTest` seams exist for the JS suite, which
// imports the SOURCE. They are bytes every page would download, so the shipped
// builds drop them. Each is a top-level function closed by a `}` in column 0;
// anything else named that way fails the build below.
const TEST_SEAM = /^export function __\w+ForTest\([^)]*\) \{\n(?:(?!\}\n)[^\n]*\n)*\}\n/gm
const stripTestSeams = {
  name: "strip-test-seams",
  setup(build) {
    build.onLoad({ filter: /\/reactive\/core\.js$/ }, async ({ path }) => {
      const contents = (await Bun.file(path).text()).replace(TEST_SEAM, "")
      if (/ForTest/.test(contents.replace(/^\s*\/\/.*$/gm, ""))) {
        throw new Error(`${path}: a __…ForTest seam survived the strip — keep seams top-level, one function each`)
      }
      return { contents, loader: "js" }
    })
  },
}

const shared = {
  plugins: [stripTestSeams],
  outdir: srcDir,
  // Entries live in more than one directory (features/): anchor the output
  // layout on the source directory so features/persist.js lands beside it.
  root: srcDir,
  minify: true,
  sourcemap: "linked",
  naming: "[dir]/[name].min.[ext]",
}

const builds = [
  await Bun.build({ ...shared, entrypoints: ENTRIES.map((name) => join(srcDir, `${name}.js`)), external: EXTERNAL }),
  await Bun.build({ ...shared, entrypoints: [join(srcDir, `${BUNDLE}.js`)], external: SEAMS }),
]

for (const result of builds) {
  if (!result.success) {
    for (const log of result.logs) console.error(log)
    process.exit(1)
  }
  for (const output of result.outputs) {
    console.log(`  ${output.path.replace(`${root}/`, "")}  ${output.size} bytes`)
  }
}
