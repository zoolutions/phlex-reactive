// reactive_lazy(cache:) client half (issue #277). A `cache:` shell carries a
// stable, signed fragment URL in data-reactive-defer-src instead of a defer
// token (plain shell) or alongside the identity token (on: shell). Every load
// of such a shell is a plain GET of that URL on the defer pull lane — no
// method, no body, no CSRF header — so the browser's private HTTP cache can
// answer it:
//   * a plain cached shell GETs on connect (and when a morph re-shows it);
//   * an on: shell GETs when its event / visibility trigger fires, once;
//   * real content morphed back into a cached shell GETs again (a cache hit in
//     a browser), instead of POSTing __materialize.
// A shell WITHOUT the URL keeps its POST (the defer endpoint, or __materialize).
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll, beforeEach, afterEach } from "bun:test"

let Controller
let resetReactiveDefers
let REQUESTS_ATTR

beforeAll(async () => {
  mock.module("@hotwired/stimulus", () => ({
    Controller: class {
      constructor() {}
    },
  }))
  const mod = await import("../../app/javascript/phlex/reactive/reactive_controller.js")
  Controller = mod.default
  // The defer code is a feature module (issue #275). Loaded up front, so a
  // connect or a `reactive:defer` stream reaches it in the same tick; the
  // not-yet-loaded path is covered in reactive_features.test.js.
  resetReactiveDefers = (await mod.__loadReactiveFeatureForTest("defer")).resetReactiveDefers
  REQUESTS_ATTR = mod.REQUESTS_ATTR
})

let observers
let calls
let nextResponse
let rendered
let byId
let html
let metas
let bodyMetas

class FakeIntersectionObserver {
  constructor(callback) {
    this.callback = callback
    this.disconnected = false
    observers.push(this)
  }
  observe() {}
  disconnect() {
    this.disconnected = true
  }
  trigger() {
    if (!this.disconnected) this.callback([{ isIntersecting: true }])
  }
}

const response = (status = 200, body = "<turbo-stream></turbo-stream>") => ({
  redirected: false,
  ok: status >= 200 && status < 300,
  status,
  headers: { get: () => "text/vnd.turbo-stream.html" },
  text: () => Promise.resolve(body),
})

function gate() {
  let release
  const promise = new Promise((resolve) => (release = () => resolve(response())))
  return { promise, release }
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 0))

beforeEach(() => {
  resetReactiveDefers()
  delete globalThis[Symbol.for("phlex-reactive.early")]
  observers = []
  calls = []
  rendered = []
  byId = {}
  nextResponse = () => Promise.resolve(response())
  globalThis.IntersectionObserver = FakeIntersectionObserver
  metas = {}
  bodyMetas = {}
  globalThis.window = {
    Turbo: { StreamActions: {}, renderStreamMessage: (body) => rendered.push(body) },
    location: { href: "https://app.example/dashboard" },
  }
  const htmlAttrs = { "data-reactive-verbose": "" }
  html = {
    attrs: htmlAttrs,
    hasAttribute: (name) => name in htmlAttrs,
    getAttribute: (name) => htmlAttrs[name] ?? null,
    setAttribute: (name, value) => (htmlAttrs[name] = value),
    removeAttribute: (name) => delete htmlAttrs[name],
  }
  globalThis.document = {
    documentElement: html,
    getElementById: (id) => byId[id] ?? null,
    // <head> holds `metas`; a document-wide query also sees `bodyMetas` —
    // markup a page could have had injected into its body.
    head: { querySelector: (selector) => findMeta(selector, metas) },
    querySelector: (selector) => findMeta(selector, metas) ?? findMeta(selector, bodyMetas),
    addEventListener: () => {},
    dispatchEvent: () => {},
  }
  globalThis.fetch = (url, options) => {
    calls.push({ url, options })
    return nextResponse()
  }
})

afterEach(() => {
  delete globalThis.IntersectionObserver
})

function findMeta(selector, source) {
  const name = selector.match(/meta\[name="([^"]+)"\]/)?.[1]
  return name && source[name] ? { content: source[name] } : null
}

const TOKEN = "data-reactive-token-value"
const ON = "data-reactive-lazy-on"
const VISIBLE = "data-reactive-lazy-visible"
const SRC = "data-reactive-defer-src"
const DEFER_TOKEN = "data-reactive-defer-token"
const PENDING = "data-reactive-defer-pending"
const URL = "/reactive/fragment/abc123?v=0011223344556677"

function makeRoot(attrs = {}) {
  const listeners = {}
  const el = {
    id: "cached-root",
    isConnected: true,
    attrs: { ...attrs },
    dispatched: [],
    getAttribute: (name) => el.attrs[name] ?? null,
    hasAttribute: (name) => name in el.attrs,
    setAttribute: (name, value) => (el.attrs[name] = value),
    removeAttribute: (name) => delete el.attrs[name],
    dispatchEvent: (event) => {
      el.dispatched.push(event)
      return true
    },
    querySelectorAll: () => [],
    contains: () => true,
    get attributes() {
      return Object.entries(el.attrs).map(([name, value]) => ({ name, value }))
    },
    addEventListener: (name, fn) => (listeners[name] ??= []).push(fn),
    removeEventListener: (name, fn) => {
      listeners[name] = (listeners[name] ?? []).filter((registered) => registered !== fn)
    },
    fire: (name, event = {}) =>
      (listeners[name] ?? []).slice().forEach((fn) => fn({ type: name, target: el, ...event })),
    morphTo: (next) => {
      el.attrs = { ...next }
      el.fire("turbo:morph-element")
    },
  }
  byId[el.id] = el
  return el
}

function connect(el) {
  const controller = new Controller()
  controller.element = el
  Object.defineProperty(controller, "tokenValue", { get: () => el.attrs[TOKEN] })
  controller.connect()
  return controller
}

function stimulusFires(controller) {
  return controller.dispatch({
    type: "panel:opened",
    params: { action: "__materialize", params: "{}" },
    currentTarget: controller.element,
    target: controller.element,
    preventDefault: () => {},
  })
}

const cachedShell = () => ({ [SRC]: URL, [PENDING]: "true" })
const plainShell = () => ({ [DEFER_TOKEN]: "defer-token", [PENDING]: "true" })
const cachedEventShell = () => ({ [TOKEN]: "shell-token", [ON]: "panel:opened", [SRC]: URL })
const cachedVisibleShell = () => ({ [TOKEN]: "shell-token", [VISIBLE]: "0px", [SRC]: URL })
const realContent = () => ({ [TOKEN]: "real-token" })

function expectFragmentGet(call) {
  expect(call.url).toBe(URL)
  expect(call.options.method).toBeUndefined()
  expect(call.options.body).toBeUndefined()
  expect(call.options.credentials).toBe("same-origin")
  expect(call.options.headers).toEqual({ Accept: "text/vnd.turbo-stream.html" })
  expect(call.options.signal).toBeDefined()
}

// --- the plain cached shell (fetch on connect) --------------------------------

test("a cached shell GETs its fragment URL on connect — no method, body or CSRF header", async () => {
  connect(makeRoot(cachedShell()))
  await settle()

  expect(calls.length).toBe(1)
  expectFragmentGet(calls[0])
})

test("the fragment response is applied like a defer response and clears pending", async () => {
  nextResponse = () => Promise.resolve(response(200, "<turbo-stream>menu</turbo-stream>"))
  const el = makeRoot(cachedShell())
  connect(el)
  await settle()

  expect(rendered).toEqual(["<turbo-stream>menu</turbo-stream>"])
  expect(el.attrs[PENDING]).toBeUndefined()
})

test("a 204 keeps the shell and clears pending", async () => {
  nextResponse = () => Promise.resolve(response(204, ""))
  const el = makeRoot(cachedShell())
  connect(el)
  await settle()

  expect(rendered).toEqual([])
  expect(el.attrs[PENDING]).toBeUndefined()
  expect(el.attrs["data-reactive-error"]).toBeUndefined()
})

test("a failed fragment load marks the root and retry() GETs the same URL again", async () => {
  nextResponse = () => Promise.resolve(response(403, ""))
  const el = makeRoot(cachedShell())
  connect(el)
  await settle()

  expect(el.attrs["data-reactive-error"]).toBe("defer")
  const error = el.dispatched.find((event) => event.type === "reactive:error")
  expect(error.detail.status).toBe(403)

  nextResponse = () => Promise.resolve(response())
  error.detail.retry()
  await settle()

  expect(calls.length).toBe(2)
  expectFragmentGet(calls[1])
})

test("a fragment GET counts as a defer request (per fetch call, cache hit or not)", async () => {
  connect(makeRoot(cachedShell()))
  await settle()

  expect(JSON.parse(html.attrs[REQUESTS_ATTR])).toEqual({ action: 0, defer: 1 })
})

test("a plain shell (defer token, no URL) still POSTs the token to the defer endpoint", async () => {
  connect(makeRoot(plainShell()))
  await settle()

  expect(calls.length).toBe(1)
  expect(calls[0].url).toBe("/reactive/defer")
  expect(calls[0].options.method).toBe("POST")
  expect(JSON.parse(calls[0].options.body)).toEqual({ token: "defer-token" })
})

// --- the URL comes from the DOM: only this app's fragment endpoint is fetched ----

const refused = [
  ["another origin", "https://evil.example/reactive/fragment/abc"],
  ["a protocol-relative URL", "//evil.example/reactive/fragment/abc"],
  ["a same-origin path that is not the fragment endpoint", "/uploads/payload.html"],
  ["a path that only starts like it", "/reactive/fragmentx/abc"],
  ["a traversal out of the fragment endpoint", "/reactive/fragment/../../uploads/payload.html"],
  ["a javascript: URL", "javascript:alert(1)"],
]

for (const [label, src] of refused) {
  test(`a plain shell whose URL is ${label} is never fetched`, async () => {
    const el = makeRoot({ [SRC]: src, [PENDING]: "true" })
    connect(el)
    await settle()

    expect(calls).toEqual([])
    expect(rendered).toEqual([])
  })

  test(`…and the shell fails loudly instead of staying pending (${label})`, async () => {
    const el = makeRoot({ [SRC]: src, [PENDING]: "true" })
    connect(el)
    await settle()

    expect(el.attrs[PENDING]).toBeUndefined()
    expect(el.attrs["data-reactive-error"]).toBe("defer")
    const error = el.dispatched.find((event) => event.type === "reactive:error")
    expect(error.detail).toMatchObject({ kind: "defer", target: "cached-root", reason: "refused-url" })
    expect(error.detail.retry).toBeUndefined()
  })
}

test("a fragment-path meta injected into <body> is ignored — only <head> can widen the path", async () => {
  bodyMetas["phlex-reactive-fragment-path"] = "/uploads"
  connect(makeRoot({ [SRC]: "/uploads/payload", [PENDING]: "true" }))
  await settle()

  expect(calls).toEqual([])
})

// --- the response must BE a fragment --------------------------------------------

test("a redirected response (a filter's 302 to a sign-in page) is a failed load, never rendered", async () => {
  nextResponse = () => Promise.resolve({ ...response(200, "<html>sign in</html>"), redirected: true })
  const el = makeRoot(cachedShell())
  connect(el)
  await settle()

  expect(rendered).toEqual([])
  expect(el.attrs["data-reactive-error"]).toBe("defer")
  expect(el.dispatched.some((event) => event.type === "reactive:error")).toBe(true)
})

test("a 200 that is not a turbo-stream is a failed load, never rendered", async () => {
  nextResponse = () =>
    Promise.resolve({ ...response(200, "<html>oops</html>"), headers: { get: () => "text/html; charset=utf-8" } })
  const el = makeRoot(cachedShell())
  connect(el)
  await settle()

  expect(rendered).toEqual([])
  expect(el.attrs["data-reactive-error"]).toBe("defer")
})

test("the same holds for the token (POST) lane", async () => {
  nextResponse = () => Promise.resolve({ ...response(200, "<html>sign in</html>"), redirected: true })
  const el = makeRoot(plainShell())
  connect(el)
  await settle()

  expect(rendered).toEqual([])
  expect(el.attrs["data-reactive-error"]).toBe("defer")
})

test("an on: shell with a refused URL falls back to the signed __materialize POST", async () => {
  const controller = connect(
    makeRoot({ [TOKEN]: "shell-token", [ON]: "panel:opened", [SRC]: "https://evil.example/reactive/fragment/abc" }),
  )

  stimulusFires(controller)
  await settle()

  expect(calls.length).toBe(1)
  expect(calls[0].url).toBe("/reactive/actions")
  expect(JSON.parse(calls[0].options.body)).toEqual({ token: "shell-token", act: "__materialize", params: {} })
})

test("an absolute same-origin fragment URL is fetched", async () => {
  const src = "https://app.example/reactive/fragment/abc"
  connect(makeRoot({ [SRC]: src, [PENDING]: "true" }))
  await settle()

  expect(calls.map((call) => call.url)).toEqual([src])
})

test("the fragment path follows the phlex-reactive-fragment-path meta", async () => {
  metas["phlex-reactive-fragment-path"] = "/_r/frag"
  connect(makeRoot({ [SRC]: "/_r/frag/abc", [PENDING]: "true" }))
  const defaultPath = makeRoot({ [SRC]: URL, [PENDING]: "true" })
  defaultPath.id = "default-path"
  byId["default-path"] = defaultPath
  connect(defaultPath)
  await settle()

  expect(calls.map((call) => call.url)).toEqual(["/_r/frag/abc"])
})

// --- on: + cache: -------------------------------------------------------------

test("a cached event shell requests nothing on connect", async () => {
  connect(makeRoot(cachedEventShell()))
  await settle()

  expect(calls).toEqual([])
})

test("its event GETs the fragment URL once — never the __materialize POST", async () => {
  const controller = connect(makeRoot(cachedEventShell()))

  stimulusFires(controller)
  await settle()

  expect(calls.length).toBe(1)
  expectFragmentGet(calls[0])
})

test("reactive:before-dispatch can veto the cacheable GET, like any materialize", async () => {
  const el = makeRoot(cachedEventShell())
  const dispatch = el.dispatchEvent
  el.dispatchEvent = (event) => {
    if (event.type === "reactive:before-dispatch") event.preventDefault()
    return dispatch(event)
  }
  const controller = connect(el)

  stimulusFires(controller)
  await settle()

  expect(calls).toEqual([])
  const before = el.dispatched.find((event) => event.type === "reactive:before-dispatch")
  expect(before.detail).toMatchObject({ action: "__materialize", params: {} })
})

test("a vetoed load can be triggered again", async () => {
  const el = makeRoot(cachedEventShell())
  const dispatch = el.dispatchEvent
  let veto = true
  el.dispatchEvent = (event) => {
    if (veto && event.type === "reactive:before-dispatch") event.preventDefault()
    return dispatch(event)
  }
  const controller = connect(el)
  stimulusFires(controller)
  veto = false

  el.morphTo(realContent())
  el.morphTo(cachedEventShell())
  await settle()

  expect(calls.length).toBe(1)
})

test("a second trigger while the GET is in flight does not double-request", async () => {
  const pending = gate()
  nextResponse = () => pending.promise
  const controller = connect(makeRoot(cachedEventShell()))

  stimulusFires(controller)
  stimulusFires(controller)
  await settle()
  expect(calls.length).toBe(1)

  pending.release()
  await settle()
  expect(calls.length).toBe(1)
})

test("a cached :visible shell GETs when it intersects, once", async () => {
  connect(makeRoot(cachedVisibleShell()))
  await settle()
  expect(calls).toEqual([])

  observers[0].trigger()
  await settle()

  expect(calls.length).toBe(1)
  expectFragmentGet(calls[0])
  expect(observers[0].disconnected).toBe(true)
})

test("an on: shell WITHOUT the URL keeps the __materialize POST", async () => {
  const controller = connect(makeRoot({ [TOKEN]: "shell-token", [ON]: "panel:opened" }))

  stimulusFires(controller)
  await settle()

  expect(calls.length).toBe(1)
  expect(calls[0].options.method).toBe("POST")
  expect(JSON.parse(calls[0].options.body)).toEqual({ token: "shell-token", act: "__materialize", params: {} })
})

// --- morph-back -----------------------------------------------------------------

test("real content morphed back into a cached event shell GETs the URL (a cache hit in a browser)", async () => {
  const el = makeRoot(realContent())
  connect(el)

  el.morphTo(cachedEventShell())
  await settle()

  expect(calls.length).toBe(1)
  expectFragmentGet(calls[0])
})

test("real content morphed back into a cached :visible shell GETs the URL", async () => {
  const el = makeRoot(realContent())
  connect(el)

  el.morphTo(cachedVisibleShell())
  await settle()

  expect(calls.length).toBe(1)
  expectFragmentGet(calls[0])
})

test("real content morphed back into a plain cached shell GETs the URL", async () => {
  const el = makeRoot(realContent())
  connect(el)

  el.morphTo(cachedShell())
  await settle()

  expect(calls.length).toBe(1)
  expectFragmentGet(calls[0])
})

test("real content morphed back into a plain defer-token shell POSTs its token (no longer shimmers forever)", async () => {
  const el = makeRoot(realContent())
  connect(el)

  el.morphTo(plainShell())
  await settle()

  expect(calls.length).toBe(1)
  expect(calls[0].url).toBe("/reactive/defer")
  expect(JSON.parse(calls[0].options.body)).toEqual({ token: "defer-token" })
})

test("a cached shell re-shown by a morph while connected GETs exactly once per morph", async () => {
  const el = makeRoot(cachedShell())
  connect(el)
  await settle()
  expect(calls.length).toBe(1)

  el.morphTo(cachedShell())
  await settle()

  expect(calls.length).toBe(2)
})

test("a morph that leaves real content real requests nothing", async () => {
  const el = makeRoot(realContent())
  connect(el)

  el.morphTo(realContent())
  await settle()

  expect(calls).toEqual([])
})

test("a morph of a CHILD of a real root never probes", async () => {
  const el = makeRoot(realContent())
  connect(el)
  el.attrs = cachedShell()

  el.fire("turbo:morph-element", { target: { id: "a-child" } })
  await settle()

  expect(calls).toEqual([])
})
