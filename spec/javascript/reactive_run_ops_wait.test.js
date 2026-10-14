// Unit tests for on_client debounce:/throttle: (issue #393). The binding
// record carries the wait; runOps runs it on the SAME timers on()'s dispatch
// uses (#debounceTimers / #throttleTimers), so disconnect tears both down:
//
//   * debounce — trailing edge: a burst runs the ops ONCE, `ms` after the last
//     event; a new event inside the window replaces the pending run.
//   * throttle — leading edge: the first event runs now, the rest are dropped
//     until the window elapses (no trailing run).
//   * keys — two waited records on one element, or an on() debounce and an
//     on_client debounce on one trigger, never cancel each other.
//   * once — one run for the life of the binding, after the wait.
//   * no wait — every event runs, as before.
//
// Real timers with small delays for debounce (like reactive_debounce.test.js);
// the throttle window is a captured fake timer, so machine load can't overrun it.
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll, afterEach } from "bun:test"

let ReactiveController

beforeAll(async () => {
  mock.module("@hotwired/stimulus", () => ({
    Controller: class {
      constructor() {}
    },
  }))
  ReactiveController = (await import("../../app/javascript/phlex/reactive/reactive_controller.js")).default
})

const realSetTimeout = globalThis.setTimeout
afterEach(() => {
  globalThis.setTimeout = realSetTimeout
})
const wait = (ms) => new Promise((resolve) => realSetTimeout(resolve, ms))

// Capture the timers scheduled for `ms` instead of running them; firing one is
// "the window elapsed".
function captureTimers(ms) {
  const captured = []
  globalThis.setTimeout = (fn, delay, ...args) => {
    if (delay !== ms) return realSetTimeout(fn, delay, ...args)
    captured.push(fn)
    return captured.length
  }
  return captured
}

// A target whose toggle_class op counts runs.
function makeCounter() {
  const el = { runs: 0, hidden: false, closest: () => null }
  el.classList = { toggle: () => (el.runs += 1) }
  return el
}

function makeRoot(matches = {}) {
  const root = {
    isConnected: true,
    id: "search-root",
    hidden: false,
    getAttribute: () => null,
    setAttribute: () => {},
    removeAttribute: () => {},
    dispatchEvent: () => {},
    contains: () => true,
    querySelectorAll: (sel) => matches[sel] ?? [],
  }
  for (const list of Object.values(matches)) for (const el of list) el.closest = () => root
  return root
}

function buildController(root) {
  const controller = new ReactiveController()
  controller.element = root
  controller.tokenValue = "tok"
  let fetches = 0
  globalThis.fetch = () => {
    fetches += 1
    return Promise.resolve({
      redirected: false,
      ok: true,
      headers: { get: () => "text/vnd.turbo-stream.html" },
      text: () => Promise.resolve(""),
    })
  }
  globalThis.document = { querySelector: () => null, querySelectorAll: () => [], dispatchEvent: () => {} }
  globalThis.window = { Turbo: { renderStreamMessage: () => {} } }
  return { controller, fetches: () => fetches }
}

// A trigger element with add/removeEventListener (the debounce blur flush).
function makeTrigger() {
  const listeners = {}
  return {
    listeners,
    addEventListener: (type, fn) => ((listeners[type] ??= new Set()).add(fn)),
    removeEventListener: (type, fn) => listeners[type]?.delete(fn),
  }
}

function makeEvent({ type = "input", ops, currentTarget, target } = {}) {
  return {
    type,
    params: { ops },
    currentTarget,
    target: target ?? currentTarget,
    defaultPrevented: false,
    preventDefault() {
      this.defaultPrevented = true
    },
  }
}

const op = [["toggle_class", { to: "#out", classes: ["x"] }]]

// --- debounce -----------------------------------------------------------------

test("debounce: a burst runs the ops ONCE, after the last event's wait", async () => {
  const out = makeCounter()
  const { controller } = buildController(makeRoot({ "#out": [out] }))
  const trigger = makeTrigger()
  // A wide window against short gaps: a slow runner can't fire it mid-burst.
  const record = { on: "input", debounce: 200, ops: op }

  controller.runOps(makeEvent({ ops: record, currentTarget: trigger }))
  await wait(20)
  controller.runOps(makeEvent({ ops: record, currentTarget: trigger }))
  await wait(20)
  controller.runOps(makeEvent({ ops: record, currentTarget: trigger }))
  expect(out.runs).toBe(0) // nothing runs inside the window

  await wait(300)
  expect(out.runs).toBe(1)
})

test("debounce: element-bound events are still preventDefault-ed NOW (the native default can't wait)", () => {
  const { controller } = buildController(makeRoot({ "#out": [makeCounter()] }))
  const trigger = makeTrigger()
  const event = makeEvent({ ops: { on: "input", debounce: 20, ops: op }, currentTarget: trigger })

  controller.runOps(event)

  expect(event.defaultPrevented).toBe(true)
  controller.disconnect()
})

test("debounce: a blur flushes the pending run (on()'s timer semantics)", () => {
  const out = makeCounter()
  const { controller } = buildController(makeRoot({ "#out": [out] }))
  const trigger = makeTrigger()

  controller.runOps(makeEvent({ ops: { on: "input", debounce: 1000, ops: op }, currentTarget: trigger }))
  for (const fn of [...trigger.listeners.blur]) fn()

  expect(out.runs).toBe(1)
  expect(trigger.listeners.blur.size).toBe(0)
})

test("debounce: a window-bound record adds no blur flush (a window blur is a tab switch)", async () => {
  const out = makeCounter()
  const { controller } = buildController(makeRoot({ "#out": [out] }))
  const win = { addEventListener: mock(() => {}), removeEventListener: () => {} }
  win.window = win // isWindow() recognises a window structurally

  controller.runOps(makeEvent({ type: "resize", ops: { on: "resize", window: true, debounce: 15, ops: op }, currentTarget: win }))

  expect(win.addEventListener).not.toHaveBeenCalled()
  await wait(30)
  expect(out.runs).toBe(1)
})

test("debounce: disconnect drops a pending on_client run", async () => {
  const out = makeCounter()
  const { controller } = buildController(makeRoot({ "#out": [out] }))
  const trigger = makeTrigger()

  controller.runOps(makeEvent({ ops: { on: "input", debounce: 15, ops: op }, currentTarget: trigger }))
  controller.disconnect()
  await wait(30)

  expect(out.runs).toBe(0)
})

test("debounce: two waited records on one element keep their own timers", async () => {
  const a = makeCounter()
  const b = makeCounter()
  const { controller } = buildController(makeRoot({ "#a": [a], "#b": [b] }))
  const trigger = makeTrigger()
  const ops = [
    JSON.stringify({ on: "input", debounce: 15, ops: [["toggle_class", { to: "#a", classes: ["x"] }]] }),
    JSON.stringify({ on: "keyup", debounce: 15, ops: [["toggle_class", { to: "#b", classes: ["x"] }]] }),
  ].join(" ")

  controller.runOps(makeEvent({ type: "input", ops, currentTarget: trigger }))
  controller.runOps(makeEvent({ type: "keyup", ops, currentTarget: trigger }))
  await wait(35)

  expect(a.runs).toBe(1)
  expect(b.runs).toBe(1)
})

test("debounce: two IDENTICAL waited records on one element keep their own timers (mix keeps both)", async () => {
  const out = makeCounter()
  const { controller } = buildController(makeRoot({ "#out": [out] }))
  const trigger = makeTrigger()
  const one = JSON.stringify({ on: "input", debounce: 15, ops: op })

  controller.runOps(makeEvent({ ops: [one, one].join(" "), currentTarget: trigger }))
  await wait(35)

  expect(out.runs).toBe(2)
})

test("throttle: two IDENTICAL waited records on one element keep their own windows", () => {
  captureTimers(250)
  const out = makeCounter()
  const { controller } = buildController(makeRoot({ "#out": [out] }))
  const trigger = makeTrigger()
  const one = JSON.stringify({ on: "input", throttle: 250, ops: op })

  controller.runOps(makeEvent({ ops: [one, one].join(" "), currentTarget: trigger }))

  expect(out.runs).toBe(2)
})

test("debounce: an on() debounce and an on_client debounce on one trigger never cancel each other", async () => {
  const out = makeCounter()
  const { controller, fetches } = buildController(makeRoot({ "#out": [out] }))
  const trigger = makeTrigger()

  controller.dispatch({
    type: "input",
    params: { action: "search", params: "{}", debounce: 15 },
    currentTarget: trigger,
    target: trigger,
    preventDefault() {},
  })
  controller.runOps(makeEvent({ ops: { on: "input", debounce: 15, ops: op }, currentTarget: trigger }))
  await wait(40)
  await controller.queue

  expect(out.runs).toBe(1)
  expect(fetches()).toBe(1)
})

test("debounce + once: one run, after the wait, however many events reach runOps", async () => {
  const out = makeCounter()
  const { controller } = buildController(makeRoot({ "#out": [out] }))
  const trigger = makeTrigger()
  const record = { on: "input", once: true, debounce: 15, ops: op }

  controller.runOps(makeEvent({ ops: record, currentTarget: trigger }))
  controller.runOps(makeEvent({ ops: record, currentTarget: trigger }))
  expect(out.runs).toBe(0)
  await wait(30)
  controller.runOps(makeEvent({ ops: record, currentTarget: trigger }))
  await wait(30)

  expect(out.runs).toBe(1)
})

// --- throttle -----------------------------------------------------------------

test("throttle: the first event runs now, the rest drop until the window elapses", () => {
  const windows = captureTimers(250)
  const out = makeCounter()
  const { controller } = buildController(makeRoot({ "#out": [out] }))
  const win = { addEventListener: () => {}, removeEventListener: () => {} }
  win.window = win
  const record = { on: "scroll", window: true, throttle: 250, ops: op }
  const scroll = () =>
    controller.runOps(makeEvent({ type: "scroll", ops: record, currentTarget: win, target: {} }))

  scroll()
  expect(out.runs).toBe(1) // leading edge
  scroll()
  scroll()
  expect(out.runs).toBe(1) // suppressed inside the window

  windows[0]() // the window elapsed
  scroll()
  expect(out.runs).toBe(2)
  controller.disconnect()
})

test("throttle: no trailing run after the window", async () => {
  const out = makeCounter()
  const { controller } = buildController(makeRoot({ "#out": [out] }))
  const trigger = makeTrigger()
  const record = { on: "input", throttle: 15, ops: op }

  controller.runOps(makeEvent({ ops: record, currentTarget: trigger }))
  controller.runOps(makeEvent({ ops: record, currentTarget: trigger }))
  await wait(30)

  expect(out.runs).toBe(1)
})

test("throttle: an on() throttle on the same trigger has its own window", () => {
  captureTimers(250)
  const out = makeCounter()
  const { controller, fetches } = buildController(makeRoot({ "#out": [out] }))
  const trigger = makeTrigger()

  controller.dispatch({
    type: "input",
    params: { action: "track", params: "{}", throttle: 250 },
    currentTarget: trigger,
    target: trigger,
    preventDefault() {},
  })
  controller.runOps(makeEvent({ ops: { on: "input", throttle: 250, ops: op }, currentTarget: trigger }))

  expect(out.runs).toBe(1)
  return controller.queue.then(() => expect(fetches()).toBe(1))
})

// --- no wait --------------------------------------------------------------------

test("no debounce/throttle: every event runs the ops, as before", () => {
  const out = makeCounter()
  const { controller } = buildController(makeRoot({ "#out": [out] }))
  const trigger = makeTrigger()
  const record = { on: "input", ops: op }

  controller.runOps(makeEvent({ ops: record, currentTarget: trigger }))
  controller.runOps(makeEvent({ ops: record, currentTarget: trigger }))
  controller.runOps(makeEvent({ ops: record, currentTarget: trigger }))

  expect(out.runs).toBe(3)
})

test("a legacy [[op, args]] attr ignores a mix-ed on()'s element-wide debounce param", () => {
  const out = makeCounter()
  const { controller } = buildController(makeRoot({ "#out": [out] }))
  const event = makeEvent({ ops: op, currentTarget: makeTrigger() })
  event.params.debounce = 300

  controller.runOps(event)

  expect(out.runs).toBe(1)
})

test("debounce: 0 runs immediately (no wait)", () => {
  const out = makeCounter()
  const { controller } = buildController(makeRoot({ "#out": [out] }))

  controller.runOps(makeEvent({ ops: { on: "input", debounce: 0, ops: op }, currentTarget: makeTrigger() }))

  expect(out.runs).toBe(1)
})
