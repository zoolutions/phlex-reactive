// Shared harness for the client micro-benches (issue #116).
//
// The benches drive the reactive controller's PUBLIC surface only — dispatch()
// and recompute() — the same way the JS test suite does. Nothing here imports a
// private (`#`) method or adds a `__bench` export to the shipped controller (an
// app/javascript/ edit would trip the vendored-sync rule; the whole point of
// this issue is PURE TOOLING). We reach the private hot paths (#extractToken,
// #collectFields) THROUGH dispatch, exactly as reactive_extract_token.test.js /
// reactive_collect_fields.test.js reach them.
//
// Two DOM strategies, matching the issue spec:
//   - extractToken is a pure regex pass over the RESPONSE string, so its bench
//     uses the same lightweight fake root the token test uses (id + empty field
//     walk) — the DOM is irrelevant, only the body string size matters.
//   - collectFields / recompute walk a REAL form, so those use a happy-dom
//     Window (a JS DOM engine) for faithful querySelectorAll / closest / form
//     control semantics. happy-dom numbers are ENGINE-RELATIVE (see the docs
//     performance page): valid for same-machine before/after deltas, not an
//     absolute browser cost.

import ReactiveController from "../../../app/javascript/phlex/reactive/reactive_controller.js"

// --- extractToken: fake root + stubbed fetch (no DOM engine needed) ----------

// A reactive root faithful enough for #perform: an id, an empty field walk
// (querySelectorAll -> []), and the attribute toggles. Mirrors the fakeRoot in
// reactive_extract_token.test.js so the benched path is the tested path.
export function fakeRoot(id) {
  const attrs = {}
  return {
    id,
    querySelectorAll: () => [],
    setAttribute: (name, value) => {
      attrs[name] = value
    },
    removeAttribute: (name) => {
      delete attrs[name]
    },
    getAttribute: (name) => attrs[name] ?? null,
  }
}

// Minimal document/window stubs for the extractToken path — #perform reads the
// action-path/csrf meta and hands the body to Turbo.renderStreamMessage.
export function stubExtractEnv() {
  globalThis.document = {
    querySelector: (sel) => {
      if (sel.includes("action-path")) return { content: "/reactive/actions" }
      if (sel.includes("csrf-token")) return { content: "csrf-abc" }
      return null
    },
    dispatchEvent: () => {},
  }
  globalThis.window = { Turbo: { renderStreamMessage: () => {} } }
  globalThis.navigator = { onLine: true }
}

// Stub fetch to return a fixed turbo-stream body — the string #extractToken
// regex-scans. No `captured` array: the bench only cares about the parse cost.
export function stubFetchReturning(body) {
  globalThis.fetch = () =>
    Promise.resolve({
      redirected: false,
      ok: true,
      status: 200,
      headers: { get: () => "text/vnd.turbo-stream.html" },
      text: () => Promise.resolve(body),
    })
}

// Build a controller bound to `rootEl` with an initial token, matching the test
// harness (element + tokenValue are the only two fields dispatch/perform need).
export function buildController(rootEl, initialToken = "TOKEN-INITIAL") {
  const controller = new ReactiveController()
  controller.element = rootEl
  controller.tokenValue = initialToken
  return controller
}

// One dispatch call — the public entry the bench measures. A synthetic event
// with the minimal params shape dispatch() reads.
export function dispatchOnce(controller, action = "go") {
  return controller.dispatch({
    params: { action, params: "{}" },
    preventDefault: () => {},
  })
}

// --- happy-dom: real DOM for collectFields / recompute -----------------------

// Build a happy-dom Window and return { window, document } — a real DOM engine
// so querySelectorAll / closest / .value / .checked behave like a browser's.
// happy-dom is engine-relative (not V8/JSC-in-a-browser), but a same-machine
// before/after over it is a valid delta.
//
// The controller builds events with the BARE globals `new CustomEvent(...)` /
// `new Event(...)` (see #emit, the compute input dispatch). happy-dom validates
// that a dispatched event is an instanceof ITS OWN Event class, so we mirror the
// window's DOM event constructors onto globalThis — otherwise a global
// CustomEvent produces a node happy-dom's dispatchEvent rejects. (We don't pull
// in @happy-dom/global-registrator for this one need.)
//
// ONE Window for every bench that asks (memoized): the benches register at
// import time and run later, so the globals the last caller installed are the
// ones every bench runs under — a second Window would hand the others a
// foreign Event class.
let dom
export async function makeDom() {
  if (dom) return dom
  const { Window } = await import("happy-dom")
  const window = new Window({ url: "http://localhost/" })
  globalThis.Event = window.Event
  globalThis.CustomEvent = window.CustomEvent
  return (dom = { window, document: window.document })
}

// A reactive root <div> with a form of `fieldCount` text inputs (name="f0"…),
// optionally nesting `nestedRoots` INNER reactive roots each holding two inputs.
// The nested inputs must NOT be collected by the outer root (#ownsField scopes
// to the nearest data-controller~="reactive" ancestor, issue #15) — so a nested
// fixture measures the ownership-filter cost on a realistic mixed tree.
export function buildForm(document, { fieldCount, nestedRoots = 0 }) {
  const root = document.createElement("div")
  root.setAttribute("data-controller", "reactive")
  root.id = "form-root"

  for (let i = 0; i < fieldCount; i++) {
    const input = document.createElement("input")
    input.setAttribute("type", "text")
    input.setAttribute("name", `f${i}`)
    input.value = `v${i}`
    root.appendChild(input)
  }

  for (let n = 0; n < nestedRoots; n++) {
    const nested = document.createElement("div")
    nested.setAttribute("data-controller", "reactive")
    nested.id = `nested-${n}`
    for (const name of ["nq", "np"]) {
      const input = document.createElement("input")
      input.setAttribute("type", "text")
      input.setAttribute("name", `${name}${n}`)
      input.value = "9"
      nested.appendChild(input)
    }
    root.appendChild(nested)
  }

  document.body.appendChild(root)
  return root
}

// A reactive root wired for recompute: a `data-reactive-compute-*` calculator
// with `fieldCount` numeric inputs (name="in0"…) feeding a registered reducer
// that sums them into a single `sum` output field. Registers the reducer in the
// compute registry under `key`. Returns { root, firstInput } — the bench calls
// controller.recompute({ target: firstInput }) so meta.changed resolves like a
// real keystroke.
export async function buildCalculator(document, { fieldCount, key = "bench_sum" }) {
  const { setComputeReducer } = await import("../../../app/javascript/phlex/reactive/compute.js")

  const inputs = Array.from({ length: fieldCount }, (_, i) => `in${i}`)
  setComputeReducer(key, (values) => ({
    sum: inputs.reduce((acc, name) => acc + (values[name] || 0), 0),
  }))

  const root = document.createElement("div")
  root.setAttribute("data-controller", "reactive")
  root.id = "calc-root"
  root.setAttribute("data-reactive-compute-reducer-param", key)
  root.setAttribute("data-reactive-compute-inputs-param", JSON.stringify(inputs))
  root.setAttribute("data-reactive-compute-outputs-param", JSON.stringify(["sum"]))

  let firstInput = null
  for (let i = 0; i < fieldCount; i++) {
    const input = document.createElement("input")
    input.setAttribute("type", "number")
    input.setAttribute("name", `in${i}`)
    input.value = String(i + 1)
    root.appendChild(input)
    if (i === 0) firstInput = input
  }

  const output = document.createElement("input")
  output.setAttribute("type", "number")
  output.setAttribute("name", "sum")
  output.value = "0"
  root.appendChild(output)

  document.body.appendChild(root)
  return { root, firstInput }
}
