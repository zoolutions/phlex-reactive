// Unit tests for the reactive REQUEST TOTALS (issue #279). Alongside the
// in-flight activity count (issue #201), the client keeps a running total of
// the reactive requests it has made, per kind:
//
//   * action — one per action POST (#perform's fetch)
//   * defer  — one per deferred-render POST (performDeferFetch)
//
// The totals live as JSON on <html data-reactive-requests> (e.g.
// {"action":1,"defer":0}) — the attribute IS the store, so a system test can
// read it, and reset it by writing zeros, with no window hook. It is written
// ONLY under the verbose gate (data-reactive-verbose on <html>, or on any
// reactive root — stamped in dev/test by default): production writes nothing.
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
  // The opt-in entry: it tells the shared runtime where each feature module
  // lives, which the load-up-front seam below goes through.
  await import("../../app/javascript/phlex/reactive/core.js")
  // The defer code is a feature module (issue #275). Loaded up front, so a
  // connect or a `reactive:defer` stream reaches it in the same tick; the
  // not-yet-loaded path is covered in reactive_features.test.js.
  defer = await mod.__loadReactiveFeatureForTest("defer")
  ReactiveController = mod.default
})

const flush = async (times = 6) => {
  for (let i = 0; i < times; i++) await Promise.resolve()
}

// A document stub with a real <html> attribute store. `verboseRoot` models a
// reactive root carrying data-reactive-verbose="true" somewhere in the page.
function stubDocument({ byId = {}, metas = {}, verboseRoot = false, htmlAttrs = {} } = {}) {
  const rootAttrs = { ...htmlAttrs }
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
      if (sel === '[data-reactive-verbose="true"]') return verboseRoot ? {} : null
      const name = sel.match(/meta\[name="([^"]+)"\]/)?.[1]
      return name && metas[name] != null ? { content: metas[name] } : null
    },
    createElement: () => ({ setAttribute() {}, id: "" }),
    body: { appendChild: () => {} },
    addEventListener: () => {},
    dispatchEvent: () => true,
  }
  return { rootAttrs }
}

function stubTurbo() {
  globalThis.window = { Turbo: { StreamActions: {}, renderStreamMessage: () => {} } }
  return globalThis.window.Turbo.StreamActions
}

const totals = (rootAttrs) => JSON.parse(rootAttrs["data-reactive-requests"])

function makeRoot() {
  const attrs = { "data-reactive-verbose": "true" }
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
    closest: () => null,
    getAttribute: (n) => (n in attrs ? attrs[n] : null),
    setAttribute: (n, v) => {
      attrs[n] = String(v)
    },
    removeAttribute: (n) => {
      delete attrs[n]
    },
    hasAttribute: (n) => n in attrs,
    classList: { add() {}, remove() {}, toggle() {}, contains: () => false },
  }
}

function okResponse(html = "") {
  return {
    redirected: false,
    ok: true,
    status: 200,
    headers: { get: () => "text/vnd.turbo-stream.html" },
    text: () => Promise.resolve(html),
  }
}

function fireDispatch(controller) {
  const trigger = makeTrigger()
  return controller.dispatch({
    target: trigger,
    currentTarget: trigger,
    params: { action: "save", params: "{}" },
    defaultPrevented: false,
    preventDefault() {
      this.defaultPrevented = true
    },
  })
}

function buildController() {
  const controller = new ReactiveController()
  controller.element = makeRoot()
  controller.tokenValue = "tok"
  globalThis.queueMicrotask ??= (fn) => Promise.resolve().then(fn)
  return controller
}

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
  }
}

function directiveEl(target) {
  const attrs = { target, "data-reactive-defer-via": "fetch", "data-reactive-defer-token": "t" }
  return { getAttribute: (n) => attrs[n] ?? null }
}

beforeEach(() => {
  mod.resetReactiveActivity()
  defer.resetReactiveDefers()
})

test("exports the counter primitive and the attribute name", () => {
  expect(typeof mod.countReactiveRequest).toBe("function")
  expect(mod.REQUESTS_ATTR).toBe("data-reactive-requests")
})

test("counts per kind under a verbose root, mirrored as JSON on <html>", () => {
  const { rootAttrs } = stubDocument({ verboseRoot: true })
  mod.countReactiveRequest("action")
  expect(totals(rootAttrs)).toEqual({ action: 1, defer: 0 })
  mod.countReactiveRequest("defer")
  mod.countReactiveRequest("action")
  expect(totals(rootAttrs)).toEqual({ action: 2, defer: 1 })
})

test("<html data-reactive-verbose> alone opens the gate", () => {
  const { rootAttrs } = stubDocument({ htmlAttrs: { "data-reactive-verbose": "" } })
  mod.countReactiveRequest("action")
  expect(totals(rootAttrs)).toEqual({ action: 1, defer: 0 })
})

test("with verbose off nothing is written to <html>", () => {
  const { rootAttrs } = stubDocument()
  mod.countReactiveRequest("action")
  mod.countReactiveRequest("defer")
  expect("data-reactive-requests" in rootAttrs).toBe(false)
})

test("the attribute is the store: writing zeros (a test reset) re-baselines", () => {
  const { rootAttrs } = stubDocument({ verboseRoot: true })
  mod.countReactiveRequest("action")
  mod.countReactiveRequest("action")
  rootAttrs["data-reactive-requests"] = JSON.stringify({ action: 0, defer: 0 })
  mod.countReactiveRequest("action")
  expect(totals(rootAttrs)).toEqual({ action: 1, defer: 0 })
})

test("a missing or garbled attribute restarts from zero rather than throwing", () => {
  const { rootAttrs } = stubDocument({ verboseRoot: true, htmlAttrs: { "data-reactive-requests": "{nope" } })
  expect(() => mod.countReactiveRequest("defer")).not.toThrow()
  expect(totals(rootAttrs)).toEqual({ action: 0, defer: 1 })
})

test("no document (non-browser) is a safe no-op", () => {
  const saved = globalThis.document
  delete globalThis.document
  try {
    expect(() => mod.countReactiveRequest("action")).not.toThrow()
  } finally {
    globalThis.document = saved
  }
})

test("an action dispatch counts one action request", async () => {
  const { rootAttrs } = stubDocument({ verboseRoot: true })
  stubTurbo()
  globalThis.fetch = async () => okResponse()
  const controller = buildController()

  await fireDispatch(controller)
  await controller.queue
  expect(totals(rootAttrs)).toEqual({ action: 1, defer: 0 })

  await fireDispatch(controller)
  await controller.queue
  expect(totals(rootAttrs)).toEqual({ action: 2, defer: 0 })
})

test("a deferred render fetch counts one defer request", async () => {
  const el = makeDeferTarget("slow-totals")
  const { rootAttrs } = stubDocument({
    byId: { "slow-totals": el },
    metas: { "csrf-token": "c" },
    verboseRoot: true,
  })
  const actions = stubTurbo()
  globalThis.fetch = async () => okResponse("<turbo-stream></turbo-stream>")
  mod.registerReactiveDefer()

  actions["reactive:defer"].call(directiveEl("slow-totals"))
  await flush()
  expect(totals(rootAttrs)).toEqual({ action: 0, defer: 1 })
})
