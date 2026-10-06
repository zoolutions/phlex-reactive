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
import { test, expect, mock, beforeAll, beforeEach, afterEach } from "bun:test"

let ReactiveController

// The transition tests stub the timer/frame globals. bun runs every test file
// in ONE shared process, so a stub left in place would break the debounce /
// throttle / confirm tests (they rely on REAL setTimeout). Snapshot the
// originals once and restore them after every test.
const REAL = {
  setTimeout: globalThis.setTimeout,
  clearTimeout: globalThis.clearTimeout,
  requestAnimationFrame: globalThis.requestAnimationFrame,
  cancelAnimationFrame: globalThis.cancelAnimationFrame,
  getComputedStyle: globalThis.getComputedStyle,
  CustomEvent: globalThis.CustomEvent,
}

// The transition tests' fake setTimeout hands back plain numbers, and a settled
// run clears its fallback timer. bun's real timers are objects, so a numeric
// id is always one of ours — never pass it to the real clearTimeout, where it
// could cancel an unrelated timer elsewhere in the shared process.
beforeEach(() => {
  globalThis.clearTimeout = (id) => (typeof id === "number" ? undefined : REAL.clearTimeout(id))
})

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
  globalThis.clearTimeout = REAL.clearTimeout
  globalThis.requestAnimationFrame = REAL.requestAnimationFrame
  globalThis.cancelAnimationFrame = REAL.cancelAnimationFrame
  globalThis.getComputedStyle = REAL.getComputedStyle
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
    removeEventListener: (name, cb) => {
      if (el.listeners.get(name)?.cb === cb) el.listeners.delete(name)
    },
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

// The settle bugs effects.js had (#296), in runTransition: animationend and
// transitionend both BUBBLE, so a descendant's end event must not clean the
// parent's transition classes up early, and settling drops BOTH listeners
// (`once` would drop only the one that fired — or let a child's event consume it).
function startTransition(op = "show") {
  const root = makeRoot()
  const menu = makeEl({ owner: root })
  root.querySelectorAll = () => [menu]
  const controller = buildController(root)
  globalThis.requestAnimationFrame = (cb) => (cb(), 1)
  fire(controller, { ops: [[op, { to: "#menu", transition: ["t-fade", "from", "to"] }]] })
  return menu
}

test("a CSS transition settles on the element's own transitionend", () => {
  const menu = startTransition()

  const listener = menu.listeners.get("transitionend")
  expect(listener).toBeDefined()
  listener.cb({ target: menu })

  expect(menu.classes.has("t-fade")).toBe(false)
  expect(menu.classes.has("to")).toBe(false)
})

test("a descendant's bubbling transitionend/animationend does NOT settle the parent", () => {
  const menu = startTransition()
  const child = makeEl()

  menu.listeners.get("transitionend").cb({ target: child })
  menu.listeners.get("animationend").cb({ target: child })

  // Still mid-transition, and still listening for its OWN end event.
  expect(menu.classes.has("t-fade")).toBe(true)
  expect(menu.classes.has("to")).toBe(true)
  expect(menu.listeners.has("animationend")).toBe(true)
  expect(menu.listeners.has("transitionend")).toBe(true)

  menu.listeners.get("animationend").cb({ target: menu })
  expect(menu.classes.has("t-fade")).toBe(false)
})

test("settling removes BOTH end listeners, whichever event fired", () => {
  const menu = startTransition()
  menu.listeners.get("animationend").cb({ target: menu })
  expect(menu.listeners.has("animationend")).toBe(false)
  expect(menu.listeners.has("transitionend")).toBe(false)

  const other = startTransition("hide")
  other.listeners.get("transitionend").cb({ target: other })
  expect(other.listeners.has("animationend")).toBe(false)
  expect(other.listeners.has("transitionend")).toBe(false)
})

test("the fallback timer settles and removes both listeners too", () => {
  const root = makeRoot()
  const menu = makeEl({ owner: root })
  root.querySelectorAll = () => [menu]
  const controller = buildController(root)
  globalThis.requestAnimationFrame = (cb) => (cb(), 1)
  let timeoutCb = null
  globalThis.setTimeout = (cb) => {
    timeoutCb = cb
    return 1
  }

  fire(controller, { ops: [["hide", { to: "#menu", transition: ["t-fade", "from", "to"] }]] })
  timeoutCb()

  expect(menu.classes.has("t-fade")).toBe(false)
  expect(menu.listeners.has("animationend")).toBe(false)
  expect(menu.listeners.has("transitionend")).toBe(false)
})

// A hidden tab never runs rAF, but the 350 ms fallback is armed synchronously
// (not behind the frame), so cleanup still happens. What must not happen is the
// late frame — run when the tab wakes — re-adding `to` after cleanup, or `from`
// staying behind: cleanup drops all three classes and cancels the pending frame.
test("a never-firing rAF (hidden tab): the fallback cleans up all classes and cancels the frame", () => {
  const root = makeRoot()
  const menu = makeEl({ owner: root })
  root.querySelectorAll = () => [menu]
  const controller = buildController(root)
  let rafCb = null
  globalThis.requestAnimationFrame = (cb) => {
    rafCb = cb
    return 42
  }
  const canceled = []
  globalThis.cancelAnimationFrame = (id) => canceled.push(id)
  let timeoutCb = null
  globalThis.setTimeout = (cb) => {
    timeoutCb = cb
    return 1
  }

  fire(controller, { ops: [["show", { to: "#menu", transition: ["t-fade", "from", "to"] }]] })
  expect(menu.hidden).toBe(false)
  timeoutCb() // the frame never came

  expect([...menu.classes]).toEqual([])
  expect(canceled).toEqual([42])

  // Even if the browser runs the stale frame anyway, it must not re-add `to`.
  rafCb()
  expect([...menu.classes]).toEqual([])
})

// A controllable clock for the run-token and duration tests: every timer is
// captured with its delay (the id is its 1-based index), and clearing one is
// recorded.
function fakeClock() {
  const timers = []
  const cleared = []
  globalThis.setTimeout = (fn, ms) => timers.push({ fn, ms })
  globalThis.clearTimeout = (id) => cleared.push(id)
  return { timers, cleared }
}

function transitionHarness() {
  const root = makeRoot()
  const menu = makeEl({ owner: root })
  root.querySelectorAll = () => [menu]
  const controller = buildController(root)
  const frames = []
  globalThis.requestAnimationFrame = (cb) => frames.push(cb)
  const canceledFrames = []
  globalThis.cancelAnimationFrame = (id) => canceledFrames.push(id)
  const run = (op, triple) => fire(controller, { ops: [[op, { to: "#menu", transition: triple }]] })
  return { menu, frames, canceledFrames, run }
}

// Rapid show/hide on one element: each run cleans up only its OWN classes. A
// new run supersedes the live one (its timer, listeners and pending frame are
// cancelled), so the superseded run's late fallback, end event or frame does
// nothing to the new run's classes.
test("a superseded transition run's late fallback, end event and frame leave the new run alone", () => {
  const clock = fakeClock()
  const { menu, frames, canceledFrames, run } = transitionHarness()

  run("show", ["fade", "fade-from", "fade-to"]) // run A
  const aTimer = clock.timers[0]
  const aAnimationEnd = menu.listeners.get("animationend").cb
  const aFrame = frames[0]

  run("hide", ["out", "out-from", "out-to"]) // run B, before A settles
  expect(menu.hidden).toBe(true)
  // A was cancelled: its timer cleared, its frame cancelled, its classes gone.
  expect(clock.cleared).toEqual([1])
  expect(canceledFrames).toEqual([1])
  expect(menu.classes.has("fade")).toBe(false)
  expect(menu.classes.has("fade-from")).toBe(false)

  // A's late wakeups all arrive after B started: none touches B.
  aTimer.fn()
  aAnimationEnd({ target: menu })
  aFrame()
  expect(menu.classes.has("out")).toBe(true)
  expect(menu.classes.has("out-from")).toBe(true)
  expect(menu.classes.has("fade-to")).toBe(false)

  // B still runs and settles normally.
  frames[1]()
  expect(menu.classes.has("out-to")).toBe(true)
  menu.listeners.get("transitionend").cb({ target: menu })
  expect([...menu.classes]).toEqual([])
})

test("a superseding run with the SAME classes keeps them (toggle twice mid-transition)", () => {
  const clock = fakeClock()
  const { menu, run } = transitionHarness()
  const triple = ["t-fade", "from", "to"]

  run("toggle", triple)
  const aTimer = clock.timers[0]
  run("toggle", triple)
  aTimer.fn() // A's stale fallback

  expect(menu.classes.has("t-fade")).toBe(true)
  expect(menu.classes.has("from")).toBe(true)
  clock.timers[1].fn() // B's own fallback
  expect([...menu.classes]).toEqual([])
})

// Transitions longer than 350 ms: the fallback follows the element's computed
// durations (+delays), read once `during` is applied, with 350 ms as the floor
// and a 5 s cap.
function styleWith(props) {
  globalThis.getComputedStyle = () => ({
    transitionDuration: "0s",
    transitionDelay: "0s",
    animationDuration: "0s",
    animationDelay: "0s",
    ...props,
  })
}

test("a 600 ms transition is not cut at 350 ms: the fallback follows its computed duration", () => {
  const clock = fakeClock()
  const { menu, frames, run } = transitionHarness()
  let seenDuring = null
  globalThis.getComputedStyle = (el) => {
    seenDuring = el.classes.has("t-slow")
    return { transitionDuration: "0.6s", transitionDelay: "0s", animationDuration: "0s", animationDelay: "0s" }
  }

  run("show", ["t-slow", "from", "to"])
  frames[0]()

  expect(seenDuring).toBe(true) // read after `during` is applied
  expect(clock.timers).toHaveLength(1)
  expect(clock.timers[0].ms).toBeGreaterThan(600)
  expect(clock.timers[0].ms).toBeLessThan(1000)
  expect(menu.classes.has("t-slow")).toBe(true) // nothing settled at 350 ms

  menu.listeners.get("transitionend").cb({ target: menu })
  expect([...menu.classes]).toEqual([])
})

test("the fallback takes the longest duration+delay pair across comma lists, in s or ms", () => {
  const clock = fakeClock()
  const { run } = transitionHarness()
  styleWith({
    transitionDuration: "150ms, 0.2s",
    transitionDelay: "0s, 500ms", // 0.2s + 500ms = 700 ms
    animationDuration: "0.4s",
    animationDelay: "100ms", // 500 ms
  })

  run("show", ["t", "f", "to"])
  expect(clock.timers[0].ms).toBeGreaterThanOrEqual(700)
  expect(clock.timers[0].ms).toBeLessThan(1000)
})

test("no declared duration keeps the 350 ms floor; a bogus huge one is capped at 5 s", () => {
  const clock = fakeClock()
  const { run } = transitionHarness()

  styleWith({})
  run("show", ["t", "f", "to"])
  expect(clock.timers[0].ms).toBe(350)

  styleWith({ transitionDuration: "99999s" })
  run("hide", ["t", "f", "to"])
  expect(clock.timers[1].ms).toBe(5000)

  globalThis.getComputedStyle = () => {
    throw new Error("not an Element")
  }
  run("show", ["t", "f", "to"])
  expect(clock.timers[2].ms).toBe(350)
})
