// Unit tests for the on(...) event modifiers (issue #80): outside:, window:,
// and throttle:. (window:/once: descriptor composition is pure Ruby — native
// Stimulus — covered by the component spec; here we test the CLIENT contract.)
//
//   outside  — data-reactive-outside-param: the guard runs FIRST in dispatch().
//              An event whose target is INSIDE this root is a COMPLETE no-op:
//              no preventDefault, no reactive:before-dispatch, no fetch.
//              An event outside the root dispatches normally.
//   window   — data-reactive-window-param: a window-bound trigger must NOT
//              call event.preventDefault() — a mounted dropdown must not kill
//              every link click on the page. Element-bound triggers keep the
//              unconditional preventDefault (issue #11).
//   throttle — data-reactive-throttle-param: LEADING-EDGE rate limit, mirroring
//              the debounce suite. The first event fires immediately; further
//              events are suppressed until the window elapses. Timers are keyed
//              on action + target (window scroll events share
//              event.target === document — two window-bound triggers must not
//              collide) and cleared in disconnect().
//
// Real timers with small delays, like the debounce suite — except the
// leading-edge throttle test, whose window is driven by a captured (fake)
// suppression timer: real 5 ms sleeps could overrun its 60 ms window under
// machine load.
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

// bun runs every test file in ONE process: keep the real setTimeout (wait()
// uses it even while a test stubs the global) and restore it after each test.
const realSetTimeout = globalThis.setTimeout
afterEach(() => {
  globalThis.setTimeout = realSetTimeout
})

const wait = (ms) => new Promise((resolve) => realSetTimeout(resolve, ms))

// Capture the timers scheduled for `ms` (the throttle's suppression window)
// instead of running them; every other timer still runs for real. Firing a
// captured one is "the window elapsed", with no dependence on wall-clock time.
function captureTimers(ms) {
  const captured = []
  globalThis.setTimeout = (fn, delay, ...args) => {
    if (delay !== ms) return realSetTimeout(fn, delay, ...args)
    captured.push(fn)
    return captured.length
  }
  return captured
}

// A reactive root stub that records raw-dispatched CustomEvents (so the tests
// can assert reactive:before-dispatch did or did not fire) and scripts
// containment for the outside guard.
function makeRoot({ containsTarget = false } = {}) {
  const events = []
  return {
    events,
    isConnected: true,
    id: "menu",
    contains: () => containsTarget,
    dispatchEvent: (event) => events.push(event),
    querySelectorAll: () => [],
    setAttribute: () => {},
    removeAttribute: () => {},
    getAttribute: () => null,
  }
}

function buildController({ root } = {}) {
  const controller = new ReactiveController()
  controller.element = root ?? makeRoot()
  controller.tokenValue = "tok"
  let calls = 0
  globalThis.fetch = () => {
    calls++
    return Promise.resolve({
      redirected: false,
      ok: true,
      headers: { get: () => "text/vnd.turbo-stream.html" },
      text: () => Promise.resolve(""),
    })
  }
  globalThis.document = { querySelector: () => null, dispatchEvent: () => {} }
  globalThis.window = { Turbo: { renderStreamMessage: () => {} } }
  return { controller, calls: () => calls }
}

// A dispatchable event stub whose preventDefault flips defaultPrevented, so a
// test can assert the REAL observable (would the browser's default run?).
function makeEvent(params, { target = {} } = {}) {
  return {
    params,
    target,
    defaultPrevented: false,
    preventDefault() {
      this.defaultPrevented = true
    },
  }
}

// --- outside: --------------------------------------------------------------

test("an outside click OUTSIDE the root dispatches the action", async () => {
  const root = makeRoot({ containsTarget: false })
  const { controller, calls } = buildController({ root })

  await controller.dispatch(makeEvent({ action: "close_menu", params: "{}", outside: true, window: true }))

  expect(calls()).toBe(1)
})

test("an outside click INSIDE the root is a COMPLETE no-op (no fetch, no before-dispatch, no preventDefault)", async () => {
  const root = makeRoot({ containsTarget: true })
  const { controller, calls } = buildController({ root })

  const event = makeEvent({ action: "close_menu", params: "{}", outside: true, window: true })
  await controller.dispatch(event)
  await wait(20) // let any (wrongly) scheduled work surface

  expect(calls()).toBe(0)
  // The guard runs BEFORE the lifecycle event — an inside click must not even
  // announce itself to reactive:before-dispatch listeners.
  expect(root.events.filter((e) => e.type === "reactive:before-dispatch").length).toBe(0)
  // ...and BEFORE preventDefault — the page's native behavior is untouched.
  expect(event.defaultPrevented).toBe(false)
})

// --- window: (no preventDefault) --------------------------------------------

test("a window-bound trigger does NOT preventDefault (links elsewhere keep working)", async () => {
  const root = makeRoot({ containsTarget: false })
  const { controller, calls } = buildController({ root })

  const event = makeEvent({ action: "close_menu", params: "{}", outside: true, window: true })
  await controller.dispatch(event)

  expect(event.defaultPrevented).toBe(false) // the round trip still ran...
  expect(calls()).toBe(1) // ...without hijacking the page's click
})

test("an element-bound trigger still preventDefaults unconditionally (issue #11)", async () => {
  const { controller, calls } = buildController()

  const event = makeEvent({ action: "save", params: "{}" })
  await controller.dispatch(event)

  expect(event.defaultPrevented).toBe(true)
  expect(calls()).toBe(1)
})

// --- throttle: ---------------------------------------------------------------

test("throttled dispatches fire LEADING-EDGE: first immediately, burst suppressed, next window fires again", async () => {
  const { controller, calls } = buildController()
  const target = {}
  const windows = captureTimers(60) // the 60 ms window never elapses on its own

  // First event of the burst fires NOW (leading edge) and opens ONE window...
  controller.dispatch(makeEvent({ action: "track", params: "{}", throttle: 60 }, { target }))
  await wait(5)
  expect(calls()).toBe(1)
  expect(windows).toHaveLength(1)

  // ...the rest of the burst inside the window is suppressed (dropped, not
  // queued, and no further window is opened).
  for (let i = 0; i < 4; i++) {
    controller.dispatch(makeEvent({ action: "track", params: "{}", throttle: 60 }, { target }))
    await wait(5)
  }
  expect(calls()).toBe(1)
  expect(windows).toHaveLength(1)

  // After the window elapses the next event fires immediately again.
  windows[0]()
  controller.dispatch(makeEvent({ action: "track", params: "{}", throttle: 60 }, { target }))
  await wait(5)
  expect(calls()).toBe(2)
  expect(windows).toHaveLength(2)
})

test("throttle timers are keyed on action + target — two actions sharing event.target don't collide", async () => {
  const { controller, calls } = buildController()
  // Window-bound scroll events all share event.target === document.
  const sharedTarget = {}

  controller.dispatch(makeEvent({ action: "track_scroll", params: "{}", throttle: 5000 }, { target: sharedTarget }))
  controller.dispatch(makeEvent({ action: "track_pointer", params: "{}", throttle: 5000 }, { target: sharedTarget }))
  await wait(10)

  expect(calls()).toBe(2) // each action got its own leading-edge fire

  controller.disconnect() // tear down the two long timers for suite stability
})

test("disconnect() clears the throttle timers alongside the debounces", async () => {
  const { controller, calls } = buildController()
  const target = {}

  controller.dispatch(makeEvent({ action: "track", params: "{}", throttle: 5000 }, { target }))
  await wait(5)
  expect(calls()).toBe(1)

  // The element leaves the DOM before the window elapses; the pending
  // suppression timer must be torn down, not left running.
  controller.disconnect()

  controller.dispatch(makeEvent({ action: "track", params: "{}", throttle: 5000 }, { target }))
  await wait(5)
  expect(calls()).toBe(2) // the stale suppression entry is gone

  controller.disconnect() // clean up the fresh timer too
})

test("no throttle → dispatch fires immediately every time (unchanged behavior)", async () => {
  const { controller, calls } = buildController()

  await controller.dispatch(makeEvent({ action: "save", params: "{}" }))
  await controller.dispatch(makeEvent({ action: "save", params: "{}" }))

  expect(calls()).toBe(2)
})

test("a throttled dispatch still fires reactive:before-dispatch per gesture (pre-throttle, like pre-debounce)", async () => {
  const root = makeRoot()
  const { controller, calls } = buildController({ root })
  const target = {}

  controller.dispatch(makeEvent({ action: "track", params: "{}", throttle: 5000 }, { target }))
  controller.dispatch(makeEvent({ action: "track", params: "{}", throttle: 5000 }, { target }))
  await wait(10)

  expect(calls()).toBe(1) // second one throttled away...
  // ...but the veto point saw both gestures (mirrors debounce's PRE-debounce timing).
  expect(root.events.filter((e) => e.type === "reactive:before-dispatch").length).toBe(2)

  controller.disconnect()
})
