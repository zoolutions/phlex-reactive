// Regression test for issue #57: the reactive controller's confirm import must
// be the BARE, importmap-pinned specifier `phlex/reactive/confirm`, NOT a
// relative `./confirm.js`.
//
// Under importmap-rails + Propshaft, a relative specifier inside a pinned (and
// therefore DIGESTED) module is left untouched — Propshaft's JS compiler only
// rewrites `RAILS_ASSET_URL(...)`, never `import`/`from`, and the import map
// maps ONLY bare specifiers, never relative-resolved URLs. So the browser
// resolves `./confirm.js` against the digested controller URL and requests an
// undigested `/assets/phlex/reactive/confirm.js`, which 404s. The throwing
// import then cascades: in an app that eagerly registers the controller, the
// whole controllers entrypoint dies and EVERY Stimulus controller stops.
//
// The bare specifier `phlex/reactive/confirm` is the one the engine already
// pins (and apps already import via README), so it resolves to the digested URL
// through the import map. For bundlers/bun the same bare specifier resolves via
// the project's module-resolution config (tsconfig `paths`), exactly like the
// app-side `phlex/reactive/reactive_controller` import.
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll } from "bun:test"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"

// The confirm import lives in the shared runtime (runtime.js); the default entry
// (reactive_controller.js) bundles the core and leaves this seam external.
const SOURCE = fileURLToPath(new URL("../../app/javascript/phlex/reactive/runtime.js", import.meta.url))

let ReactiveController
let confirmModule

beforeAll(async () => {
  mock.module("@hotwired/stimulus", () => ({
    Controller: class {
      constructor() {}
    },
  }))
  // If the bare specifier `phlex/reactive/confirm` does not resolve (no tsconfig
  // `paths` mapping), this import throws and the suite goes red — the same
  // failure shape an importmap app hits when the pin is missing.
  ReactiveController = (await import("../../app/javascript/phlex/reactive/reactive_controller.js")).default
  confirmModule = await import("../../app/javascript/phlex/reactive/confirm.js")
})

test("the controller module imports (bare confirm specifier resolves)", () => {
  expect(typeof ReactiveController).toBe("function")
  expect(typeof confirmModule.confirmResolver).toBe("function")
})

test("source imports the bare `phlex/reactive/confirm`, never a relative path (issue #57)", () => {
  const source = readFileSync(SOURCE, "utf8")
  // The bare, importmap-pinnable specifier must be present...
  expect(source).toContain('from "phlex/reactive/confirm"')
  // ...and the relative form that 404s under importmap + Propshaft must be gone.
  expect(source).not.toContain('from "./confirm.js"')
  expect(source).not.toContain("from './confirm.js'")
})
