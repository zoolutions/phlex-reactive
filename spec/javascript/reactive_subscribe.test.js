// Subscribe (issue #474), in features/subscribe.js:
//
//   data-reactive-subscribe="<signed src>"   the root subscribes to its own
//                                            broadcast stream; the module keeps
//                                            a <pgbus-stream-source> for it
//
// pgbus is not loaded here: a bare custom element stands in for
// <pgbus-stream-source>, and a test plays the transport by setting its
// connection-id. Requests go through the real controller's pipeline to a
// scripted fetch.
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll, beforeEach, afterEach } from "bun:test"
import { Window } from "happy-dom"

const window = new Window({ url: "http://localhost/" })
let ReactiveController
const SAVED = {}
const GLOBALS = ["document", "window", "Event", "CustomEvent", "MutationObserver", "fetch", "location", "customElements"]

window.customElements.define("pgbus-stream-source", class extends window.HTMLElement {})

beforeAll(async () => {
  mock.module("@hotwired/stimulus", () => ({ Controller: class {} }))
  ReactiveController = (await import("../../app/javascript/phlex/reactive/reactive_controller.js")).default
})

let requests
let controllers

beforeEach(() => {
  for (const key of GLOBALS) SAVED[key] = globalThis[key]
  globalThis.document = window.document
  globalThis.window = window
  globalThis.Event = window.Event
  globalThis.CustomEvent = window.CustomEvent
  globalThis.MutationObserver = window.MutationObserver
  globalThis.location = window.location
  globalThis.customElements = window.customElements
  window.Turbo = { renderStreamMessage: () => {} }
  requests = []
  globalThis.fetch = (_url, init) => {
    requests.push({ body: JSON.parse(init.body), headers: init.headers })
    return Promise.resolve({
      redirected: false,
      ok: true,
      status: 200,
      headers: { get: () => "text/vnd.turbo-stream.html" },
      text: () => Promise.resolve(""),
    })
  }
  document.body.innerHTML = ""
  controllers = []
})

afterEach(async () => {
  for (const controller of controllers) controller.disconnect?.()
  await flush()
  for (const [key, value] of Object.entries(SAVED)) globalThis[key] = value
})

const flush = async () => {
  for (let i = 0; i < 5; i++) await new Promise((resolve) => setTimeout(resolve, 0))
}

const widget = (id = "widget", src = "/pgbus/streams/signed-item:widget") =>
  `<div id="${id}" data-controller="reactive" data-reactive-token-value="tok-${id}"
        data-reactive-subscribe="${src}">${id}</div>`

function connect(root) {
  const controller = new ReactiveController()
  controller.element = root
  controller.tokenValue = root.getAttribute("data-reactive-token-value") ?? ""
  controller.connect()
  controllers.push(controller)
  return controller
}

function mount(html) {
  document.body.insertAdjacentHTML("beforeend", html)
  return [...document.querySelectorAll("[data-controller~='reactive']")]
    .filter((root) => !controllers.some((c) => c.element === root))
    .map(connect)
}

const sources = () => [...document.querySelectorAll("pgbus-stream-source[data-reactive-subscribe-source]")]

function disconnect(controller) {
  controller.disconnect()
  controllers.splice(controllers.indexOf(controller), 1)
}

function fireAction(controller) {
  const trigger = controller.element
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

test("a subscribing root mints one hidden source for its src in the sources box, without presence", () => {
  mount(widget())
  const [el] = sources()
  expect(sources().length).toBe(1)
  // The box: last in <body>, permanent (a page refresh by morph keeps it), in
  // a tag no server page renders (Idiomorph cannot pair it with a new node).
  expect(el.parentElement.localName).toBe("reactive-stream-sources")
  expect(el.parentElement.parentElement).toBe(document.body)
  expect(el.parentElement.hasAttribute("data-turbo-permanent")).toBe(true)
  expect(el.parentElement.hidden).toBe(true)
  expect(el.hidden).toBe(true)
  expect(el.getAttribute("src")).toBe("/pgbus/streams/signed-item:widget")
  expect(el.hasAttribute("presence")).toBe(false)
})

test("a root without the attribute mints nothing", () => {
  document.body.innerHTML = `<div id="plain" data-controller="reactive" data-reactive-token-value="t">x</div>`
  connect(document.getElementById("plain"))
  expect(document.querySelectorAll("pgbus-stream-source").length).toBe(0)
})

test("removing the root closes its source", async () => {
  const [controller] = mount(widget())
  controller.element.remove()
  disconnect(controller)
  await flush()
  expect(sources().length).toBe(0)
})

test("a replace that brings the same root id back keeps the one connection", async () => {
  const [controller] = mount(widget())
  const before = sources()[0]
  const old = controller.element
  old.insertAdjacentHTML("afterend", widget())
  const fresh = old.nextElementSibling
  old.remove()
  disconnect(controller)
  connect(fresh)
  await flush()
  expect(sources()).toEqual([before])
})

test("a morph that keeps the src keeps the source; one that re-keys moves the root", async () => {
  const [controller] = mount(widget())
  const before = sources()[0]

  controller.element.setAttribute("data-reactive-subscribe", "/pgbus/streams/signed-item:widget")
  controller.element.textContent = "morphed"
  await flush()
  expect(sources()).toEqual([before])

  controller.element.setAttribute("data-reactive-subscribe", "/pgbus/streams/signed-other:widget")
  await flush()
  expect(sources().map((s) => s.getAttribute("src"))).toEqual(["/pgbus/streams/signed-other:widget"])
  expect(before.isConnected).toBe(false)

  controller.element.removeAttribute("data-reactive-subscribe")
  await flush()
  expect(sources().length).toBe(0)
})

test("two roots with the same src share one source, closed when the last one goes", async () => {
  const [a, b] = mount(widget("a") + widget("b"))
  expect(sources().length).toBe(1)

  a.element.remove()
  disconnect(a)
  await flush()
  expect(sources().length).toBe(1)

  b.element.remove()
  disconnect(b)
  await flush()
  expect(sources().length).toBe(0)
})

test("two roots with different srcs get one source each, in one box", () => {
  mount(widget("a", "/pgbus/streams/signed-one") + widget("b", "/pgbus/streams/signed-two"))
  expect(sources().map((s) => s.getAttribute("src")).sort()).toEqual(["/pgbus/streams/signed-one", "/pgbus/streams/signed-two"])
  expect(document.querySelectorAll("reactive-stream-sources").length).toBe(1)
})

test("a Turbo cache restore's clone of a source is replaced by a fresh one", async () => {
  const [controller] = mount(widget())
  const clone = sources()[0].cloneNode()
  controller.element.remove()
  disconnect(controller)
  await flush()

  // The restored snapshot: the old page's source comes back as a clone.
  document.body.appendChild(clone)
  mount(widget())
  expect(sources().length).toBe(1)
  expect(sources()[0]).not.toBe(clone)
  expect(clone.isConnected).toBe(false)
})

test("a root whose id changes while connected still releases its source", async () => {
  const [controller] = mount(widget())
  controller.element.id = "renamed"
  controller.element.remove()
  disconnect(controller)
  await flush()
  expect(sources().length).toBe(0)
})

test("an action ignores another source of the same src the page renders itself", async () => {
  // A server-rendered source for the same stream (no subscribe mark), connected first.
  document.body.innerHTML =
    '<pgbus-stream-source src="/pgbus/streams/signed-item:widget" connection-id="page-conn"></pgbus-stream-source>'
  const [controller] = mount(widget())
  sources()[0].setAttribute("connection-id", "own-conn")

  await fireAction(controller)
  await flush()

  expect(requests[0].headers["X-Pgbus-Connection"]).toBe("own-conn")
})

test("an action from a subscribing root sends its own source's connection id", async () => {
  // Another stream's source comes first on the page.
  document.body.innerHTML = '<pgbus-stream-source id="app" connection-id="app-conn"></pgbus-stream-source>'
  const [controller] = mount(widget())
  sources()[0].setAttribute("connection-id", "own-conn")

  await fireAction(controller)
  await flush()

  expect(requests.length).toBe(1)
  expect(requests[0].headers["X-Pgbus-Connection"]).toBe("own-conn")
})

test("before its own source connects, an action falls back to the page's first source", async () => {
  document.body.innerHTML = '<pgbus-stream-source id="app" connection-id="app-conn"></pgbus-stream-source>'
  const [controller] = mount(widget())

  await fireAction(controller)
  await flush()

  expect(requests[0].headers["X-Pgbus-Connection"]).toBe("app-conn")
})

test("a root that connects before pgbus defines its element mints the source, and errors only after the grace period", () => {
  const errors = []
  const savedError = console.error
  const savedTimeout = globalThis.setTimeout
  const timers = []
  console.error = (...args) => errors.push(args.join(" "))
  globalThis.customElements = { get: () => undefined }
  globalThis.setTimeout = (fn, ms) => timers.push({ fn, ms })
  try {
    mount(widget())
    expect(sources().length).toBe(1)
    expect(errors).toEqual([])

    for (const { fn } of timers.filter((t) => t.ms === 5000)) fn()
    expect(errors.length).toBe(1)
    expect(errors[0]).toContain('import "pgbus/stream_source_element"')
  } finally {
    console.error = savedError
    globalThis.setTimeout = savedTimeout
  }
})

test("a page render that drops the source anyway mints a fresh one for the root still on the page", () => {
  mount(widget())
  const before = sources()[0]
  before.remove() // Turbo 8's page morph: <body>'s children the server did not render go

  document.dispatchEvent(new CustomEvent("turbo:morph"))

  expect(sources().length).toBe(1)
  expect(sources()[0]).not.toBe(before)
  expect(sources()[0].getAttribute("src")).toBe("/pgbus/streams/signed-item:widget")
})

test("a page render mints nothing for a root that left the page with it", async () => {
  const [controller] = mount(widget())
  document.body.innerHTML = "" // a full render swapped <body>; the controller disconnects after
  document.dispatchEvent(new CustomEvent("turbo:render"))
  expect(sources().length).toBe(0)

  disconnect(controller)
  await flush()
  expect(sources().length).toBe(0)
})
