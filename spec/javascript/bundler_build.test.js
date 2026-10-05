// A bundler app (esbuild, bun, Vite, webpack — anything that is not an import
// map) must be able to build BOTH client entries (issue #275):
//
//   phlex/reactive/reactive_controller  the default: one file, the core and
//       every feature already bundled in. It imports only the three seams an
//       app may override, by their bare names — as it always has. An app that
//       built before the client was split still builds, with the aliases it
//       already had, and gets no on-demand import at all.
//   phlex/reactive/core                 opt-in: reaches each feature with a
//       LITERAL dynamic import — import("phlex/reactive/features/persist") —
//       so a bundler can see the specifier. That needs ONE prefix alias for
//       the gem's JavaScript directory (README, "The split client").
//
// This builds stand-in app entries against the SHIPPED minified files, the way
// an app would, and checks what comes out.
//
// Run with: bun test spec/javascript
import { test, expect, beforeAll, afterAll } from "bun:test"
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const gemJs = join(dirname(fileURLToPath(import.meta.url)), "../../app/javascript")
// Text only ONE feature contains: persist's localStorage key prefix, the id
// prefix of the defer feature's stream source element, the unsaved guard's
// marker, the effect class prefix, the latency simulator's banner.
const FEATURE_MARKS = {
  persist: "phlex-reactive:persist:",
  defer: "reactive-defer-src-",
  form: "data-reactive-warn-unsaved",
  effects: "reactive-fx--",
  dev: "latency simulator ACTIVE",
}
const DYNAMIC_IMPORT = /import\(\s*["'][^"']+["']\s*\)/g

let app

beforeAll(() => {
  app = mkdtempSync(join(tmpdir(), "phlex-reactive-bundler-"))
  for (const entry of ["reactive_controller", "core"]) {
    writeFileSync(
      join(app, `${entry}_entry.js`),
      `import ReactiveController from "phlex/reactive/${entry}"\nexport default ReactiveController\n`,
    )
  }
  // The app's own Stimulus — stubbed, since the gem does not ship one.
  writeFileSync(join(app, "stimulus.js"), "export class Controller {}\n")
})

afterAll(() => rmSync(app, { recursive: true, force: true }))

const shipped = (name) => join(gemJs, `phlex/reactive/${name}.min.js`)
const stimulus = (build) => build.onResolve({ filter: /^@hotwired\/stimulus$/ }, () => ({ path: join(app, "stimulus.js") }))

// What an app that set the client up BEFORE the split has: the controller and
// its three seams, one exact alias each. Nothing for phlex/reactive/features.
const legacyAliases = {
  name: "legacy-exact-aliases",
  setup(build) {
    stimulus(build)
    for (const name of ["reactive_controller", "confirm", "confirm_predicate", "compute"]) {
      build.onResolve({ filter: new RegExp(`^phlex/reactive/${name}$`) }, () => ({ path: shipped(name) }))
    }
    // Any OTHER phlex/reactive specifier is one this app never aliased.
    build.onResolve({ filter: /^phlex\/reactive\// }, ({ path }) => {
      throw new Error(`unaliased: ${path}`)
    })
  },
}

// The one prefix alias the README gives for the split client.
const prefixAlias = {
  name: "phlex-reactive-prefix-alias",
  setup(build) {
    stimulus(build)
    build.onResolve({ filter: /^phlex\/reactive\// }, ({ path }) => ({ path: join(gemJs, `${path}.min.js`) }))
  },
}

async function bundle(entry, plugin, options = {}) {
  const outdir = join(app, `out-${entry}-${plugin.name}-${Object.keys(options).join("-") || "plain"}`)
  const result = await Bun.build({ entrypoints: [join(app, `${entry}_entry.js`)], outdir, plugins: [plugin], ...options })
  return {
    result,
    files: result.outputs.map((output) => ({ path: output.path, kind: output.kind, text: readFileSync(output.path, "utf8") })),
  }
}

const unresolved = (files) => files.filter(({ text }) => /(?:from\s*|import\(\s*)["']phlex\/reactive\//.test(text))

// --- the default entry ------------------------------------------------------------

test("the default entry builds with the aliases an app had before the split — no feature alias needed", async () => {
  const { result, files } = await bundle("reactive_controller", legacyAliases)

  expect(result.logs.filter((log) => log.level === "error")).toEqual([])
  expect(result.success).toBe(true)
  expect(unresolved(files)).toEqual([])
})

test("the default entry carries every feature and imports nothing on demand, with or without code splitting", async () => {
  for (const options of [{}, { splitting: true }]) {
    const { result, files } = await bundle("reactive_controller", legacyAliases, options)

    expect(result.success).toBe(true)
    const entry = files.find((file) => file.kind === "entry-point")
    for (const mark of Object.values(FEATURE_MARKS)) expect(entry.text).toContain(mark)
    expect(entry.text.match(DYNAMIC_IMPORT)).toBeNull()
  }
})

test("the shipped default bundle itself has no dynamic import and imports only the seams", () => {
  const text = readFileSync(shipped("reactive_controller"), "utf8")

  expect(text.match(DYNAMIC_IMPORT)).toBeNull()
  // Its only imports are Stimulus and the three override seams, by bare name:
  // no core, no feature. (The feature specifier still appears as TEXT, in the
  // loader's failure message — a message this build can never log.)
  expect([...text.matchAll(/from"([^"]+)"/g)].map(([, specifier]) => specifier).sort()).toEqual([
    "@hotwired/stimulus",
    "phlex/reactive/compute",
    "phlex/reactive/confirm",
    "phlex/reactive/confirm_predicate",
  ])
})

// --- the opt-in split core ----------------------------------------------------------

test("the split core fails to build with the old exact aliases, naming the feature it cannot find", async () => {
  const legacyPlusCore = {
    name: "legacy-plus-core",
    setup(build) {
      build.onResolve({ filter: /^phlex\/reactive\/core$/ }, () => ({ path: shipped("core") }))
      legacyAliases.setup(build)
    },
  }
  let failure = ""
  try {
    const { result } = await bundle("core", legacyPlusCore)
    failure = result.success ? "BUILD SUCCEEDED" : result.logs.map((log) => String(log.message ?? log)).join("\n")
  } catch (error) {
    failure = [error.message, ...(error.errors ?? []).map((inner) => inner.message)].join("\n")
  }

  expect(failure).not.toBe("BUILD SUCCEEDED")
  expect(failure).toContain("phlex/reactive/features/")
})

test("with the prefix alias the split core resolves its seams and its feature modules", async () => {
  const { result, files } = await bundle("core", prefixAlias)

  expect(result.logs.filter((log) => log.level === "error")).toEqual([])
  expect(result.success).toBe(true)
  expect(unresolved(files)).toEqual([])
})

test("with code splitting each feature of the split core is its own chunk, loaded by a dynamic import", async () => {
  const { result, files } = await bundle("core", prefixAlias, { splitting: true })

  expect(result.success).toBe(true)
  const entry = files.find((file) => file.kind === "entry-point")
  for (const mark of Object.values(FEATURE_MARKS)) {
    // The feature's code is NOT in the entry chunk a page always loads …
    expect(entry.text).not.toContain(mark)
    // … it is in one chunk of its own …
    expect(files.filter((file) => file.text.includes(mark))).toHaveLength(1)
  }
  // … and every feature is a different chunk …
  const chunkOf = (mark) => files.find((file) => file.text.includes(mark)).path
  expect(new Set(Object.values(FEATURE_MARKS).map(chunkOf)).size).toBe(Object.keys(FEATURE_MARKS).length)
  // … which the entry still reaches through dynamic imports.
  expect(entry.text.match(DYNAMIC_IMPORT)).toHaveLength(Object.keys(FEATURE_MARKS).length)
})

test("without code splitting the split core's features are bundled in and the build still succeeds", async () => {
  const { result, files } = await bundle("core", prefixAlias)

  expect(result.success).toBe(true)
  for (const mark of Object.values(FEATURE_MARKS)) {
    expect(files.filter((file) => file.text.includes(mark))).toHaveLength(1)
  }
})
