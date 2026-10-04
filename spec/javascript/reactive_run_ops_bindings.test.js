// Unit tests for on_client binding records (issue #271). Each on_client call
// emits ONE self-describing record ({on, ops, window?, outside?, confirm?,
// confirmWhen?}) in data-reactive-ops-param; mix space-joins several. Stimulus
// hands every runOps descriptor on an element the SAME event.params, so runOps
// must pick the record(s) whose descriptor matches the firing event:
//
//   * parse — a lone record (Stimulus typecasts it to an object), a
//     space-joined multi-record string, the legacy [[op, args]] list (array or
//     JSON string), a malformed piece warn-and-skipped while siblings run.
//   * match — event.type, the key filter (Stimulus's default key mappings,
//     modifiers matched EXACTLY), and window-boundness (currentTarget === window).
//   * per-record outside / preventDefault / confirm, never element-wide.
//   * run-once — two identical descriptors (two Stimulus bindings) call runOps
//     twice for one event; each record still runs once.
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll, afterEach } from "bun:test"

let ReactiveController
let setConfirmResolver

beforeAll(async () => {
  mock.module("@hotwired/stimulus", () => ({
    Controller: class {
      constructor() {}
    },
  }))
  ReactiveController = (await import("../../app/javascript/phlex/reactive/reactive_controller.js")).default
  setConfirmResolver = (await import("../../app/javascript/phlex/reactive/confirm.js")).setConfirmResolver
})

afterEach(() => {
  setConfirmResolver((message) =>
    Promise.resolve(typeof globalThis.window?.confirm === "function" ? globalThis.window.confirm(message) : true)
  )
})

function makeEl() {
  return { hidden: false, closest: () => null }
}

function makeRoot(matches = {}, attrs = {}) {
  const root = {
    isConnected: true,
    id: "menu-root",
    hidden: false,
    getAttribute: (name) => attrs[name] ?? null,
    setAttribute: () => {},
    removeAttribute: () => {},
    dispatchEvent: () => {},
    contains: (el) => el?.__inside === true,
    querySelectorAll: (sel) => matches[sel] ?? [],
  }
  for (const list of Object.values(matches)) for (const el of list) el.closest = () => root
  return root
}

function buildController(root) {
  const controller = new ReactiveController()
  controller.element = root
  globalThis.fetch = () => {
    throw new Error("runOps must NEVER fetch")
  }
  globalThis.document = { querySelector: () => null, querySelectorAll: () => [], dispatchEvent: () => {} }
  globalThis.window = { Turbo: { renderStreamMessage: () => {} } }
  return controller
}

function makeEvent({ type = "click", ops, params = {}, key, mods = {}, currentTarget, target } = {}) {
  return {
    type,
    key,
    metaKey: false,
    ctrlKey: false,
    altKey: false,
    shiftKey: false,
    ...mods,
    params: { ops, ...params },
    currentTarget,
    target: target ?? { __inside: true },
    defaultPrevented: false,
    preventDefault() {
      this.defaultPrevented = true
    },
  }
}

// Mirror Ruby's on_client wire: compact JSON, spaces as  , space-joined.
const wire = (...records) => records.map((r) => JSON.stringify(r).replaceAll(" ", "\\u0020")).join(" ")

function captureWarns(fn) {
  const warns = []
  const original = console.warn
  console.warn = (...args) => warns.push(args.join(" "))
  try {
    fn()
  } finally {
    console.warn = original
  }
  return warns
}

// --- parse -------------------------------------------------------------------

test("a lone record (typecast to an object by Stimulus) runs its ops", () => {
  const menu = makeEl()
  const root = makeRoot({ "#menu": [menu] })
  const controller = buildController(root)

  controller.runOps(makeEvent({ ops: { on: "click", ops: [["hide", { to: "#menu" }]] }, currentTarget: root }))

  expect(menu.hidden).toBe(true)
})

test("a space-joined two-record string parses each piece, \\u0020 inside a selector included", () => {
  const item = makeEl()
  const root = makeRoot({ "#menu .item": [item] })
  const controller = buildController(root)
  const ops = wire({ on: "click", window: true, outside: true, ops: [["show", { to: "#menu .item" }]] },
    { on: "keydown.esc", ops: [["hide", { to: "#menu .item" }]] })

  controller.runOps(makeEvent({ type: "keydown", key: "Escape", ops, currentTarget: root }))

  expect(item.hidden).toBe(true)
})

test("the legacy [[op, args]] list (array or JSON string) still runs and reads element-wide params", () => {
  const root = makeRoot()
  const controller = buildController(root)

  controller.runOps(makeEvent({ ops: [["toggle", { to: "@root" }]], currentTarget: root }))
  expect(root.hidden).toBe(true)

  controller.runOps(makeEvent({ ops: '[["toggle",{"to":"@root"}]]', currentTarget: root }))
  expect(root.hidden).toBe(false)

  // Legacy outside/window still come from event.params (hand-built attrs).
  const event = makeEvent({
    ops: [["hide", { to: "@root" }]],
    params: { outside: true, window: true },
    target: { __inside: true },
    currentTarget: globalThis.window,
  })
  controller.runOps(event)
  expect(root.hidden).toBe(false)
  expect(event.defaultPrevented).toBe(false)
})

test("a malformed piece warns and is skipped; its sibling record still runs", () => {
  const root = makeRoot()
  const controller = buildController(root)
  const ops = `{"on":"click",oops ${wire({ on: "click", ops: [["hide", { to: "@root" }]] })}`

  const warns = captureWarns(() => controller.runOps(makeEvent({ ops, currentTarget: root })))

  expect(root.hidden).toBe(true)
  expect(warns.some((w) => w.includes("malformed"))).toBe(true)
})

// --- match -------------------------------------------------------------------

test("event.type selects the record: a keydown never runs the click record", () => {
  const a = makeEl()
  const b = makeEl()
  const root = makeRoot({ "#a": [a], "#b": [b] })
  const controller = buildController(root)
  const ops = wire({ on: "click", ops: [["hide", { to: "#a" }]] }, { on: "keydown.esc", ops: [["hide", { to: "#b" }]] })

  controller.runOps(makeEvent({ type: "keydown", key: "Escape", ops, currentTarget: root }))

  expect(a.hidden).toBe(false)
  expect(b.hidden).toBe(true)
})

test("key filters pick between two keydown records on one element", () => {
  const esc = makeEl()
  const down = makeEl()
  const root = makeRoot({ "#esc": [esc], "#down": [down] })
  const controller = buildController(root)
  const ops = wire({ on: "keydown.esc", ops: [["hide", { to: "#esc" }]] },
    { on: "keydown.down", ops: [["hide", { to: "#down" }]] })

  controller.runOps(makeEvent({ type: "keydown", key: "ArrowDown", ops, currentTarget: root }))
  expect(esc.hidden).toBe(false)
  expect(down.hidden).toBe(true)

  controller.runOps(makeEvent({ type: "keydown", key: "Escape", ops, currentTarget: root }))
  expect(esc.hidden).toBe(true)
})

test("modifiers match EXACTLY (ctrl+k is not a plain k, and vice versa)", () => {
  const ctrlK = makeEl()
  const plainK = makeEl()
  const root = makeRoot({ "#ctrl": [ctrlK], "#plain": [plainK] })
  const controller = buildController(root)
  const ops = wire({ on: "keydown.ctrl+k", ops: [["hide", { to: "#ctrl" }]] },
    { on: "keydown.k", ops: [["hide", { to: "#plain" }]] })

  controller.runOps(makeEvent({ type: "keydown", key: "k", ops, currentTarget: root }))
  expect(ctrlK.hidden).toBe(false)
  expect(plainK.hidden).toBe(true)

  plainK.hidden = false
  controller.runOps(makeEvent({ type: "keydown", key: "K", mods: { ctrlKey: true }, ops, currentTarget: root }))
  expect(ctrlK.hidden).toBe(true)
  expect(plainK.hidden).toBe(false)
})

test("single-letter, digit, and custom event names match", () => {
  const root = makeRoot()
  const controller = buildController(root)

  controller.runOps(makeEvent({ type: "keydown", key: "7", ops: wire({ on: "keydown.7", ops: [["toggle", { to: "@root" }]] }), currentTarget: root }))
  expect(root.hidden).toBe(true)

  controller.runOps(makeEvent({ type: "app:refresh", ops: wire({ on: "app:refresh", ops: [["toggle", { to: "@root" }]] }), currentTarget: root }))
  expect(root.hidden).toBe(false)
})

test("an unknown key filter never matches when telling same-type records apart", () => {
  const known = makeEl()
  const unknown = makeEl()
  const root = makeRoot({ "#known": [known], "#unknown": [unknown] })
  const controller = buildController(root)
  const ops = wire({ on: "keydown.f13", ops: [["hide", { to: "#unknown" }]] },
    { on: "keydown.esc", ops: [["hide", { to: "#known" }]] })

  controller.runOps(makeEvent({ type: "keydown", key: "F13", ops, currentTarget: root }))

  expect(unknown.hidden).toBe(false)
  expect(known.hidden).toBe(false)
})

// --- window-boundness ----------------------------------------------------------

test("click + click@window on one element: an inside click runs the element record ONCE", () => {
  const root = makeRoot()
  const controller = buildController(root)
  let runs = 0
  root.dispatchEvent = () => runs++
  const ops = wire({ on: "click", ops: [["dispatch", { name: "inner", to: "@root" }]] },
    { on: "click", window: true, outside: true, ops: [["hide", { to: "@root" }]] })
  const target = { __inside: true }

  // One inside click reaches BOTH listeners: the element's, then the window's.
  const event = makeEvent({ ops, target, currentTarget: root })
  controller.runOps(event)
  event.currentTarget = globalThis.window
  controller.runOps(event)

  expect(runs).toBe(1)
  expect(root.hidden).toBe(false) // the outside record bailed on its guard
})

test("an outside click (currentTarget = window) runs only the window record", () => {
  const root = makeRoot()
  const controller = buildController(root)
  let runs = 0
  root.dispatchEvent = () => runs++
  const ops = wire({ on: "click", ops: [["dispatch", { name: "inner", to: "@root" }]] },
    { on: "click", window: true, outside: true, ops: [["hide", { to: "@root" }]] })

  const event = makeEvent({ ops, target: { __inside: false }, currentTarget: globalThis.window })
  controller.runOps(event)

  expect(runs).toBe(0)
  expect(root.hidden).toBe(true)
  expect(event.defaultPrevented).toBe(false) // window-bound never preventDefaults
})

test("an element-bound record preventDefaults; its window-bound sibling's flags never leak onto it", () => {
  const root = makeRoot()
  const controller = buildController(root)
  const ops = wire({ on: "click", window: true, outside: true, ops: [["show", { to: "@root" }]] },
    { on: "keydown.esc", ops: [["hide", { to: "@root" }]] })

  // An Escape INSIDE the root: the old element-wide outside param would have bailed it.
  const event = makeEvent({ type: "keydown", key: "Escape", ops, target: { __inside: true }, currentTarget: root })
  controller.runOps(event)

  expect(root.hidden).toBe(true)
  expect(event.defaultPrevented).toBe(true)
})

// --- run-once for duplicate descriptors -----------------------------------------

test("two identical descriptors (runOps called twice for one event) run each record once, in order", () => {
  const root = makeRoot()
  const controller = buildController(root)
  const names = []
  root.dispatchEvent = (e) => names.push(e.type)
  const ops = wire({ on: "click", ops: [["dispatch", { name: "first", to: "@root" }]] },
    { on: "click", ops: [["dispatch", { name: "second", to: "@root" }]] })

  const event = makeEvent({ ops, currentTarget: root })
  controller.runOps(event)
  controller.runOps(event)

  expect(names).toEqual(["first", "second"])
})

// --- confirm per record ---------------------------------------------------------

test("confirm gates only its own record", async () => {
  const a = makeEl()
  const b = makeEl()
  const root = makeRoot({ "#a": [a], "#b": [b] })
  const controller = buildController(root)
  const asked = []
  setConfirmResolver((message) => {
    asked.push(message)
    return false
  })
  const ops = wire({ on: "click", confirm: "Really?", ops: [["hide", { to: "#a" }]] },
    { on: "keydown.esc", ops: [["hide", { to: "#b" }]] })

  controller.runOps(makeEvent({ type: "keydown", key: "Escape", ops, currentTarget: root }))
  await Promise.resolve()
  expect(asked).toEqual([])
  expect(b.hidden).toBe(true)

  controller.runOps(makeEvent({ ops, currentTarget: root }))
  await new Promise((r) => setTimeout(r, 0))
  expect(asked).toEqual(["Really?"])
  expect(a.hidden).toBe(false) // declined
})

test("confirmWhen (an object in the record) gates through the conditional evaluator", async () => {
  const root = makeRoot()
  const controller = buildController(root)
  const asked = []
  setConfirmResolver((message) => {
    asked.push(message)
    return true
  })
  const ops = wire({ on: "click", confirmWhen: { predicate: "always", message: "Sure?" }, ops: [["hide", { to: "@root" }]] })

  const warns = captureWarns(() => controller.runOps(makeEvent({ ops, currentTarget: root })))
  await new Promise((r) => setTimeout(r, 0))

  // An unregistered predicate fails open (warns, no dialog) — proving the payload reached the evaluator.
  expect(warns.some((w) => w.includes("always"))).toBe(true)
  expect(root.hidden).toBe(true)
})

// --- zero matches ----------------------------------------------------------------

test("zero matching records runs nothing; warns only under the verbose gate", () => {
  const quiet = makeRoot()
  const quietController = buildController(quiet)
  const ops = wire({ on: "keydown.esc", ops: [["hide", { to: "@root" }]] })

  const silent = captureWarns(() => quietController.runOps(makeEvent({ ops, currentTarget: quiet })))
  expect(quiet.hidden).toBe(false)
  expect(silent).toEqual([])

  const verbose = makeRoot({}, { "data-reactive-verbose": "true" })
  verbose.id = "verbose-root"
  const verboseController = buildController(verbose)
  const loud = captureWarns(() => verboseController.runOps(makeEvent({ ops, currentTarget: verbose })))
  expect(verbose.hidden).toBe(false)
  expect(loud.some((w) => w.includes("no on_client binding"))).toBe(true)
})

// --- run-once must not swallow OTHER bindings on the same window event ----------
// Stimulus walks every binding of the one (window, "click") listener with the
// SAME event object, so a guard keyed only on currentTarget (= window) would drop
// every window-bound runOps after the first.

test("two roots with identical outside-close records both close on one outside click", () => {
  const rootA = makeRoot()
  const rootB = makeRoot()
  const a = buildController(rootA)
  const b = buildController(rootB)
  const ops = wire({ on: "click", window: true, outside: true, ops: [["hide", { to: "@root" }]] })

  const event = makeEvent({ ops, target: { __inside: false }, currentTarget: globalThis.window })
  a.runOps(event)
  event.params = { ops } // Stimulus reassigns params per binding
  b.runOps(event)

  expect(rootA.hidden).toBe(true)
  expect(rootB.hidden).toBe(true)
})

test("a root outside-close and a child window-bound binding in one root both run", () => {
  const panel = makeEl()
  const root = makeRoot({ "#panel": [panel] })
  const controller = buildController(root)
  const rootOps = wire({ on: "click", window: true, outside: true, ops: [["hide", { to: "@root" }]] })
  const childOps = wire({ on: "click", window: true, ops: [["hide", { to: "#panel" }]] })

  const event = makeEvent({ ops: rootOps, target: { __inside: false }, currentTarget: globalThis.window })
  controller.runOps(event)
  event.params = { ops: childOps }
  controller.runOps(event)

  expect(root.hidden).toBe(true)
  expect(panel.hidden).toBe(true)
})

// --- PR #272 review ---------------------------------------------------------------

test("a lone binding runs on any event Stimulus let through (custom keyMappings are Stimulus's call)", () => {
  const root = makeRoot()
  const controller = buildController(root)
  // `slash` is not in the default table — an app registered it in its Stimulus schema.
  const ops = wire({ on: "keydown.slash", ops: [["hide", { to: "@root" }]] })

  controller.runOps(makeEvent({ type: "keydown", key: "/", ops, currentTarget: root }))

  expect(root.hidden).toBe(true)
})

test("custom keyMappings from the Stimulus schema tell two same-type records apart", () => {
  const slash = makeEl()
  const esc = makeEl()
  const root = makeRoot({ "#slash": [slash], "#esc": [esc] })
  const controller = buildController(root)
  controller.application = { schema: { keyMappings: { esc: "Escape", slash: "/" } } }
  const ops = wire({ on: "keydown.slash", ops: [["hide", { to: "#slash" }]] },
    { on: "keydown.esc", ops: [["hide", { to: "#esc" }]] })

  controller.runOps(makeEvent({ type: "keydown", key: "/", ops, currentTarget: root }))

  expect(slash.hidden).toBe(true)
  expect(esc.hidden).toBe(false)
})

test("a non-legacy record without `on` never matches (default-deny)", () => {
  const root = makeRoot()
  const controller = buildController(root)

  const event = makeEvent({ ops: { ops: [["hide", { to: "@root" }]] }, currentTarget: root })
  controller.runOps(event)

  expect(root.hidden).toBe(false)
  expect(event.defaultPrevented).toBe(false)
})

test("a once record runs once even when a regular same-event sibling keeps firing", () => {
  const root = makeRoot()
  const controller = buildController(root)
  const names = []
  root.dispatchEvent = (e) => names.push(e.type)
  const ops = wire({ on: "click", once: true, ops: [["dispatch", { name: "once", to: "@root" }]] },
    { on: "click", ops: [["dispatch", { name: "every", to: "@root" }]] })

  controller.runOps(makeEvent({ ops, currentTarget: root }))
  controller.runOps(makeEvent({ ops, currentTarget: root }))

  expect(names).toEqual(["once", "every", "every"])
})

test("spent once state belongs to the trigger element: a re-rendered or sibling trigger starts fresh", () => {
  const root = makeRoot()
  const controller = buildController(root)
  const names = []
  root.dispatchEvent = (e) => names.push(e.type)
  const ops = wire({ on: "click", once: true, ops: [["dispatch", { name: "once", to: "@root" }]] },
    { on: "click", ops: [["dispatch", { name: "every", to: "@root" }]] })
  const first = { id: "first" }
  const rerendered = { id: "rerendered" } // a morph/stream swapped in a fresh element, same markup

  controller.runOps(makeEvent({ ops, currentTarget: first }))
  controller.runOps(makeEvent({ ops, currentTarget: first }))
  controller.runOps(makeEvent({ ops, currentTarget: rerendered }))

  expect(names).toEqual(["once", "every", "every", "once", "every"])
})
