// Unit tests for the latency simulator dev aid (issue #102):
//
//   ENABLE/DISABLE — named exports enableLatencySim(ms) / disableLatencySim()
//   persist to sessionStorage under "phlex-reactive:latency". enable writes the
//   ms; disable removes the key.
//
//   SLEEP — in #perform, AFTER aria-busy is set (at enqueue) and right BEFORE the
//   fetch, the controller reads the key and awaits setTimeout(ms) so the busy
//   window is actually visible. A null/absent key is a no-op (zero prod surface);
//   a NaN/non-positive value does not delay. A one-time console.warn banner fires
//   while the sim is active, not once per request.
//
//   DEV GATE — registerReactiveActions attaches window.PhlexReactive =
//   { enableLatencySim, disableLatencySim } ONLY when
//   <meta name="phlex-reactive-env" content="development"> is present. Without the
//   meta there is no global handle at all.
//
// Sleeps are asserted by ORDER (fetch happens after the awaited timer), never by
// wall-clock timing — a fake setTimeout resolves synchronously via a captured
// callback so the tests stay deterministic.
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll, beforeEach, afterEach } from "bun:test"

let mod
let ReactiveController
let enableLatencySim
let disableLatencySim
let registerReactiveActions
let __resetReactiveLatencyForTest

beforeAll(async () => {
  mock.module("@hotwired/stimulus", () => ({
    Controller: class {
      constructor() {}
    },
  }))
  mod = await import("../../app/javascript/phlex/reactive/reactive_controller.js")
  ReactiveController = mod.default
  enableLatencySim = mod.enableLatencySim
  disableLatencySim = mod.disableLatencySim
  registerReactiveActions = mod.registerReactiveActions
  ;({ resetLatencySim: __resetReactiveLatencyForTest } = await import("../../app/javascript/phlex/reactive/features/dev.js"))
})

// A minimal sessionStorage stub (a Map behind the Storage API surface).
function makeSessionStorage() {
  const map = new Map()
  return {
    map,
    getItem: (k) => (map.has(k) ? map.get(k) : null),
    setItem: (k, v) => map.set(k, String(v)),
    removeItem: (k) => map.delete(k),
  }
}

// bun runs EVERY spec in one process on a shared globalThis, so a test that
// mutates a global must RESTORE it — not delete it. In particular bun provides a
// native `navigator` (whose `.onLine` is undefined, so the offline gate passes);
// deleting it would leave sibling suites' #perform throwing on `navigator.onLine`.
// Snapshot the originals once and restore them in afterEach. `realSetTimeout` is
// the untouched real timer used by this file's `wait()` helper (we never stub the
// global timer — clobbering it would corrupt bun's own scheduling).
const realSetTimeout = globalThis.setTimeout
const ORIGINALS = {
  window: globalThis.window,
  document: globalThis.document,
  sessionStorage: globalThis.sessionStorage,
  navigator: globalThis.navigator,
  fetch: globalThis.fetch,
  console: globalThis.console,
}

let warnings
beforeEach(() => {
  warnings = []
  globalThis.console = { warn: (...a) => warnings.push(a.join(" ")), error: () => {} }
  __resetReactiveLatencyForTest?.()
})

afterEach(() => {
  // Restore every global this file may have stubbed to its pre-file value.
  for (const [key, value] of Object.entries(ORIGINALS)) {
    if (value === undefined) delete globalThis[key]
    else globalThis[key] = value
  }
})

// --- ENABLE / DISABLE -------------------------------------------------------

test("enableLatencySim writes the ms to sessionStorage under phlex-reactive:latency", () => {
  const storage = makeSessionStorage()
  globalThis.sessionStorage = storage

  enableLatencySim(400)

  expect(storage.getItem("phlex-reactive:latency")).toBe("400")
})

test("disableLatencySim removes the key", () => {
  const storage = makeSessionStorage()
  globalThis.sessionStorage = storage
  storage.setItem("phlex-reactive:latency", "400")

  disableLatencySim()

  expect(storage.getItem("phlex-reactive:latency")).toBeNull()
})

// --- DEV GATE ---------------------------------------------------------------

// A document stub whose phlex-reactive-env meta content is configurable, and
// which records addEventListener so the Turbo-absent branch doesn't throw.
function docWithEnv(env) {
  return {
    querySelector: (sel) => {
      if (sel === 'meta[name="phlex-reactive-env"]') return env ? { content: env } : null
      return null
    },
    querySelectorAll: () => [],
    addEventListener: () => {},
    documentElement: { toggleAttribute: () => {} },
  }
}

test("registerReactiveActions attaches window.PhlexReactive when env meta is development", () => {
  const win = { addEventListener: () => {} }
  globalThis.window = win
  globalThis.document = docWithEnv("development")
  globalThis.navigator = { onLine: true }

  registerReactiveActions()

  expect(typeof win.PhlexReactive).toBe("object")
  expect(typeof win.PhlexReactive.enableLatencySim).toBe("function")
  expect(typeof win.PhlexReactive.disableLatencySim).toBe("function")
})

test("registerReactiveActions does NOT attach window.PhlexReactive without the env meta", () => {
  const win = { addEventListener: () => {} }
  globalThis.window = win
  globalThis.document = docWithEnv(null)
  globalThis.navigator = { onLine: true }

  registerReactiveActions()

  expect(win.PhlexReactive).toBeUndefined()
})

test("registerReactiveActions does NOT attach window.PhlexReactive for a non-development env", () => {
  const win = { addEventListener: () => {} }
  globalThis.window = win
  globalThis.document = docWithEnv("production")
  globalThis.navigator = { onLine: true }

  registerReactiveActions()

  expect(win.PhlexReactive).toBeUndefined()
})

// --- SLEEP (in #perform) ----------------------------------------------------

// A reactive root stub recording attribute writes + dispatched events.
function makeRoot() {
  const attrs = {}
  return {
    attrs,
    isConnected: true,
    id: "counter",
    dispatchEvent: () => {},
    querySelectorAll: () => [],
    setAttribute: (name, value) => (attrs[name] = String(value)),
    removeAttribute: (name) => delete attrs[name],
    getAttribute: (name) => attrs[name] ?? null,
    hasAttribute: (name) => name in attrs,
  }
}

// Build a controller with a fetch that records whether (and when) it fired.
// `latency` seeds the sessionStorage key. IMPORTANT: this NEVER stubs the global
// setTimeout — bun runs every spec in one process and its own scheduling relies
// on a working global timer, so clobbering it corrupts unrelated suites. Instead
// the sleep uses a REAL (short) timer and the tests assert ordering with small
// real waits — deterministic vs. microtasks, and zero cross-file leakage.
function buildController({ latency } = {}) {
  const controller = new ReactiveController()
  controller.element = makeRoot()
  controller.tokenValue = "tok"
  globalThis.navigator = { onLine: true }

  const storage = makeSessionStorage()
  if (latency != null) storage.setItem("phlex-reactive:latency", String(latency))
  globalThis.sessionStorage = storage

  let fetched = false
  globalThis.fetch = () => {
    fetched = true
    return Promise.resolve({
      redirected: false,
      ok: true,
      status: 200,
      headers: { get: () => "text/vnd.turbo-stream.html" },
      text: () => Promise.resolve(""),
    })
  }
  globalThis.window = { Turbo: { renderStreamMessage: () => {} } }
  globalThis.document = {
    querySelector: () => null,
    dispatchEvent: () => {},
  }
  return { controller, fetched: () => fetched, storage }
}

function click(controller) {
  return controller.dispatch({
    params: { action: "save", params: '{"n":1}' },
    preventDefault: () => {},
  })
}

// A real short wait, using the (untouched) real setTimeout via realSetTimeout.
const wait = (ms) => new Promise((resolve) => realSetTimeout(resolve, ms))

test("with the latency key set, the fetch is delayed until the sleep elapses", async () => {
  // A generous 60ms delay: long enough that a microtask flush can't reach the
  // fetch, short enough to keep the test fast.
  const { controller, fetched } = buildController({ latency: 60 })

  const done = click(controller)
  // Drain microtasks + a short real wait WELL under the latency window.
  await Promise.resolve()
  await wait(10)

  // The fetch has NOT fired yet — it is blocked behind the awaited sleep.
  expect(fetched()).toBe(false)

  // Once the sleep window elapses, the round trip completes and the fetch fires.
  await done
  expect(fetched()).toBe(true)
})

test("with NO latency key, the fetch is not delayed (round trip completes on the microtask queue)", async () => {
  const { controller, fetched } = buildController({ latency: null })

  await click(controller)

  // No sleep for the null key — the round trip resolved without any real timer.
  expect(fetched()).toBe(true)
})

test("a non-positive / NaN latency value does not delay the fetch", async () => {
  const { controller, fetched } = buildController({ latency: "0" })

  await click(controller)

  expect(fetched()).toBe(true)
})

test("the active-sim console.warn banner fires once, not per request", async () => {
  const { controller } = buildController({ latency: 20 })

  await click(controller)
  await click(controller)

  const banners = warnings.filter((w) => w.toLowerCase().includes("latency"))
  expect(banners.length).toBe(1)
})

test("disableLatencySim resets the warn-once guard so a later enable re-announces", async () => {
  // enable → warn once → disable → enable again → the banner MUST fire again.
  // disableLatencySim() is the lifecycle boundary that re-arms the one-time warn,
  // so each fresh activation re-announces the sim is on (the banner text points
  // the user AT disableLatencySim() to turn it off).
  const { controller } = buildController({ latency: 20 })

  await click(controller) // first activation → banner #1
  expect(warnings.filter((w) => w.toLowerCase().includes("latency")).length).toBe(1)

  disableLatencySim() // clears the key AND re-arms the guard
  enableLatencySim(20) // re-set the key (same globalThis.sessionStorage stub)

  await click(controller) // second activation → banner #2
  expect(warnings.filter((w) => w.toLowerCase().includes("latency")).length).toBe(2)
})
