// reactive_lazy(on:) client half (issue #276). The server renders an on:
// shell with the IDENTITY token — NO defer token — plus one of two markers:
//
//   data-reactive-lazy-on="<event>"       an event shell (it also carries the
//                                         once-bound `<event>->reactive#dispatch`
//                                         descriptor for __materialize)
//   data-reactive-lazy-visible="<margin>" a visibility shell (no descriptor)
//
// Every materialize funnels through ONE controller method, whichever way it
// starts (the Stimulus binding, the IntersectionObserver, a morph), so:
//   * connect() never fetches for a shell;
//   * a :visible shell materializes straight from the observer callback;
//   * a root showing REAL content that a Turbo morph turns back into a shell
//     re-materializes at once (it was loaded; the morph wiped it);
//   * a shell that is still unloaded after a morph (never triggered, or a
//     failed load) is re-armed — its spent `once` binding is not relied on;
//   * a morph landing mid-flight never double-requests, and a morph that
//     leaves real content real requests nothing.
//
// Every assertion below counts actual `__materialize` POSTs, not observers.
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll, beforeEach, afterEach } from "bun:test"

let Controller

beforeAll(async () => {
  mock.module("@hotwired/stimulus", () => ({
    Controller: class {
      constructor() {}
    },
  }))
  Controller = (await import("../../app/javascript/phlex/reactive/reactive_controller.js")).default
})

let observers
let posts
let nextResponse

class FakeIntersectionObserver {
  constructor(callback, options) {
    this.callback = callback
    this.options = options
    this.observed = []
    this.disconnected = false
    observers.push(this)
  }
  observe(el) {
    this.observed.push(el)
  }
  disconnect() {
    this.disconnected = true
  }
  trigger(isIntersecting) {
    if (this.disconnected) return
    this.callback([{ isIntersecting, target: this.observed[0] }])
  }
}

const okResponse = (body = "") => ({
  redirected: false,
  ok: true,
  status: 200,
  headers: { get: () => "text/vnd.turbo-stream.html" },
  text: () => Promise.resolve(body),
})

// A response the test releases later: queued duplicates would run (and POST)
// once it resolves, so "still one POST after release" proves none were queued.
function gate() {
  let release
  const promise = new Promise((resolve) => (release = () => resolve(okResponse())))
  return { promise, release }
}

// Let the queued #perform (and its finally) run to completion.
const settle = () => new Promise((resolve) => setTimeout(resolve, 0))

beforeEach(() => {
  observers = []
  posts = []
  // Each POST consumes nextResponse(): a response, a rejection, or a pending gate.
  nextResponse = () => Promise.resolve(okResponse())
  globalThis.IntersectionObserver = FakeIntersectionObserver
  globalThis.window = { Turbo: { StreamActions: {}, renderStreamMessage: () => {} } }
  globalThis.document = {
    getElementById: () => null,
    querySelector: () => null,
    addEventListener: () => {},
    dispatchEvent: () => {},
  }
  globalThis.fetch = (url, options) => {
    posts.push(JSON.parse(options.body))
    return nextResponse()
  }
})

afterEach(() => {
  delete globalThis.IntersectionObserver
})

const TOKEN = "data-reactive-token-value"
const ON = "data-reactive-lazy-on"
const VISIBLE = "data-reactive-lazy-visible"

function makeRoot(attrs = {}) {
  const listeners = {}
  const el = {
    id: "lazy-root",
    isConnected: true,
    attrs: { ...attrs },
    listeners,
    getAttribute: (name) => el.attrs[name] ?? null,
    hasAttribute: (name) => name in el.attrs,
    setAttribute: (name, value) => (el.attrs[name] = value),
    removeAttribute: (name) => delete el.attrs[name],
    dispatchEvent: () => true,
    querySelectorAll: () => [],
    contains: () => true,
    addEventListener: (name, fn) => (listeners[name] ??= []).push(fn),
    removeEventListener: (name, fn) => {
      listeners[name] = (listeners[name] ?? []).filter((registered) => registered !== fn)
    },
    // Fire a DOM event at the root's own listeners (the controller's, not Stimulus's).
    fire: (name) => (listeners[name] ?? []).slice().forEach((fn) => fn({ type: name })),
    // A Turbo morph rewrote the root's attributes in place, then announced it.
    morphTo: (next) => {
      el.attrs = { ...next }
      el.fire("turbo:morph-element")
    },
  }
  return el
}

function connect(el) {
  const controller = new Controller()
  controller.element = el
  // Stimulus's value getter reads the live attribute.
  Object.defineProperty(controller, "tokenValue", { get: () => el.attrs[TOKEN] })
  controller.connect()
  return controller
}

// What Stimulus does when the shell's once-bound descriptor fires.
function stimulusFires(controller) {
  return controller.dispatch({
    params: { action: "__materialize", params: "{}" },
    currentTarget: controller.element,
    target: controller.element,
    preventDefault: () => {},
  })
}

const visibleShell = (token = "shell-token") => ({ [TOKEN]: token, [VISIBLE]: "0px" })
const eventShell = (token = "shell-token") => ({ [TOKEN]: token, [ON]: "panel:opened" })
const realContent = (token = "real-token") => ({ [TOKEN]: token })

// --- connect ----------------------------------------------------------------

test("a visible shell observes itself with the rendered rootMargin and requests nothing", async () => {
  const el = makeRoot({ [TOKEN]: "shell-token", [VISIBLE]: "200px" })
  connect(el)
  await settle()

  expect(observers.length).toBe(1)
  expect(observers[0].options).toEqual({ rootMargin: "200px" })
  expect(observers[0].observed).toEqual([el])
  expect(posts).toEqual([])
})

test("an event shell requests nothing on connect and never observes", async () => {
  connect(makeRoot(eventShell()))
  await settle()

  expect(observers.length).toBe(0)
  expect(posts).toEqual([])
})

// --- the first materialize ----------------------------------------------------

test("intersecting POSTs __materialize once, straight from the controller, and stops observing", async () => {
  const el = makeRoot(visibleShell())
  connect(el)

  observers[0].trigger(false)
  await settle()
  expect(posts).toEqual([])

  observers[0].trigger(true)
  await settle()
  expect(posts).toEqual([{ token: "shell-token", act: "__materialize", params: {} }])
  expect(observers[0].disconnected).toBe(true)
})

test("the event shell's Stimulus binding POSTs __materialize once", async () => {
  const controller = connect(makeRoot(eventShell()))

  stimulusFires(controller)
  await settle()
  expect(posts).toEqual([{ token: "shell-token", act: "__materialize", params: {} }])
})

test("a second trigger while the first is in flight does not double-request", async () => {
  const pending = gate()
  nextResponse = () => pending.promise
  const controller = connect(makeRoot(eventShell()))

  stimulusFires(controller)
  stimulusFires(controller)
  await settle()
  expect(posts.length).toBe(1)

  pending.release()
  await settle()
  expect(posts.length).toBe(1)
})

test("without IntersectionObserver the visible shell materializes right after connect", async () => {
  delete globalThis.IntersectionObserver
  connect(makeRoot(visibleShell()))

  await settle()
  expect(posts.map((post) => post.act)).toEqual(["__materialize"])
})

test("disconnect() tears the observer down", () => {
  const controller = connect(makeRoot(visibleShell()))

  controller.disconnect()
  expect(observers[0].disconnected).toBe(true)
})

// --- real content morphed BACK into a shell (the root connected as real) -----

test("real content morphed back into a :visible shell re-materializes at once — one request", async () => {
  const el = makeRoot(realContent())
  connect(el)

  el.morphTo(visibleShell("morphed-token"))
  await settle()

  // No observer needed: it was loaded, the morph wiped it. The morphed-in
  // shell's token (server truth) is the one sent.
  expect(posts).toEqual([{ token: "morphed-token", act: "__materialize", params: {} }])
})

test("real content morphed back into an event shell re-materializes at once — one request", async () => {
  const el = makeRoot(realContent())
  connect(el)

  el.morphTo(eventShell("morphed-token"))
  await settle()

  expect(posts).toEqual([{ token: "morphed-token", act: "__materialize", params: {} }])
})

test("each morph-back costs exactly one request, even when a second morph lands mid-flight", async () => {
  const pending = gate()
  nextResponse = () => pending.promise
  const el = makeRoot(realContent())
  connect(el)

  el.morphTo(eventShell())
  el.morphTo(eventShell())
  await settle()
  expect(posts.length).toBe(1)

  pending.release()
  await settle()
  expect(posts.length).toBe(1)
})

test("a morph that leaves real content as real content requests nothing", async () => {
  const el = makeRoot(realContent())
  connect(el)

  el.morphTo(realContent("fresh-token"))
  await settle()

  expect(posts).toEqual([])
  expect(observers.length).toBe(0)
})

// --- a shell that is STILL an unloaded shell after a morph --------------------

test("a failed :visible load is retried after a morph: re-observe, then fire directly", async () => {
  nextResponse = () => Promise.reject(new Error("offline"))
  const el = makeRoot(visibleShell())
  connect(el)
  observers[0].trigger(true)
  await settle()
  expect(posts.length).toBe(1)

  // The failed shell alone never retries…
  await settle()
  expect(posts.length).toBe(1)

  // …a morph re-arms it, and the next intersection requests again.
  nextResponse = () => Promise.resolve(okResponse())
  el.morphTo(visibleShell())
  expect(observers.length).toBe(2)
  observers[1].trigger(true)
  await settle()
  expect(posts.length).toBe(2)
  expect(posts[1].act).toBe("__materialize")
})

test("a failed event load is retried after a morph: the event is accepted again", async () => {
  nextResponse = () => Promise.reject(new Error("offline"))
  const el = makeRoot(eventShell())
  const controller = connect(el)
  stimulusFires(controller)
  await settle()
  expect(posts.length).toBe(1)

  // Stimulus's `once` binding is spent; before a morph the event is dead.
  el.fire("panel:opened")
  await settle()
  expect(posts.length).toBe(1)

  nextResponse = () => Promise.resolve(okResponse())
  el.morphTo(eventShell())
  el.fire("panel:opened")
  await settle()
  expect(posts.length).toBe(2)
  expect(posts[1].act).toBe("__materialize")
})

test("a re-armed event listener is consumed by its attempt: one morph buys one retry", async () => {
  nextResponse = () => Promise.reject(new Error("offline"))
  const el = makeRoot(eventShell())
  const controller = connect(el)
  stimulusFires(controller)
  await settle()

  el.morphTo(eventShell())
  el.fire("panel:opened")
  await settle()
  expect(posts.length).toBe(2)

  // That retry failed too. Without another morph the event is dead again.
  el.fire("panel:opened")
  await settle()
  expect(posts.length).toBe(2)

  el.morphTo(eventShell())
  el.fire("panel:opened")
  await settle()
  expect(posts.length).toBe(3)
})

test("a never-triggered event shell after a morph requests once when both bindings fire", async () => {
  const pending = gate()
  nextResponse = () => pending.promise
  const el = makeRoot(eventShell())
  const controller = connect(el)

  el.morphTo(eventShell())
  await settle()
  expect(posts).toEqual([])

  // The intact Stimulus binding AND the re-armed listener both see the event.
  stimulusFires(controller)
  el.fire("panel:opened")
  await settle()
  expect(posts.length).toBe(1)

  pending.release()
  await settle()
  expect(posts.length).toBe(1)
})

test("a never-triggered :visible shell after a morph keeps ONE live observer", async () => {
  const el = makeRoot(visibleShell())
  connect(el)

  el.morphTo(visibleShell())
  const live = observers.filter((observer) => !observer.disconnected)
  expect(live.length).toBe(1)

  live[0].trigger(true)
  await settle()
  expect(posts.length).toBe(1)
})

test("a morph landing while the shell's load is in flight does not double-request", async () => {
  const pending = gate()
  nextResponse = () => pending.promise
  const el = makeRoot(visibleShell())
  connect(el)
  observers[0].trigger(true)
  await settle()
  expect(posts.length).toBe(1)

  el.morphTo(visibleShell())
  observers.forEach((observer) => observer.trigger(true))
  await settle()
  expect(posts.length).toBe(1)

  pending.release()
  await settle()
  expect(posts.length).toBe(1)
})

test("a shell morphed into real content stops observing and listening", async () => {
  const el = makeRoot(visibleShell())
  connect(el)

  el.morphTo(realContent())
  expect(observers[0].disconnected).toBe(true)
  observers[0].trigger(true)
  await settle()
  expect(posts).toEqual([])
})

// --- cost gate ----------------------------------------------------------------

test("a tokenless (client-only) root wires no morph listener", () => {
  const el = makeRoot({})
  connect(el)

  expect(el.listeners["turbo:morph-element"] ?? []).toEqual([])
})
