// Unit tests for the dev-mode zero-target op warning (issue #237).
//
// A client op that resolves ZERO targets is indistinguishable from a working
// no-op — and three documented scoping traps (nested-root ownership filter,
// root-self selector, stream default scope) all present exactly that way. Under
// the verbose gate (data-reactive-verbose, stamped by verbose_errors — or the
// existing data-reactive-debug) the interpreter console.warns ONCE per unique
// (op, selector, scope) with the op, the selector, the scoping root, and a
// targeted hint (`to: :root` / `global: true`) when the element EXISTS but sits
// outside the op's scope. With both gates off (production) behavior is
// byte-identical to before: silent.
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll } from "bun:test"

let ReactiveController
let registerReactiveJs

beforeAll(async () => {
  mock.module("@hotwired/stimulus", () => ({
    Controller: class {
      constructor() {}
    },
  }))
  const mod = await import("../../app/javascript/phlex/reactive/reactive_controller.js")
  ReactiveController = mod.default
  registerReactiveJs = mod.registerReactiveJs
})

// A fake DOM node owned by `owner` (its nearest reactive root, via closest).
function makeEl({ owner = null } = {}) {
  const el = {
    hidden: false,
    classes: new Set(),
    closest: () => owner,
  }
  el.classList = {
    add: (...cs) => cs.forEach((c) => el.classes.add(c)),
    remove: (...cs) => cs.forEach((c) => el.classes.delete(c)),
    toggle: (c) => (el.classes.has(c) ? el.classes.delete(c) : el.classes.add(c)),
  }
  return el
}

// A reactive root: `attrs` answers getAttribute (the verbose/debug gate),
// `matches` answers the selector-matches-the-root-itself probe, and
// querySelectorAll resolves from a selector -> elements map.
function makeRoot({ id = "tabs", attrs = {}, matches = {}, selfMatches = () => false } = {}) {
  return {
    isConnected: true,
    id,
    hidden: false,
    getAttribute: (name) => attrs[name] ?? null,
    setAttribute: () => {},
    removeAttribute: () => {},
    dispatchEvent: () => {},
    contains: (el) => el?.__inside === true,
    matches: selfMatches,
    querySelectorAll: (sel) => matches[sel] ?? [],
  }
}

// Fresh globals per controller. Reassigning globalThis.document also resets the
// warn dedupe, which is keyed per document (per page lifetime in the browser).
function buildController(root, { documentMatches = {} } = {}) {
  const controller = new ReactiveController()
  controller.element = root
  globalThis.fetch = () => {
    throw new Error("runOps must NEVER fetch")
  }
  globalThis.document = {
    querySelector: () => null,
    querySelectorAll: (sel) => documentMatches[sel] ?? [],
    dispatchEvent: () => {},
  }
  globalThis.window = { Turbo: { renderStreamMessage: () => {} } }
  return controller
}

function fire(controller, ops) {
  const event = {
    params: { ops },
    target: { __inside: false },
    defaultPrevented: false,
    preventDefault() {
      this.defaultPrevented = true
    },
  }
  controller.runOps(event)
  return event
}

function captureWarns(run) {
  const warns = []
  const original = console.warn
  console.warn = (...args) => warns.push(args.join(" "))
  try {
    run()
  } finally {
    console.warn = original
  }
  return warns
}

const VERBOSE = { "data-reactive-verbose": "true" }

// --- gating -----------------------------------------------------------------

test("gate off (production): a zero-target op stays completely silent", () => {
  const controller = buildController(makeRoot())

  const warns = captureWarns(() => fire(controller, [["hide", { to: "#gone" }]]))

  expect(warns.length).toBe(0)
})

test("data-reactive-verbose gates the warning on: op, selector, and root id are named", () => {
  const controller = buildController(makeRoot({ attrs: VERBOSE }))

  const warns = captureWarns(() => fire(controller, [["hide", { to: "#gone" }]]))

  expect(warns.length).toBe(1)
  expect(warns[0]).toContain("hide")
  expect(warns[0]).toContain("#gone")
  expect(warns[0]).toContain("#tabs")
})

test("a blur whose target is missing warns under the gate (issue #399)", () => {
  const controller = buildController(makeRoot({ attrs: VERBOSE }))

  const warns = captureWarns(() => fire(controller, [["blur", { to: "#menu" }]]))

  expect(warns.length).toBe(1)
  expect(warns[0]).toContain("blur")
  expect(warns[0]).toContain("#menu")
})

test("data-reactive-debug ALONE also gates the warning on (debug users get no less)", () => {
  const controller = buildController(makeRoot({ attrs: { "data-reactive-debug": "true" } }))

  const warns = captureWarns(() => fire(controller, [["hide", { to: "#gone" }]]))

  expect(warns.length).toBe(1)
})

// --- the hint ladder ---------------------------------------------------------

test("selector matching the component's own root hints to: :root", () => {
  const root = makeRoot({ attrs: VERBOSE, selfMatches: (sel) => sel === "#tabs" })
  const controller = buildController(root)

  const warns = captureWarns(() => fire(controller, [["hide", { to: "#tabs" }]]))

  expect(warns.length).toBe(1)
  expect(warns[0]).toContain(":root")
})

test("selector matching only inside a nested reactive root hints global: true", () => {
  const root = makeRoot({ attrs: VERBOSE })
  const nestedRoot = makeRoot({ id: "nested" })
  const theirs = makeEl({ owner: nestedRoot }) // ownership-filtered out
  root.querySelectorAll = () => [theirs]
  const controller = buildController(root)

  const warns = captureWarns(() => fire(controller, [["hide", { to: ".panel" }]]))

  expect(warns.length).toBe(1)
  expect(warns[0]).toContain("nested reactive root")
  expect(warns[0]).toContain("global: true")
  expect(theirs.hidden).toBe(false) // the op still did NOT apply (behavior unchanged)
})

test("selector matching elsewhere in the document hints global: true", () => {
  const outside = makeEl()
  const controller = buildController(makeRoot({ attrs: VERBOSE }), {
    documentMatches: { "#overlay": [outside] },
  })

  const warns = captureWarns(() => fire(controller, [["hide", { to: "#overlay" }]]))

  expect(warns.length).toBe(1)
  expect(warns[0]).toContain("global: true")
})

test("a global: true op that matches nothing anywhere warns plainly (no hint)", () => {
  const controller = buildController(makeRoot({ attrs: VERBOSE }))

  const warns = captureWarns(() => fire(controller, [["hide", { to: "#gone", global: true }]]))

  expect(warns.length).toBe(1)
  expect(warns[0]).toContain("#gone")
  expect(warns[0]).not.toContain("global: true")
})

// --- never-warn cases --------------------------------------------------------

test('"@root" and malformed targets never warn, even gated', () => {
  const controller = buildController(makeRoot({ attrs: VERBOSE }))

  const warns = captureWarns(() => {
    fire(controller, [["toggle", { to: "@root" }]])
    fire(controller, [["hide", {}]]) // no to:
    fire(controller, [["hide", { to: 42 }]])
    fire(controller, [["hide", { to: "" }]])
  })

  expect(warns.length).toBe(0)
})

test("an op that RESOLVES targets never warns", () => {
  const root = makeRoot({ attrs: VERBOSE })
  const el = makeEl({ owner: root })
  root.querySelectorAll = () => [el]
  const controller = buildController(root)

  const warns = captureWarns(() => fire(controller, [["hide", { to: ".panel" }]]))

  expect(warns.length).toBe(0)
  expect(el.hidden).toBe(true)
})

// --- dedupe ------------------------------------------------------------------

test("dedupe: an identical (op, selector, scope) warns once per page; a different selector warns again", () => {
  const controller = buildController(makeRoot({ attrs: VERBOSE }))

  const warns = captureWarns(() => {
    fire(controller, [["hide", { to: "#gone" }]])
    fire(controller, [["hide", { to: "#gone" }]]) // same — deduped
    fire(controller, [["hide", { to: "#other" }]]) // different selector — warns
    fire(controller, [["show", { to: "#gone" }]]) // different op — warns
  })

  expect(warns.length).toBe(3)
})

// --- the reactive:js stream path ---------------------------------------------

function stubTurbo() {
  globalThis.window = { Turbo: { StreamActions: {} } }
  return globalThis.window.Turbo.StreamActions
}

function stubDocument({ byId = {}, docMatches = {} } = {}) {
  globalThis.document = {
    getElementById: (id) => byId[id] ?? null,
    querySelectorAll: (sel) => docMatches[sel] ?? [],
  }
  return globalThis.document
}

// A fake <turbo-stream> element; `verbose` adds the server-stamped gate.
function streamEl({ ops, target, verbose = false } = {}) {
  const attrs = { "data-reactive-ops": JSON.stringify(ops) }
  if (target != null) attrs.target = target
  if (verbose) attrs["data-reactive-verbose"] = "true"
  return { getAttribute: (name) => attrs[name] ?? null }
}

function invoke(actions, el) {
  actions["reactive:js"].call(el)
}

test("stream path, gate off: zero targets stay silent (production wire)", () => {
  const actions = stubTurbo()
  registerReactiveJs()
  const rootEl = makeRoot({ id: "sidebar" })
  stubDocument({ byId: { sidebar: rootEl } })

  const warns = captureWarns(() =>
    invoke(actions, streamEl({ ops: [["hide", { to: "#gone" }]], target: "sidebar" })),
  )

  expect(warns.length).toBe(0)
})

test("stream path: a root-scoped selector that exists document-wide hints global: true", () => {
  const actions = stubTurbo()
  registerReactiveJs()
  const rootEl = makeRoot({ id: "sidebar" })
  const outside = makeEl()
  stubDocument({ byId: { sidebar: rootEl }, docMatches: { "#bell": [outside] } })

  const warns = captureWarns(() =>
    invoke(actions, streamEl({ ops: [["hide", { to: "#bell" }]], target: "sidebar", verbose: true })),
  )

  expect(warns.length).toBe(1)
  expect(warns[0]).toContain("hide")
  expect(warns[0]).toContain("#bell")
  expect(warns[0]).toContain("global: true")
})

test("stream path: a document-scoped op (no target) matching nothing warns plainly", () => {
  const actions = stubTurbo()
  registerReactiveJs()
  stubDocument()

  const warns = captureWarns(() =>
    invoke(actions, streamEl({ ops: [["hide", { to: "#gone" }]], verbose: true })),
  )

  expect(warns.length).toBe(1)
  expect(warns[0]).toContain("#gone")
})

test("stream path: a MISSING target root id warns (gated) instead of silently dropping the ops", () => {
  const actions = stubTurbo()
  registerReactiveJs()
  stubDocument() // no byId entries — the target root is not in the DOM

  const warns = captureWarns(() =>
    invoke(actions, streamEl({ ops: [["hide", { to: "#x" }]], target: "vanished", verbose: true })),
  )

  expect(warns.length).toBe(1)
  expect(warns[0]).toContain("vanished")
})

test("stream path: a missing target root stays silent without the gate", () => {
  const actions = stubTurbo()
  registerReactiveJs()
  stubDocument()

  const warns = captureWarns(() =>
    invoke(actions, streamEl({ ops: [["hide", { to: "#x" }]], target: "vanished" })),
  )

  expect(warns.length).toBe(0)
})

// --- the hint (busy/optimistic) path -----------------------------------------

test("an optimistic hint whose to: selector matches nothing warns under the gate", async () => {
  const root = makeRoot({ attrs: VERBOSE, id: "counter" })
  const controller = new ReactiveController()
  controller.element = root
  controller.tokenValue = "tok"
  globalThis.fetch = () =>
    Promise.resolve({
      redirected: false,
      ok: true,
      status: 200,
      headers: { get: () => "text/vnd.turbo-stream.html" },
      text: () => Promise.resolve(""),
    })
  globalThis.document = {
    querySelector: () => null,
    querySelectorAll: () => [],
    dispatchEvent: () => {},
  }
  globalThis.window = { Turbo: { renderStreamMessage: () => {} } }
  const trigger = makeEl()
  trigger.closest = () => root

  const warns = []
  const original = console.warn
  console.warn = (...args) => warns.push(args.join(" "))
  try {
    const event = {
      target: trigger,
      params: { action: "toggle", params: "{}", optimistic: { add_class: ["on"], to: ".badge" } },
      defaultPrevented: false,
      preventDefault() {
        this.defaultPrevented = true
      },
    }
    await controller.dispatch(event)
  } finally {
    console.warn = original
  }

  expect(warns.length).toBe(1)
  expect(warns[0]).toContain(".badge")
  expect(warns[0]).toContain("#counter")
})
