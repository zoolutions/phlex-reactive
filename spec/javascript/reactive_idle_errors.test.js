// Issue #464: reactive:idle tells a failed round trip from an applied one, and
// fires only after the reply is drawn.
//
//   * The dispatch lane exits the activity counter only once every stream of
//     the root's own reply has rendered (a reply with no stream, or one whose
//     render a listener prevented, after one repaint).
//   * The busy window collects every failure raised inside it: reactive:idle's
//     detail carries `errors: [{ action, kind, status, root }]`, and <html>
//     carries data-reactive-errors (the same list, as JSON) from that idle edge
//     until the next busy edge.
//
// The Turbo stub announces each stream synchronously inside
// renderStreamMessage and renders it a beat later, as Turbo 8 does (it awaits
// nextRepaint before calling detail.render).
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll, beforeEach, afterEach } from "bun:test"
import { Window } from "happy-dom"

const window = new Window({ url: "http://localhost/" })
let runtime
let ReactiveController
const SAVED = {}
const GLOBALS = ["document", "window", "Event", "CustomEvent", "MutationObserver", "fetch", "location", "navigator"]

beforeAll(async () => {
  mock.module("@hotwired/stimulus", () => ({ Controller: class {} }))
  runtime = await import("../../app/javascript/phlex/reactive/reactive_controller.js")
  ReactiveController = runtime.default
  const saved = globalThis.document
  globalThis.document = window.document
  runtime.__resetReactiveStreamRenderForTest()
  runtime.registerReactiveStreamRender()
  globalThis.document = saved
})

let controllers
let idles
let replies // root id -> { apply, delay } for the stream its reply carries
let quietConsole

const ok = (body = "<turbo-stream></turbo-stream>") => ({
  redirected: false,
  ok: true,
  status: 200,
  headers: { get: (name) => (name.toLowerCase() === "content-type" ? "text/vnd.turbo-stream.html" : null) },
  text: () => Promise.resolve(body),
})

beforeEach(() => {
  for (const key of GLOBALS) SAVED[key] = globalThis[key]
  globalThis.document = window.document
  globalThis.window = window
  globalThis.Event = window.Event
  globalThis.CustomEvent = window.CustomEvent
  globalThis.MutationObserver = window.MutationObserver
  globalThis.location = window.location
  globalThis.navigator = { onLine: true }
  replies = {}
  window.Turbo = {
    // The body names the root whose reply it is: "<turbo-stream target=ID>".
    renderStreamMessage: (html) => {
      const id = html.match(/target="([^"]+)"/)?.[1]
      const reply = replies[id]
      if (!reply) return
      const stream = document.createElement("turbo-stream")
      const event = new window.CustomEvent("turbo:before-stream-render", {
        bubbles: true,
        cancelable: true,
        detail: { newStream: stream, render: async () => reply.apply() },
      })
      document.dispatchEvent(event)
      if (!event.defaultPrevented) setTimeout(() => event.detail.render(stream), reply.delay ?? 0)
    },
  }
  globalThis.fetch = () => Promise.resolve(ok())
  document.body.innerHTML = ""
  document.head.innerHTML = ""
  runtime.resetReactiveActivity()
  controllers = []
  idles = []
  document.addEventListener("reactive:idle", record)
  quietConsole = console.error
  console.error = () => {}
})

afterEach(() => {
  document.removeEventListener("reactive:idle", record)
  for (const controller of controllers) controller.disconnect?.()
  for (const [key, value] of Object.entries(SAVED)) globalThis[key] = value
  console.error = quietConsole
})

function record(event) {
  idles.push({ detail: event.detail, value: document.getElementById("v")?.textContent })
}

const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms))

function mount(id = "r", inner = '<span id="v">0</span>') {
  const holder = document.createElement("div")
  holder.innerHTML = `<div id="${id}" data-controller="reactive" data-reactive-token-value="tok">${inner}</div>`
  document.body.appendChild(holder.firstElementChild)
  const controller = new ReactiveController()
  controller.element = document.getElementById(id)
  controller.tokenValue = "tok"
  controller.connect()
  controllers.push(controller)
  return controller
}

const act = (controller, action = "save") => controller.dispatch({ params: { action }, preventDefault() {} })
const errorsAttr = () => document.documentElement.getAttribute("data-reactive-errors")

// --- idle waits for the reply to be drawn ------------------------------------

test("reactive:idle fires after the reply's stream has changed the DOM", async () => {
  const controller = mount()
  replies.r = { apply: () => (document.getElementById("v").textContent = "1"), delay: 20 }
  globalThis.fetch = () => Promise.resolve(ok('<turbo-stream target="r"></turbo-stream>'))

  await act(controller)

  expect(idles).toHaveLength(1)
  expect(idles[0].value).toBe("1")
  expect(idles[0].detail.count).toBe(0)
  expect(idles[0].detail.errors).toEqual([])
  expect(errorsAttr()).toBeNull()
})

test("a reply with no stream still reaches idle", async () => {
  const controller = mount()
  await act(controller)
  expect(idles).toHaveLength(1)
  expect(idles[0].detail.errors).toEqual([])
})

test("a stream whose render a listener prevented still reaches idle", async () => {
  const controller = mount()
  replies.r = { apply: () => (document.getElementById("v").textContent = "never") }
  globalThis.fetch = () => Promise.resolve(ok('<turbo-stream target="r"></turbo-stream>'))
  const prevent = (event) => event.preventDefault()
  document.addEventListener("turbo:before-stream-render", prevent)
  try {
    await act(controller)
  } finally {
    document.removeEventListener("turbo:before-stream-render", prevent)
  }
  expect(idles).toHaveLength(1)
  expect(idles[0].value).toBe("0")
})

test("a stream whose render never finishes cannot wedge the queue (capped at the action timeout)", async () => {
  document.head.innerHTML = '<meta name="phlex-reactive-timeout" content="40">'
  const controller = mount()
  replies.r = { apply: () => new Promise(() => {}) }
  globalThis.fetch = () => Promise.resolve(ok('<turbo-stream target="r"></turbo-stream>'))
  await act(controller)
  expect(idles).toHaveLength(1)
})

test("the next queued action starts only after the previous reply is drawn", async () => {
  const controller = mount()
  const seen = []
  replies.r = { apply: () => (document.getElementById("v").textContent = String(Number(document.getElementById("v").textContent) + 1)), delay: 15 }
  globalThis.fetch = () => {
    seen.push(document.getElementById("v").textContent)
    return Promise.resolve(ok('<turbo-stream target="r"></turbo-stream>'))
  }
  act(controller)
  await act(controller)
  await controller.queue
  expect(seen).toEqual(["0", "1"])
})

// --- the error ledger --------------------------------------------------------

const failures = {
  http: () => ({ redirected: false, ok: false, status: 500, headers: { get: () => "text/html" }, text: () => Promise.resolve("oops") }),
  redirected: () => ({ redirected: true, ok: true, status: 200, headers: { get: () => "text/html" }, text: () => Promise.resolve("") }),
  "content-type": () => ({ redirected: false, ok: true, status: 200, headers: { get: () => "text/html" }, text: () => Promise.resolve("<html>") }),
}
const statuses = { http: 500, redirected: 200, "content-type": 200 }

for (const kind of Object.keys(failures)) {
  test(`a ${kind} failure is listed in reactive:idle's errors and on <html>`, async () => {
    const controller = mount()
    globalThis.fetch = () => Promise.resolve(failures[kind]())
    await act(controller)
    const expected = [{ action: "save", kind, status: statuses[kind], root: "r" }]
    expect(idles).toHaveLength(1)
    expect(idles[0].detail.errors).toEqual(expected)
    expect(JSON.parse(errorsAttr())).toEqual(expected)
  })
}

test("a timeout is listed with a null status", async () => {
  const controller = mount()
  globalThis.fetch = () => Promise.reject(Object.assign(new Error("slow"), { name: "TimeoutError" }))
  await act(controller)
  expect(idles[0].detail.errors).toEqual([{ action: "save", kind: "timeout", status: null, root: "r" }])
})

test("a network failure and an offline send are listed", async () => {
  const controller = mount()
  globalThis.fetch = () => Promise.reject(new TypeError("Failed to fetch"))
  await act(controller)
  expect(idles[0].detail.errors.map((e) => e.kind)).toEqual(["network"])

  globalThis.navigator = { onLine: false }
  await act(controller)
  expect(idles[1].detail.errors.map((e) => e.kind)).toEqual(["offline"])
})

test("an apply failure is listed and marks the root data-reactive-error=apply", async () => {
  const controller = mount()
  window.Turbo.renderStreamMessage = () => {
    throw new Error("broken render")
  }
  await act(controller)
  expect(idles[0].detail.errors).toEqual([{ action: "save", kind: "apply", status: null, root: "r" }])
  expect(document.getElementById("r").getAttribute("data-reactive-error")).toBe("apply")
})

test("a non-OK turbo-stream reply waits for its stream, then lists the failure", async () => {
  const controller = mount()
  replies.r = { apply: () => (document.getElementById("v").textContent = "flash"), delay: 15 }
  globalThis.fetch = () =>
    Promise.resolve({
      redirected: false,
      ok: false,
      status: 422,
      headers: { get: () => "text/vnd.turbo-stream.html" },
      text: () => Promise.resolve('<turbo-stream target="r"></turbo-stream>'),
    })
  await act(controller)
  expect(idles[0].value).toBe("flash")
  expect(idles[0].detail.errors).toEqual([{ action: "save", kind: "http", status: 422, root: "r" }])
  expect(document.getElementById("r").getAttribute("data-reactive-error")).toBe("http")
})

test("the next busy edge clears the ledger and the <html> attribute", async () => {
  const controller = mount()
  globalThis.fetch = () => Promise.resolve(failures.http())
  await act(controller)
  expect(errorsAttr()).not.toBeNull()

  globalThis.fetch = () => Promise.resolve(ok())
  const busy = []
  const onBusy = () => busy.push(errorsAttr())
  document.addEventListener("reactive:busy", onBusy)
  try {
    await act(controller)
  } finally {
    document.removeEventListener("reactive:busy", onBusy)
  }
  expect(busy).toEqual([null])
  expect(idles[1].detail.errors).toEqual([])
  expect(errorsAttr()).toBeNull()
})

test("two concurrent roots, one failing: one entry, one idle once both settle", async () => {
  const good = mount("good")
  const bad = mount("bad", "")
  let releaseGood
  globalThis.fetch = (_url, init) => {
    const body = JSON.parse(init.body)
    if (body.act === "fail") return Promise.resolve(failures.http())
    return new Promise((resolve) => (releaseGood = () => resolve(ok())))
  }
  const first = act(good)
  await tick()
  await act(bad, "fail")
  expect(idles).toHaveLength(0)
  releaseGood()
  await first
  expect(idles).toHaveLength(1)
  expect(idles[0].detail.errors).toEqual([{ action: "fail", kind: "http", status: 500, root: "bad" }])
})

test("resetReactiveActivity clears the ledger and the attribute", async () => {
  const controller = mount()
  globalThis.fetch = () => Promise.resolve(failures.http())
  await act(controller)
  runtime.resetReactiveActivity()
  expect(errorsAttr()).toBeNull()
  runtime.enterReactiveActivity()
  runtime.exitReactiveActivity()
  expect(idles.at(-1).detail.errors).toEqual([])
})
