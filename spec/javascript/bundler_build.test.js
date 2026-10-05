// A bundler app (esbuild, bun, Vite, webpack — anything that is not an import
// map) must still be able to build the client now that it is a core plus
// feature modules (issue #275).
//
// The controller reaches a feature with a LITERAL dynamic import —
// import("phlex/reactive/features/persist") — so a bundler can see the
// specifier at build time. The app's side of the bargain is ONE alias for the
// gem's JavaScript directory (README, "esbuild / webpack / bun"), which covers
// the controller, its seams (confirm, compute, …) and every feature at once.
//
// This builds a stand-in app entry against the SHIPPED minified files with
// exactly that alias, the way an app would, and checks what comes out.
//
// Run with: bun test spec/javascript
import { test, expect, beforeAll, afterAll } from "bun:test"
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const gemJs = join(dirname(fileURLToPath(import.meta.url)), "../../app/javascript")
// Text only the persist feature contains: its localStorage key prefix.
const PERSIST_MARK = "phlex-reactive:persist:"

let app

beforeAll(() => {
  app = mkdtempSync(join(tmpdir(), "phlex-reactive-bundler-"))
  writeFileSync(
    join(app, "entry.js"),
    `import ReactiveController from "phlex/reactive/reactive_controller"\nexport default ReactiveController\n`,
  )
  // The app's own Stimulus — stubbed, since the gem does not ship one.
  writeFileSync(join(app, "stimulus.js"), "export class Controller {}\n")
})

afterAll(() => rmSync(app, { recursive: true, force: true }))

// The alias from the README, as a resolver plugin: phlex/reactive/<path>
// -> <gem>/app/javascript/phlex/reactive/<path>.min.js
const gemAlias = {
  name: "phlex-reactive-alias",
  setup(build) {
    build.onResolve({ filter: /^phlex\/reactive\// }, ({ path }) => ({ path: join(gemJs, `${path}.min.js`) }))
    build.onResolve({ filter: /^@hotwired\/stimulus$/ }, () => ({ path: join(app, "stimulus.js") }))
  },
}

async function bundle(options = {}) {
  const outdir = join(app, `out-${Object.keys(options).join("-") || "plain"}`)
  const result = await Bun.build({ entrypoints: [join(app, "entry.js")], outdir, plugins: [gemAlias], ...options })
  return {
    result,
    files: result.outputs.map((output) => ({ path: output.path, kind: output.kind, text: readFileSync(output.path, "utf8") })),
  }
}

test("the app's one alias resolves the controller, its seams and its feature modules", async () => {
  const { result, files } = await bundle()

  expect(result.logs.filter((log) => log.level === "error")).toEqual([])
  expect(result.success).toBe(true)
  // Nothing of the gem is left as an unresolved bare specifier.
  for (const { text } of files) expect(text).not.toMatch(/from\s*["']phlex\/reactive\//)
  for (const { text } of files) expect(text).not.toMatch(/import\(\s*["']phlex\/reactive\//)
})

test("with code splitting the feature is its own chunk, loaded by a dynamic import", async () => {
  const { result, files } = await bundle({ splitting: true })

  expect(result.success).toBe(true)
  const entry = files.find((file) => file.kind === "entry-point")
  const withPersist = files.filter((file) => file.text.includes(PERSIST_MARK))
  // The draft code is NOT in the entry chunk a page always loads …
  expect(entry.text).not.toContain(PERSIST_MARK)
  // … it is in one chunk of its own …
  expect(withPersist).toHaveLength(1)
  // … which the entry still reaches through a dynamic import.
  expect(entry.text).toMatch(/import\(\s*["']\.\/[^"']+["']\s*\)/)
})

test("without code splitting the feature is bundled in and the build still succeeds", async () => {
  const { result, files } = await bundle()

  expect(result.success).toBe(true)
  expect(files.filter((file) => file.text.includes(PERSIST_MARK))).toHaveLength(1)
})
