// reactive_lazy(on:) client half (issue #276). The server renders an on:
// shell with the IDENTITY token and a once-bound `__materialize` trigger —
// NO defer token — so connect():
//   * never enters the defer fetch path for it (the trigger does the work);
//   * for a `data-reactive-lazy-visible` shell, observes the root with an
//     IntersectionObserver (rootMargin from the attribute) and fires a
//     NON-bubbling `reactive:visible` once it intersects, then stops observing;
//   * disconnects that observer on disconnect();
//   * without IntersectionObserver, fires right away (content still loads).
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
let fetchCalls

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
    this.callback([{ isIntersecting, target: this.observed[0] }])
  }
}

beforeEach(() => {
  observers = []
  fetchCalls = []
  globalThis.IntersectionObserver = FakeIntersectionObserver
  globalThis.window = { Turbo: { StreamActions: {}, renderStreamMessage: () => {} } }
  globalThis.document = { getElementById: () => null, querySelector: () => null, addEventListener: () => {} }
  globalThis.fetch = (url, options) => {
    fetchCalls.push({ url, options })
    return new Promise(() => {})
  }
})

afterEach(() => {
  delete globalThis.IntersectionObserver
})

function makeShell(attrs = {}) {
  const el = {
    id: "lazy-fold",
    attrs: { ...attrs },
    dispatched: [],
    getAttribute: (name) => el.attrs[name] ?? null,
    hasAttribute: (name) => name in el.attrs,
    setAttribute: (name, value) => (el.attrs[name] = value),
    removeAttribute: (name) => delete el.attrs[name],
    dispatchEvent: (event) => el.dispatched.push(event),
    querySelectorAll: () => [],
    addEventListener: () => {},
    removeEventListener: () => {},
  }
  return el
}

function connect(el) {
  const controller = new Controller()
  controller.element = el
  controller.connect()
  return controller
}

test("a visible shell observes itself with the rendered rootMargin and fetches nothing yet", () => {
  const el = makeShell({ "data-reactive-lazy-visible": "200px" })
  connect(el)

  expect(observers.length).toBe(1)
  expect(observers[0].options).toEqual({ rootMargin: "200px" })
  expect(observers[0].observed).toEqual([el])
  expect(el.dispatched).toEqual([])
  expect(fetchCalls.length).toBe(0)
})

test("intersecting fires one non-bubbling reactive:visible and stops observing", () => {
  const el = makeShell({ "data-reactive-lazy-visible": "0px" })
  connect(el)

  observers[0].trigger(false)
  expect(el.dispatched).toEqual([])

  observers[0].trigger(true)
  expect(el.dispatched.length).toBe(1)
  expect(el.dispatched[0].type).toBe("reactive:visible")
  expect(el.dispatched[0].bubbles).toBe(false)
  expect(observers[0].disconnected).toBe(true)
})

test("disconnect() tears the observer down", () => {
  const el = makeShell({ "data-reactive-lazy-visible": "0px" })
  const controller = connect(el)

  controller.disconnect()
  expect(observers[0].disconnected).toBe(true)
})

test("an event-triggered on: shell (no defer token, no visible marker) neither observes nor fetches", () => {
  const el = makeShell({ "data-reactive-token-value": "identity" })
  connect(el)

  expect(observers.length).toBe(0)
  expect(fetchCalls.length).toBe(0)
  expect(el.dispatched).toEqual([])
})

test("without IntersectionObserver the visible shell materializes right away", async () => {
  delete globalThis.IntersectionObserver
  const el = makeShell({ "data-reactive-lazy-visible": "0px" })
  connect(el)

  await Promise.resolve()
  expect(el.dispatched.map((e) => e.type)).toEqual(["reactive:visible"])
})
