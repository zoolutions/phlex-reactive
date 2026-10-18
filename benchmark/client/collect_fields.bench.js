// Micro-bench: #collectFields — the one walk over THIS root's named controls
// that auto-collects sibling inputs into the action params (Livewire-style),
// scoped so a nested reactive root's inputs don't bleed in (issue #15). It runs
// once per dispatch, before the fetch. Driven through the PUBLIC dispatch() over
// a REAL happy-dom form (faithful querySelectorAll / closest / .value), the same
// path reactive_collect_fields.test.js exercises.
//
// Grid sizes bracket the range: a 5-field form (a typical inline editor) and a
// 60-field grid (a dense line-item table). Each is benched with 0 and 2 NESTED
// reactive roots. Those are tokenless, so client-only and transparent (issue
// #410): the walk takes the fast path. The "nested server roots" variants carry
// a token each and measure the per-field ownership walk on a mixed tree (issue
// #15), with and without a shared field in each nested root (issue #434).
//
// happy-dom numbers are ENGINE-RELATIVE (see the docs performance page): a valid
// same-machine before/after delta, NOT an absolute browser cost.

import { bench, group } from "mitata"
import { makeDom, buildForm, buildController, dispatchOnce } from "./support/harness.js"

const { document } = await makeDom()

// Build a controller over a form fixture ONCE (fixtures are static: the walk is
// read-only, so a single fixture per shape is reused across iterations). Each
// bench dispatches on it; #collectFields walks the form inside #perform.
function fixture(fieldCount, nestedRoots, options = {}) {
  const root = buildForm(document, { fieldCount, nestedRoots, ...options })
  const controller = buildController(root)
  // A stubbed fetch so dispatch completes without a network; the walk already
  // ran by then. Wire the happy-dom document/window as the GLOBALS the perform
  // path reads (#actionPath/#csrfToken read the global `document`), plus Turbo +
  // navigator. Missing meta tags return "" via the controller's own optional
  // chaining — no throw.
  globalThis.document = document
  globalThis.window = document.defaultView
  globalThis.navigator = { onLine: true }
  document.defaultView.Turbo = { renderStreamMessage: () => {} }
  globalThis.fetch = () =>
    Promise.resolve({
      redirected: false,
      ok: true,
      status: 200,
      headers: { get: () => "text/vnd.turbo-stream.html" },
      text: () => Promise.resolve(""),
    })
  return controller
}

const form5 = fixture(5, 0)
const form5Nested = fixture(5, 2)
const grid60 = fixture(60, 0)
const grid60Nested = fixture(60, 2)
// Nested SERVER roots (a token each): the per-field ownership walk (issue #15),
// with and without a shared field in each (issue #434).
const grid60Server = fixture(60, 2, { nestedTokens: true })
const grid60Shared = fixture(60, 2, { nestedTokens: true, shared: true })

group("collectFields (dispatch → walk this root's named controls, issue #15 scoped)", () => {
  bench("5-field form, 0 nested roots", () => dispatchOnce(form5, "save"))
  bench("5-field form, 2 nested roots", () => dispatchOnce(form5Nested, "save"))
  bench("60-field grid, 0 nested roots", () => dispatchOnce(grid60, "save"))
  bench("60-field grid, 2 nested roots", () => dispatchOnce(grid60Nested, "save"))
  bench("60-field grid, 2 nested server roots", () => dispatchOnce(grid60Server, "save"))
  bench("60-field grid, 2 nested server roots, 1 shared field each", () => dispatchOnce(grid60Shared, "save"))
})
