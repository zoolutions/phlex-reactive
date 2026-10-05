// Unit tests for the GLOBAL reactive-activity signal (issue #201). The
// controller tracks a DOCUMENT-LEVEL count of in-flight reactive operations —
// dispatch round trips AND deferred renders — and exposes it two ways, the
// direct analogue of Turbo's progress bar:
//
//   * a marker on <html>: data-reactive-active present while count > 0,
//   * events on document: reactive:busy on the 0 -> >0 edge, reactive:idle on
//     the >0 -> 0 edge (edges only, never once per op).
//
// The counter is a module-level primitive (enterReactiveActivity /
// exitReactiveActivity) wired into the two async lifecycles:
//   * dispatch — entered in #applyBusy (at enqueue, covering the queue wait),
//     exited in the settle closure #perform runs in its finally.
//   * defer    — entered/exited with the pendingDefers registry (set/delete),
//     so BOTH the fetch and the push (stream) lane stay balanced even though the
//     stream lane clears its pending markers by a node swap, not clearDeferPending.
//
// compute-seed is deliberately NOT counted: recompute() is synchronous, so it
// settles inline — there is no async window to await (see the module comment).
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll, beforeEach } from "bun:test"

let ReactiveController
let mod
let defer

beforeAll(async () => {
  mock.module("@hotwired/stimulus", () => ({
    Controller: class {
      constructor() {}
    },
  }))
  mod = await import("../../app/javascript/phlex/reactive/reactive_controller.js")
  // The defer code is a feature module (issue #275). Loaded up front, so a
  // connect or a `reactive:defer` stream reaches it in the same tick; the
  // not-yet-loaded path is covered in reactive_features.test.js.
  defer = await mod.__loadReactiveFeatureForTest("defer")
  ReactiveController = mod.default
})

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
const flush = async (times = 6) => {
  for (let i = 0; i < times; i++) await Promise.resolve()
}

// A document stub with a real documentElement (attribute store) and an event
// recorder, so a test can observe the <html> marker AND the reactive:busy /
// reactive:idle events. metas/byId cover the defer + dispatch fetch paths.
function stubDocument({ byId = {}, metas = {} } = {}) {
  const rootAttrs = {}
  const events = []
  const listeners = {}
  const documentElement = {
    getAttribute: (n) => (n in rootAttrs ? rootAttrs[n] : null),
    setAttribute: (n, v) => {
      rootAttrs[n] = String(v)
    },
    removeAttribute: (n) => {
      delete rootAttrs[n]
    },
    hasAttribute: (n) => n in rootAttrs,
    toggleAttribute: (n, force) => {
      const on = force ?? !(n in rootAttrs)
      if (on) rootAttrs[n] = ""
      else delete rootAttrs[n]
      return on
    },
  }
  globalThis.document = {
    documentElement,
    getElementById: (id) => byId[id] ?? null,
    querySelector: (sel) => {
      const name = sel.match(/meta\[name="([^"]+)"\]/)?.[1]
      return name && metas[name] != null ? { content: metas[name] } : null
    },
    createElement: () => ({ setAttribute() {}, id: "" }),
    body: { appendChild: () => {} },
    addEventListener: (name, fn) => (listeners[name] = fn),
    dispatchEvent: (event) => {
      events.push(event)
      return true
    },
  }
  return { rootAttrs, events, listeners, byId, documentElement }
}

function stubTurbo() {
  const rendered = []
  globalThis.window = {
    Turbo: { StreamActions: {}, renderStreamMessage: (html) => rendered.push(html) },
  }
  return { actions: globalThis.window.Turbo.StreamActions, rendered }
}

// A minimal reactive root that tracks its own attributes.
function makeRoot() {
  const attrs = {}
  return {
    isConnected: true,
    id: "counter",
    hidden: false,
    getAttribute: (n) => (n in attrs ? attrs[n] : null),
    setAttribute: (n, v) => {
      attrs[n] = String(v)
    },
    removeAttribute: (n) => {
      delete attrs[n]
    },
    hasAttribute: (n) => n in attrs,
    dispatchEvent: () => {},
    contains: () => false,
    querySelectorAll: () => [],
  }
}

function makeTrigger() {
  const attrs = {}
  return {
    isConnected: true,
    disabled: false,
    innerHTML: "",
    classes: new Set(),
    closest: () => null,
    getAttribute: (n) => (n in attrs ? attrs[n] : null),
    setAttribute: (n, v) => {
      attrs[n] = String(v)
    },
    removeAttribute: (n) => {
      delete attrs[n]
    },
    hasAttribute: (n) => n in attrs,
    classList: {
      add() {},
      remove() {},
      toggle() {},
      contains: () => false,
    },
  }
}

// Build a controller with a scripted, gate-able fetch (dispatch path).
function buildController({ hold = null } = {}) {
  const root = makeRoot()
  const controller = new ReactiveController()
  controller.element = root
  controller.tokenValue = "tok"
  globalThis.fetch = async () => {
    if (hold) await hold
    return {
      redirected: false,
      ok: true,
      status: 200,
      headers: { get: () => "text/vnd.turbo-stream.html" },
      text: () => Promise.resolve(""),
    }
  }
  globalThis.queueMicrotask ??= (fn) => Promise.resolve().then(fn)
  return { controller, root }
}

function fireDispatch(controller, trigger, extra = {}) {
  const event = {
    target: trigger,
    currentTarget: trigger,
    params: { action: "save", params: "{}", ...extra },
    defaultPrevented: false,
    preventDefault() {
      this.defaultPrevented = true
    },
  }
  return controller.dispatch(event)
}

beforeEach(() => {
  mod.resetReactiveActivity()
  defer.resetReactiveDefers()
})

// --- the primitive ----------------------------------------------------------

test("exports the activity primitive + a count/reset seam", () => {
  expect(typeof mod.enterReactiveActivity).toBe("function")
  expect(typeof mod.exitReactiveActivity).toBe("function")
  expect(typeof mod.reactiveActivityCount).toBe("function")
  expect(typeof mod.resetReactiveActivity).toBe("function")
})

test("enter/exit toggle the <html> marker and fire busy/idle on the 0-edges only", () => {
  const { rootAttrs, events } = stubDocument()
  stubTurbo()

  expect(mod.reactiveActivityCount()).toBe(0)
  expect("data-reactive-active" in rootAttrs).toBe(false)

  mod.enterReactiveActivity() // 0 -> 1
  expect(mod.reactiveActivityCount()).toBe(1)
  expect("data-reactive-active" in rootAttrs).toBe(true)
  expect(events.map((e) => e.type)).toEqual(["reactive:busy"])

  mod.enterReactiveActivity() // 1 -> 2, no new event
  expect(mod.reactiveActivityCount()).toBe(2)
  expect(events.map((e) => e.type)).toEqual(["reactive:busy"])

  mod.exitReactiveActivity() // 2 -> 1, still busy
  expect("data-reactive-active" in rootAttrs).toBe(true)
  expect(events.map((e) => e.type)).toEqual(["reactive:busy"])

  mod.exitReactiveActivity() // 1 -> 0, idle
  expect(mod.reactiveActivityCount()).toBe(0)
  expect("data-reactive-active" in rootAttrs).toBe(false)
  expect(events.map((e) => e.type)).toEqual(["reactive:busy", "reactive:idle"])
})

test("the busy/idle events carry the current count in detail", () => {
  const { events } = stubDocument()
  stubTurbo()
  mod.enterReactiveActivity()
  mod.enterReactiveActivity()
  mod.exitReactiveActivity()
  mod.exitReactiveActivity()
  const busy = events.find((e) => e.type === "reactive:busy")
  const idle = events.find((e) => e.type === "reactive:idle")
  expect(busy.detail.count).toBe(1)
  expect(idle.detail.count).toBe(0)
})

test("the count never goes negative (an unbalanced exit is clamped at 0)", () => {
  const { rootAttrs, events } = stubDocument()
  stubTurbo()
  mod.exitReactiveActivity() // spurious exit while already idle
  expect(mod.reactiveActivityCount()).toBe(0)
  expect("data-reactive-active" in rootAttrs).toBe(false)
  expect(events.length).toBe(0) // no phantom idle event
})

test("no documentElement (non-browser stub) is a safe no-op, counter still tracks", () => {
  globalThis.document = { dispatchEvent: () => {} } // no documentElement
  stubTurbo()
  expect(() => mod.enterReactiveActivity()).not.toThrow()
  expect(mod.reactiveActivityCount()).toBe(1)
  expect(() => mod.exitReactiveActivity()).not.toThrow()
  expect(mod.reactiveActivityCount()).toBe(0)
})

// --- wired into the dispatch round trip -------------------------------------

test("a dispatch enters activity at enqueue and exits on settle", async () => {
  const { rootAttrs } = stubDocument()
  stubTurbo()
  let release
  const hold = new Promise((r) => (release = r))
  const { controller } = buildController({ hold })
  const trigger = makeTrigger()

  const promise = fireDispatch(controller, trigger)
  // In flight: the global marker is up (covers the queue wait too).
  expect("data-reactive-active" in rootAttrs).toBe(true)
  expect(mod.reactiveActivityCount()).toBe(1)

  release()
  await promise
  // Settled: marker cleared, counter back to 0.
  expect("data-reactive-active" in rootAttrs).toBe(false)
  expect(mod.reactiveActivityCount()).toBe(0)
})

test("a dispatch that FAILS still exits activity (balanced on every path)", async () => {
  const { rootAttrs } = stubDocument()
  stubTurbo()
  const { controller } = buildController()
  // Make the fetch reject to force the error path.
  globalThis.fetch = async () => Promise.reject(new Error("boom"))
  const trigger = makeTrigger()
  const originalError = console.error
  console.error = () => {}
  try {
    await fireDispatch(controller, trigger)
  } finally {
    console.error = originalError
  }
  expect(mod.reactiveActivityCount()).toBe(0)
  expect("data-reactive-active" in rootAttrs).toBe(false)
})

test("two overlapping dispatches keep the layer busy until BOTH settle", async () => {
  const { rootAttrs } = stubDocument()
  stubTurbo()
  let release
  const hold = new Promise((r) => (release = r))
  const { controller } = buildController({ hold })

  fireDispatch(controller, makeTrigger(), { action: "a" })
  fireDispatch(controller, makeTrigger(), { action: "b" })
  await wait(5)
  expect(mod.reactiveActivityCount()).toBe(2)
  expect("data-reactive-active" in rootAttrs).toBe(true)

  release()
  await controller.queue
  expect(mod.reactiveActivityCount()).toBe(0)
  expect("data-reactive-active" in rootAttrs).toBe(false)
})

// --- wired into the defer lifecycle -----------------------------------------

function makeDeferTarget(id) {
  const attrs = {}
  return {
    id,
    getAttribute: (n) => (n in attrs ? attrs[n] : null),
    setAttribute: (n, v) => {
      attrs[n] = String(v)
    },
    removeAttribute: (n) => {
      delete attrs[n]
    },
    hasAttribute: (n) => n in attrs,
    dispatchEvent: () => {},
    attrs,
  }
}

function directiveEl({ target, token = "signed-defer-token", via = "fetch" } = {}) {
  const attrs = { target, "data-reactive-defer-via": via, "data-reactive-defer-token": token }
  return { getAttribute: (n) => attrs[n] ?? null }
}

function stubDeferFetch() {
  const calls = []
  globalThis.fetch = (url, options) => {
    let resolve, reject
    const promise = new Promise((res, rej) => {
      resolve = res
      reject = rej
    })
    calls.push({ url, options, resolve, reject })
    return promise
  }
  return calls
}

function okResponse(html) {
  return {
    ok: true,
    status: 200,
    headers: { get: () => "text/vnd.turbo-stream.html" },
    text: () => Promise.resolve(html),
  }
}

test("the fetch defer lane enters activity while pending and exits on arrival", async () => {
  const el = makeDeferTarget("slow-totals")
  const { rootAttrs } = stubDocument({ byId: { "slow-totals": el }, metas: { "csrf-token": "c" } })
  const { actions } = stubTurbo()
  const calls = stubDeferFetch()
  mod.registerReactiveDefer()

  actions["reactive:defer"].call(directiveEl({ target: "slow-totals" }))
  // Pending: the global marker is up.
  expect(mod.reactiveActivityCount()).toBe(1)
  expect("data-reactive-active" in rootAttrs).toBe(true)

  calls[0].resolve(okResponse("<turbo-stream></turbo-stream>"))
  await flush()
  // Arrived: back to idle.
  expect(mod.reactiveActivityCount()).toBe(0)
  expect("data-reactive-active" in rootAttrs).toBe(false)
})

test("a superseded defer stays net busy (delete+set is zero), settles once", async () => {
  const el = makeDeferTarget("slow-totals")
  const { rootAttrs } = stubDocument({ byId: { "slow-totals": el }, metas: { "csrf-token": "c" } })
  const { actions } = stubTurbo()
  const calls = stubDeferFetch()
  mod.registerReactiveDefer()

  // First directive → pending (count 1).
  actions["reactive:defer"].call(directiveEl({ target: "slow-totals" }))
  expect(mod.reactiveActivityCount()).toBe(1)

  // A newer directive for the SAME target supersedes: the old fetch aborts, a new
  // one starts. The layer must remain busy at exactly 1 (never flicker to 0).
  actions["reactive:defer"].call(directiveEl({ target: "slow-totals", token: "fresh" }))
  expect(mod.reactiveActivityCount()).toBe(1)
  expect("data-reactive-active" in rootAttrs).toBe(true)

  // The superseding fetch is calls[1] (calls[0] was aborted).
  calls[1].resolve(okResponse("<turbo-stream></turbo-stream>"))
  await flush()
  expect(mod.reactiveActivityCount()).toBe(0)
  expect("data-reactive-active" in rootAttrs).toBe(false)
})

test("a defer that ERRORS exits activity (failDefer path)", async () => {
  const el = makeDeferTarget("slow-totals")
  const { rootAttrs } = stubDocument({ byId: { "slow-totals": el }, metas: { "csrf-token": "c" } })
  const { actions } = stubTurbo()
  const calls = stubDeferFetch()
  mod.registerReactiveDefer()
  const originalError = console.error
  console.error = () => {}
  try {
    actions["reactive:defer"].call(directiveEl({ target: "slow-totals" }))
    expect(mod.reactiveActivityCount()).toBe(1)
    calls[0].reject(new Error("network"))
    await flush()
  } finally {
    console.error = originalError
  }
  expect(mod.reactiveActivityCount()).toBe(0)
  expect("data-reactive-active" in rootAttrs).toBe(false)
})

test("a dispatch AND a defer sum in the global counter, independently balanced", async () => {
  const el = makeDeferTarget("slow-totals")
  const { rootAttrs } = stubDocument({ byId: { "slow-totals": el }, metas: { "csrf-token": "c" } })
  const { actions } = stubTurbo()

  // A held dispatch fetch AND a defer fetch share one fetch stub queue: route by
  // URL so both can be gated independently.
  const dispatchCalls = []
  const deferCalls = []
  globalThis.fetch = (url, options) => {
    let resolve
    const promise = new Promise((r) => (resolve = r))
    ;(url && url.includes("defer") ? deferCalls : dispatchCalls).push({ resolve, options })
    return promise
  }
  globalThis.queueMicrotask ??= (fn) => Promise.resolve().then(fn)

  const controller = new ReactiveController()
  controller.element = makeRoot()
  controller.tokenValue = "tok"
  mod.registerReactiveDefer()

  fireDispatch(controller, makeTrigger())
  actions["reactive:defer"].call(directiveEl({ target: "slow-totals" }))
  await wait(5)
  expect(mod.reactiveActivityCount()).toBe(2)
  expect("data-reactive-active" in rootAttrs).toBe(true)

  // Settle the defer first — still busy from the dispatch.
  deferCalls[0].resolve(okResponse("<turbo-stream></turbo-stream>"))
  await flush()
  expect(mod.reactiveActivityCount()).toBe(1)
  expect("data-reactive-active" in rootAttrs).toBe(true)

  // Settle the dispatch — now idle.
  dispatchCalls[0].resolve({
    redirected: false,
    ok: true,
    status: 200,
    headers: { get: () => "text/vnd.turbo-stream.html" },
    text: () => Promise.resolve(""),
  })
  await controller.queue
  await flush()
  expect(mod.reactiveActivityCount()).toBe(0)
  expect("data-reactive-active" in rootAttrs).toBe(false)
})
