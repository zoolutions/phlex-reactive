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
//   "phlex/reactive/confirm"` — and how the opt-in client reaches a feature
//   module on demand. And it is why the specifiers are bare, never relative:
//   Propshaft serves each file under its own digest, and a relative sibling
//   import inside a digested file 404s (issue #57).
//
//   The two client entries — each ONE file with the shared runtime
//   (runtime.js: the controller) bundled in:
//
//     reactive_controller.min.js   the default: the runtime and every feature
//                                  module. It is what
//                                  `phlex/reactive/reactive_controller` has
//                                  always meant: import one module, get the
//                                  whole client, nothing fetched later. It
//                                  contains no import() at all.
//     core.min.js                  opt-in: the runtime and the table of
//                                  import("phlex/reactive/features/<name>")
//                                  calls. The features stay EXTERNAL here —
//                                  real dynamic imports of their own files.
//
//   What is bundled is only OUR OWN code that an app has no reason to
//   replace. The override seams (confirm, confirm_predicate, compute) and
//   Stimulus stay external in both entries exactly as in the per-file modules,
//   so an app's `setConfirmResolver` still reaches the one registry the entry
//   reads, and there is still no relative import for Propshaft to trip over.
//   The runtime is never a file of its own: an app loads one entry, and each
//   carries its copy (loading both is an error the runtime reports).
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
// A "features/<name>" entry is a feature module the opt-in client imports on
// demand, by the bare specifier phlex/reactive/features/<name>.
// lib/phlex/reactive/engine.rb
// (CLIENT_FEATURES) pins and precompiles the same names;
// spec/phlex/engine_client_pin_spec.rb fails when the two lists differ.
const ENTRIES = [
  "early",
  "confirm",
  "confirm_predicate",
  "compute",
  "inspect",
  "features/persist",
  "features/defer",
  "features/form",
  "features/effects",
  "features/dev",
]

// The default entry: the runtime + every feature in one file.
const BUNDLE = "reactive_controller"
// The opt-in entry: the runtime + where to import each feature from.
const SPLIT = "core"

// The seams an app may override, and Stimulus: external in EVERY output.
const SEAMS = ["@hotwired/stimulus", "phlex/reactive/confirm", "phlex/reactive/confirm_predicate", "phlex/reactive/compute"]

// External in the opt-in entry too: its import("phlex/reactive/features/…")
// must stay a real dynamic import of the feature's own file. (The default
// entry inlines the features, resolving them through tsconfig.json's paths.)
const FEATURES_EXTERNAL = [...SEAMS, "phlex/reactive/features/*"]

// Remove stale artifacts first so a renamed/removed entry can't leave a ghost.
for (const name of [...ENTRIES, BUNDLE, SPLIT]) {
  await rm(join(srcDir, `${name}.min.js`), { force: true })
  await rm(join(srcDir, `${name}.min.js.map`), { force: true })
}

// The `export function __…ForTest` seams of the runtime and of the opt-in
// entry exist for the JS suite, which
// imports the SOURCE. They are bytes every page would download, so the shipped
// builds drop them. Each is a top-level function closed by a `}` in column 0;
// anything else named that way fails the build below.
const TEST_SEAM = /^export function __\w+ForTest\([^)]*\) \{\n(?:(?!\}\n)[^\n]*\n)*\}\n/gm
const stripTestSeams = {
  name: "strip-test-seams",
  setup(build) {
    build.onLoad({ filter: /\/reactive\/(runtime|core)\.js$/ }, async ({ path }) => {
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
  await Bun.build({ ...shared, entrypoints: ENTRIES.map((name) => join(srcDir, `${name}.js`)), external: SEAMS }),
  await Bun.build({ ...shared, entrypoints: [join(srcDir, `${BUNDLE}.js`)], external: SEAMS }),
  await Bun.build({ ...shared, entrypoints: [join(srcDir, `${SPLIT}.js`)], external: FEATURES_EXTERNAL }),
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
