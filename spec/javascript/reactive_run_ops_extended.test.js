// Unit tests for the issue #96 client ops — attribute ops, focus, dispatch, and
// animated transitions — layered on the #95 runOps interpreter. Like
// reactive_run_ops.test.js they NEVER fetch (the stub throws), scope to owned
// matches (issue #15), and warn-and-skip the unknown.
//
// Focus of this file:
//   * set/remove/toggle_attr mutate attributes, and the INTERPRET-time allowlist
//     (defense in depth) warns + skips a forged event-handler/URL/style op even
//     though the Ruby builder would never emit one.
//   * focus / focus_first move focus to the right node.
//   * dispatch emits a BUBBLING CustomEvent via element.dispatchEvent (NOT
//     Stimulus's shadowed this.dispatch) with the given detail.
//   * a transition triple applies `during`+`from`, swaps to `to` on the next
//     frame, and cleans up on `animationend` — with a setTimeout fallback so a
//     NON-animated element never hangs (fake timers prove the fallback fires).
//
// Per the DOM-spec trap noted in reactive_lifecycle_events.test.js, no test here
// asserts a THROWING dispatch listener's behavior — bun:test fails on any
// surfaced exception, so that case can't be asserted cleanly in this runner.
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll, afterEach } from "bun:test"

let ReactiveController

// The transition tests stub the timer/frame globals. bun runs every test file
// in ONE shared process, so a stub left in place would break the debounce /
// throttle / confirm tests (they rely on REAL setTimeout). Snapshot the
// originals once and restore them after every test.
const REAL = {
  setTimeout: globalThis.setTimeout,
  requestAnimationFrame: globalThis.requestAnimationFrame,
  CustomEvent: globalThis.CustomEvent,
}

beforeAll(async () => {
  mock.module("@hotwired/stimulus", () => ({
    Controller: class {
      constructor() {}
    },
  }))
  ReactiveController = (await import("../../app/javascript/phlex/reactive/reactive_controller.js")).default
})

afterEach(() => {
  globalThis.setTimeout = REAL.setTimeout
  globalThis.requestAnimationFrame = REAL.requestAnimationFrame
  globalThis.CustomEvent = REAL.CustomEvent
})

// A richer fake node than reactive_run_ops.test.js's: it also models attributes,
// focus(), addEventListener (for animationend), and dispatchEvent (records the
// events it received). `closest` returns the nearest reactive root (`owner`).
function makeEl({ owner = null } = {}) {
  const el = {
    hidden: false,
    classes: new Set(),
    attrs: new Map(),
    focused: 0,
    dispatched: [],
    listeners: new Map(),
    closest: () => owner,
    getAttribute: (n) => (el.attrs.has(n) ? el.attrs.get(n) : null),
    setAttribute: (n, v) => el.attrs.set(n, String(v)),
    removeAttribute: (n) => el.attrs.delete(n),
    hasAttribute: (n) => el.attrs.has(n),
    focus: () => {
      el.focused += 1
      globalThis.document.activeElement = el
    },
    dispatchEvent: (event) => {
      el.dispatched.push(event)
      return true
    },
    addEventListener: (name, cb, opts) => el.listeners.set(name, { cb, opts }),
    querySelectorAll: () => [],
  }
  el.classList = {
    add: (...cs) => cs.forEach((c) => el.classes.add(c)),
    remove: (...cs) => cs.forEach((c) => el.classes.delete(c)),
    toggle: (c) => (el.classes.has(c) ? el.classes.delete(c) : el.classes.add(c)),
    contains: (c) => el.classes.has(c),
  }
  return el
}

function makeRoot(matches = {}) {
  const root = makeEl({ owner: null })
  root.isConnected = true
  root.id = "tabs"
  root.contains = (el) => el?.__inside === true
  root.querySelectorAll = (sel) => matches[sel] ?? []
  return root
}

function buildController(root, { documentMatches = {} } = {}) {
  const controller = new ReactiveController()
  controller.element = root
  globalThis.fetch = () => {
    throw new Error("runOps must NEVER fetch")
  }
  globalThis.document = {
    activeElement: null,
    querySelector: () => null,
    querySelectorAll: (sel) => documentMatches[sel] ?? [],
    dispatchEvent: () => {},
  }
  globalThis.window = { Turbo: { renderStreamMessage: () => {} } }
  // A CustomEvent stand-in that records name/detail/bubbles for dispatch tests.
  globalThis.CustomEvent = class {
    constructor(type, init = {}) {
      this.type = type
      this.detail = init.detail
      this.bubbles = !!init.bubbles
      this.composed = !!init.composed
    }
  }
  return controller
}

function fire(controller, { ops, target } = {}) {
  const event = {
    params: { ops },
    target: target ?? { __inside: false },
    defaultPrevented: false,
    preventDefault() {
      this.defaultPrevented = true
    },
  }
  controller.runOps(event)
  return event
}

function captureWarnings(fn) {
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

// --- attribute ops ----------------------------------------------------------

test("set_attr sets, remove_attr removes, on every owned match", () => {
  const root = makeRoot()
  const el = makeEl({ owner: root })
  el.setAttribute("disabled", "true")
  root.querySelectorAll = () => [el]
  const controller = buildController(root)

  fire(controller, { ops: [["set_attr", { to: "#x", name: "aria-expanded", value: "true" }]] })
  expect(el.getAttribute("aria-expanded")).toBe("true")

  fire(controller, { ops: [["remove_attr", { to: "#x", name: "disabled" }]] })
  expect(el.hasAttribute("disabled")).toBe(false)
})

test("toggle_attr adds a missing attr (value '') and removes a present one", () => {
  const root = makeRoot()
  const el = makeEl({ owner: root })
  root.querySelectorAll = () => [el]
  const controller = buildController(root)

  fire(controller, { ops: [["toggle_attr", { to: "#x", name: "aria-expanded" }]] })
  expect(el.hasAttribute("aria-expanded")).toBe(true)

  fire(controller, { ops: [["toggle_attr", { to: "#x", name: "aria-expanded" }]] })
  expect(el.hasAttribute("aria-expanded")).toBe(false)
})

// --- issue #271: two-value toggle_attr + expanded: -------------------------

test("toggle_attr with values flips between them; an absent attr becomes the on value", () => {
  const root = makeRoot()
  const el = makeEl({ owner: root })
  root.querySelectorAll = () => [el]
  const controller = buildController(root)
  const op = [["toggle_attr", { to: "#x", name: "aria-expanded", values: ["true", "false"] }]]

  fire(controller, { ops: op })
  expect(el.getAttribute("aria-expanded")).toBe("true")
  fire(controller, { ops: op })
  expect(el.getAttribute("aria-expanded")).toBe("false")
  fire(controller, { ops: op })
  expect(el.getAttribute("aria-expanded")).toBe("true")
})

test("toggle_attr with values still refuses an off-allowlist name", () => {
  const root = makeRoot()
  const el = makeEl({ owner: root })
  root.querySelectorAll = () => [el]
  const controller = buildController(root)

  const warns = captureWarnings(() =>
    fire(controller, { ops: [["toggle_attr", { to: "#x", name: "onclick", values: ["a", "b"] }]] }),
  )

  expect(el.hasAttribute("onclick")).toBe(false)
  expect(warns.some((w) => w.includes("refused"))).toBe(true)
})

test("show/hide/toggle with expanded set aria-expanded from the intended state", () => {
  const root = makeRoot()
  const menu = makeEl({ owner: root })
  const trigger = makeEl({ owner: root })
  menu.hidden = true
  root.querySelectorAll = (sel) => ({ "#menu": [menu], "#trigger": [trigger] })[sel] ?? []
  const controller = buildController(root)

  fire(controller, { ops: [["toggle", { to: "#menu", expanded: "#trigger" }]] })
  expect(menu.hidden).toBe(false)
  expect(trigger.getAttribute("aria-expanded")).toBe("true")

  fire(controller, { ops: [["toggle", { to: "#menu", expanded: "#trigger" }]] })
  expect(menu.hidden).toBe(true)
  expect(trigger.getAttribute("aria-expanded")).toBe("false")

  fire(controller, { ops: [["show", { to: "#menu", expanded: "#trigger" }]] })
  expect(trigger.getAttribute("aria-expanded")).toBe("true")

  fire(controller, { ops: [["hide", { to: "#menu", expanded: "@root" }]] })
  expect(root.getAttribute("aria-expanded")).toBe("false")
})

test("expanded is set synchronously, before a transition's next frame", () => {
  const root = makeRoot()
  const menu = makeEl({ owner: root })
  const trigger = makeEl({ owner: root })
  menu.hidden = true
  root.querySelectorAll = (sel) => ({ "#menu": [menu], "#trigger": [trigger] })[sel] ?? []
  const controller = buildController(root)
  globalThis.requestAnimationFrame = () => 1 // never runs the swap

  fire(controller, { ops: [["toggle", { to: "#menu", expanded: "#trigger", transition: ["t", "f", "to"] }]] })

  expect(trigger.getAttribute("aria-expanded")).toBe("true")
})

test("global: true resolves the expanded target document-wide", () => {
  const root = makeRoot()
  const overlay = makeEl()
  const pageTrigger = makeEl()
  overlay.hidden = true
  const controller = buildController(root, { documentMatches: { "#overlay": [overlay], "#page-trigger": [pageTrigger] } })

  fire(controller, { ops: [["show", { to: "#overlay", expanded: "#page-trigger", global: true }]] })

  expect(overlay.hidden).toBe(false)
  expect(pageTrigger.getAttribute("aria-expanded")).toBe("true")
})

// --- interpret-time allowlist (defense in depth) ----------------------------

test("a forged event-handler attr op warns and is skipped (interpret-time deny)", () => {
  const root = makeRoot()
  const el = makeEl({ owner: root })
  root.querySelectorAll = () => [el]
  const controller = buildController(root)

  const warns = captureWarnings(() =>
    // A hand-built ops attr the Ruby builder would have refused at build time.
    fire(controller, { ops: [["set_attr", { to: "#x", name: "onclick", value: "alert(1)" }]] }),
  )

  expect(el.hasAttribute("onclick")).toBe(false)
  expect(warns.length).toBe(1)
  expect(warns[0]).toContain("onclick")
})

test("forged URL-bearing and style attr ops are skipped (case-insensitive)", () => {
  const root = makeRoot()
  const el = makeEl({ owner: root })
  root.querySelectorAll = () => [el]
  const controller = buildController(root)

  captureWarnings(() => {
    fire(controller, { ops: [["set_attr", { to: "#x", name: "HREF", value: "javascript:evil()" }]] })
    fire(controller, { ops: [["set_attr", { to: "#x", name: "style", value: "color:red" }]] })
    fire(controller, { ops: [["toggle_attr", { to: "#x", name: "SRC" }]] })
  })

  expect(el.hasAttribute("HREF")).toBe(false)
  expect(el.hasAttribute("style")).toBe(false)
  expect(el.hasAttribute("SRC")).toBe(false)
})

test("a safe attr op still applies while a forged sibling op is skipped", () => {
  const root = makeRoot()
  const el = makeEl({ owner: root })
  root.querySelectorAll = () => [el]
  const controller = buildController(root)

  captureWarnings(() =>
    fire(controller, {
      ops: [
        ["set_attr", { to: "#x", name: "onclick", value: "x" }], // skipped
        ["set_attr", { to: "#x", name: "aria-hidden", value: "true" }], // applies
      ],
    }),
  )

  expect(el.getAttribute("aria-hidden")).toBe("true")
})

// --- focus ------------------------------------------------------------------

test("focus moves focus to the first match", () => {
  const root = makeRoot()
  const item = makeEl({ owner: root })
  root.querySelectorAll = (sel) => (sel === "#menu [role=menuitem]" ? [item] : [])
  const controller = buildController(root)

  fire(controller, { ops: [["focus", { to: "#menu [role=menuitem]" }]] })

  expect(item.focused).toBe(1)
  expect(globalThis.document.activeElement).toBe(item)
})

test("focus_first focuses the first focusable descendant of the match", () => {
  const root = makeRoot()
  const menu = makeEl({ owner: root })
  const firstItem = makeEl({ owner: root })
  // The menu's focusable descendants, in document order.
  menu.querySelectorAll = () => [firstItem]
  root.querySelectorAll = (sel) => (sel === "#menu" ? [menu] : [])
  const controller = buildController(root)

  fire(controller, { ops: [["focus_first", { to: "#menu" }]] })

  expect(firstItem.focused).toBe(1)
})

// --- dispatch ---------------------------------------------------------------

test("dispatch emits a bubbling CustomEvent on the root by default, with detail", () => {
  const root = makeRoot()
  const controller = buildController(root)

  // The Ruby builder serializes a nil target as the @root sentinel.
  fire(controller, { ops: [["dispatch", { name: "app:menu-toggled", to: "@root", detail: { open: true } }]] })

  expect(root.dispatched.length).toBe(1)
  const event = root.dispatched[0]
  expect(event.type).toBe("app:menu-toggled")
  expect(event.bubbles).toBe(true)
  expect(event.detail).toEqual({ open: true })
})

test("dispatch with a target emits on the owned match", () => {
  const root = makeRoot()
  const panel = makeEl({ owner: root })
  root.querySelectorAll = (sel) => (sel === "#panel" ? [panel] : [])
  const controller = buildController(root)

  fire(controller, { ops: [["dispatch", { name: "app:x", to: "#panel", detail: {} }]] })

  expect(panel.dispatched.length).toBe(1)
  expect(root.dispatched.length).toBe(0)
})

// --- transitions ------------------------------------------------------------

test("a transition applies during+from, then swaps from->to on the next frame", () => {
  const root = makeRoot()
  const menu = makeEl({ owner: root })
  menu.hidden = true
  root.querySelectorAll = () => [menu]
  const controller = buildController(root)

  // Capture the rAF callback instead of running it, so we can assert the two
  // phases (initial classes, then the swap) deterministically.
  let rafCb = null
  globalThis.requestAnimationFrame = (cb) => {
    rafCb = cb
    return 1
  }

  fire(controller, {
    ops: [["toggle", { to: "#menu", transition: ["transition-opacity", "opacity-0", "opacity-100"] }]],
  })

  // Phase 1: visibility flipped, during+from applied, `to` not yet.
  expect(menu.hidden).toBe(false)
  expect(menu.classes.has("transition-opacity")).toBe(true)
  expect(menu.classes.has("opacity-0")).toBe(true)
  expect(menu.classes.has("opacity-100")).toBe(false)

  // Phase 2: the next frame swaps from -> to.
  rafCb()
  expect(menu.classes.has("opacity-0")).toBe(false)
  expect(menu.classes.has("opacity-100")).toBe(true)
})

test("transition classes are cleaned up on animationend", () => {
  const root = makeRoot()
  const menu = makeEl({ owner: root })
  root.querySelectorAll = () => [menu]
  const controller = buildController(root)
  globalThis.requestAnimationFrame = (cb) => (cb(), 1)

  fire(controller, {
    ops: [["show", { to: "#menu", transition: ["t-fade", "from", "to"] }]],
  })

  // The op registered an animationend listener; firing it removes the transition
  // classes (both the `during` helper and the `to` end-state marker).
  const listener = menu.listeners.get("animationend")
  expect(listener).toBeDefined()
  listener.cb()

  expect(menu.classes.has("t-fade")).toBe(false)
  expect(menu.classes.has("to")).toBe(false)
})

test("a non-animated element does NOT hang: the setTimeout fallback cleans up", () => {
  const root = makeRoot()
  const menu = makeEl({ owner: root })
  root.querySelectorAll = () => [menu]
  const controller = buildController(root)
  globalThis.requestAnimationFrame = (cb) => (cb(), 1)

  // Fake timer: capture the fallback so we can fire it without real time.
  let timeoutCb = null
  globalThis.setTimeout = (cb) => {
    timeoutCb = cb
    return 1
  }

  fire(controller, {
    ops: [["hide", { to: "#menu", transition: ["t-fade", "from", "to"] }]],
  })

  expect(menu.classes.has("t-fade")).toBe(true) // still mid-transition
  timeoutCb() // the fallback fires (animationend never came)
  expect(menu.classes.has("t-fade")).toBe(false)
})
