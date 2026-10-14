// Issue #400: a deadline counted down on the client (features/countdown.js).
//
//   data-reactive-countdown='{"until":"<ISO8601>","format":"ms","waiting":"#wait","done":"#done"}'
//
// Every tick reads Date.now against the deadline; at zero the text is 0:00,
// data-reactive-countdown-state is "done", waiting: hides, done: shows and
// reactive:countdown-done fires once per deadline. Fake timers drive the
// clock; a morph is played by rewriting the DOM and dispatching
// turbo:morph-element, as Turbo does after Idiomorph.
//
// Run with: bun test spec/javascript
import { test, expect, mock, jest, beforeAll, beforeEach, afterEach } from "bun:test"
import { Window } from "happy-dom"

const window = new Window({ url: "http://localhost/" })
let ReactiveController
const SAVED = {}
const GLOBALS = ["document", "window", "Event", "CustomEvent", "MutationObserver", "fetch", "location"]
const NOW = Date.parse("2026-10-14T12:00:00Z")

beforeAll(async () => {
  mock.module("@hotwired/stimulus", () => ({ Controller: class {} }))
  ReactiveController = (await import("../../app/javascript/phlex/reactive/reactive_controller.js")).default
})

let requests
let controllers
let rootSeq = 0

beforeEach(() => {
  for (const key of GLOBALS) SAVED[key] = globalThis[key]
  globalThis.document = window.document
  globalThis.window = window
  globalThis.Event = window.Event
  globalThis.CustomEvent = window.CustomEvent
  globalThis.MutationObserver = window.MutationObserver
  globalThis.location = window.location
  requests = []
  globalThis.fetch = (url) => {
    requests.push(url)
    return Promise.reject(new Error("no network"))
  }
  document.body.innerHTML = ""
  controllers = []
  jest.useFakeTimers({ now: NOW })
})

afterEach(() => {
  for (const controller of controllers) controller.disconnect?.()
  jest.useRealTimers()
  delete document.visibilityState
  for (const [key, value] of Object.entries(SAVED)) globalThis[key] = value
})

const iso = (secondsFromNow) => new Date(Date.now() + secondsFromNow * 1000).toISOString()
const attr = (wire) => JSON.stringify({ format: "ms", ...wire }).replaceAll('"', "&quot;")
const microtasks = async () => {
  for (let i = 0; i < 3; i++) await Promise.resolve()
}

// A root with a countdown, its waiting and done nodes. Each test gets a fresh
// root id unless it names one (a replace keeps the id).
function mount({ until, text = "9:99", id = `clock-${++rootSeq}`, extra = "" }) {
  document.body.insertAdjacentHTML(
    "beforeend",
    `<div id="${id}" data-controller="reactive" data-reactive-token-value="t">
       <span id="${id}-c" data-reactive-countdown="${attr({ until, waiting: "#w", done: "#d" })}">${text}</span>
       <div id="w">Waiting</div>
       <div id="d" hidden>Finished</div>
       ${extra}
     </div>`,
  )
  const root = document.getElementById(id)
  const span = document.getElementById(`${id}-c`)
  const events = []
  root.addEventListener("reactive:countdown-done", (event) => events.push(event))
  return { root, span, events, wait: root.querySelector("#w"), done: root.querySelector("#d") }
}

function connect(root) {
  const controller = new ReactiveController()
  controller.element = root
  controller.tokenValue = root.getAttribute("data-reactive-token-value") ?? ""
  controller.connect()
  controllers.push(controller)
  return controller
}

test("a deadline 90 seconds ahead paints 1:30 on connect, whatever the server rendered", () => {
  const { root, span, wait, done } = mount({ until: iso(90), text: "2:00" })
  connect(root)

  expect(span.textContent).toBe("1:30")
  expect(span.getAttribute("data-reactive-countdown-state")).toBe("running")
  expect(wait.hidden).toBe(false)
  expect(done.hidden).toBe(true)
})

test("after 61 seconds of a two-minute deadline the text is 0:59", () => {
  const { root, span } = mount({ until: iso(120) })
  connect(root)
  expect(span.textContent).toBe("2:00")

  jest.advanceTimersByTime(1000)
  expect(span.textContent).toBe("1:59")
  jest.advanceTimersByTime(60_000)
  expect(span.textContent).toBe("0:59")
})

test("a fractional deadline ticks on the second boundary", () => {
  const { root, span } = mount({ until: new Date(Date.now() + 1500).toISOString() })
  connect(root)
  expect(span.textContent).toBe("0:02")

  jest.advanceTimersByTime(499)
  expect(span.textContent).toBe("0:02")
  jest.advanceTimersByTime(1)
  expect(span.textContent).toBe("0:01")
})

test("minutes are unpadded and not capped at an hour", () => {
  const { root, span } = mount({ until: iso(90 * 60 + 5) })
  connect(root)
  expect(span.textContent).toBe("90:05")
})

test("at zero: 0:00, state done, waiting hidden, done shown, one event", () => {
  const { root, span, events, wait, done } = mount({ until: iso(3) })
  connect(root)

  jest.advanceTimersByTime(3000)
  expect(span.textContent).toBe("0:00")
  expect(span.getAttribute("data-reactive-countdown-state")).toBe("done")
  expect(wait.hidden).toBe(true)
  expect(done.hidden).toBe(false)
  expect(events).toHaveLength(1)
  expect(events[0].target).toBe(span)
  expect(events[0].bubbles).toBe(true)

  jest.advanceTimersByTime(10_000)
  expect(events).toHaveLength(1)
  expect(jest.getTimerCount()).toBe(0)
})

test("a deadline already past on connect finishes at once and starts no timer", () => {
  const { root, span, events, wait, done } = mount({ until: iso(-30), text: "0:30" })
  connect(root)

  expect(span.textContent).toBe("0:00")
  expect(span.getAttribute("data-reactive-countdown-state")).toBe("done")
  expect(wait.hidden).toBe(true)
  expect(done.hidden).toBe(false)
  expect(events).toHaveLength(1)
  expect(jest.getTimerCount()).toBe(0)
})

test("a tab hidden for the whole wait finishes on wake from Date.now, not from late ticks", () => {
  const { root, span, events } = mount({ until: iso(120) })
  connect(root)
  expect(span.textContent).toBe("2:00")

  // The background tab's timers never ran; the clock moved on.
  Object.defineProperty(document, "visibilityState", { value: "hidden", configurable: true })
  document.dispatchEvent(new window.Event("visibilitychange"))
  jest.setSystemTime(NOW + 300_000)
  Object.defineProperty(document, "visibilityState", { value: "visible", configurable: true })
  document.dispatchEvent(new window.Event("visibilitychange"))

  expect(span.textContent).toBe("0:00")
  expect(events).toHaveLength(1)
  expect(jest.getTimerCount()).toBe(0)
})

test("a wake before the deadline jumps to the real remaining time", () => {
  const { root, span } = mount({ until: iso(120) })
  connect(root)

  jest.setSystemTime(NOW + 75_000)
  Object.defineProperty(document, "visibilityState", { value: "visible", configurable: true })
  document.dispatchEvent(new window.Event("visibilitychange"))
  expect(span.textContent).toBe("0:45")
  expect(jest.getTimerCount()).toBe(1)
})

test("a morph that keeps the deadline repaints the done state without a second event", async () => {
  const { root, span, events, wait, done } = mount({ until: iso(2) })
  connect(root)
  jest.advanceTimersByTime(2000)
  expect(events).toHaveLength(1)

  // Idiomorph wrote the server's render back over the client's.
  span.textContent = "0:02"
  span.removeAttribute("data-reactive-countdown-state")
  wait.hidden = false
  done.hidden = true
  span.dispatchEvent(new window.CustomEvent("turbo:morph-element", { bubbles: true }))
  root.dispatchEvent(new window.CustomEvent("turbo:morph-element", { bubbles: true }))
  await microtasks()

  expect(span.textContent).toBe("0:00")
  expect(span.getAttribute("data-reactive-countdown-state")).toBe("done")
  expect(wait.hidden).toBe(true)
  expect(done.hidden).toBe(false)
  expect(events).toHaveLength(1)
})

test("a morph that changes the deadline counts down again and fires again", async () => {
  const { root, span, events, wait, done } = mount({ until: iso(1) })
  connect(root)
  jest.advanceTimersByTime(1000)
  expect(events).toHaveLength(1)

  span.setAttribute("data-reactive-countdown", JSON.stringify({ until: iso(5), format: "ms", waiting: "#w", done: "#d" }))
  root.dispatchEvent(new window.CustomEvent("turbo:morph-element", { bubbles: true }))
  await microtasks()
  expect(span.textContent).toBe("0:05")
  expect(span.getAttribute("data-reactive-countdown-state")).toBe("running")
  expect(wait.hidden).toBe(false)
  expect(done.hidden).toBe(true)

  jest.advanceTimersByTime(5000)
  expect(span.textContent).toBe("0:00")
  expect(events).toHaveLength(2)
})

test("a morph mid-countdown keeps one timer, not two", async () => {
  const { root, span } = mount({ until: iso(10) })
  connect(root)
  root.dispatchEvent(new window.CustomEvent("turbo:morph-element", { bubbles: true }))
  root.dispatchEvent(new window.CustomEvent("turbo:morph-element", { bubbles: true }))
  await microtasks()
  expect(jest.getTimerCount()).toBe(1)
  jest.advanceTimersByTime(1000)
  expect(span.textContent).toBe("0:09")
})

test("a countdown a morph removed stops its timer", async () => {
  const { root, span } = mount({ until: iso(10) })
  connect(root)
  span.remove()
  root.dispatchEvent(new window.CustomEvent("turbo:morph-element", { bubbles: true }))
  await microtasks()
  expect(jest.getTimerCount()).toBe(0)
})

test("a replace of the root that keeps the deadline does not fire again", () => {
  const first = mount({ until: iso(1), id: "replaced" })
  const until = JSON.parse(first.span.getAttribute("data-reactive-countdown")).until
  const controller = connect(first.root)
  jest.advanceTimersByTime(1000)
  expect(first.events).toHaveLength(1)

  controller.disconnect()
  first.root.remove()
  const again = mount({ until, id: "replaced", text: "0:01" })
  connect(again.root)
  expect(again.span.textContent).toBe("0:00")
  expect(again.events).toHaveLength(0)
})

test("disconnect clears the timer", () => {
  const { root, span } = mount({ until: iso(10) })
  const controller = connect(root)
  expect(jest.getTimerCount()).toBe(1)

  controller.disconnect()
  expect(jest.getTimerCount()).toBe(0)
  jest.advanceTimersByTime(20_000)
  expect(span.textContent).toBe("0:10")
})

test("the root itself can be the countdown", () => {
  document.body.insertAdjacentHTML(
    "beforeend",
    `<span id="self-clock" data-controller="reactive" data-reactive-token-value="t" data-reactive-countdown="${attr({ until: iso(65) })}">x</span>`,
  )
  const root = document.getElementById("self-clock")
  connect(root)
  expect(root.textContent).toBe("1:05")
})

test("a nested root's countdown is the nested root's, not the parent's", () => {
  const { root } = mount({
    until: iso(30),
    extra: `<div id="inner" data-controller="reactive" data-reactive-token-value="t2">
              <span id="inner-c" data-reactive-countdown="${attr({ until: iso(45) })}">x</span>
            </div>`,
  })
  connect(root)
  expect(document.getElementById("inner-c").textContent).toBe("x")
})

test("an unparseable deadline is left alone", () => {
  document.body.insertAdjacentHTML(
    "beforeend",
    `<div id="bad" data-controller="reactive" data-reactive-token-value="t">
       <span id="bad-c" data-reactive-countdown="${attr({ until: "soon" })}">2:00</span>
     </div>`,
  )
  connect(document.getElementById("bad"))
  expect(document.getElementById("bad-c").textContent).toBe("2:00")
  expect(jest.getTimerCount()).toBe(0)
})

test("the countdown never requests the network", () => {
  const { root } = mount({ until: iso(2) })
  connect(root)
  jest.advanceTimersByTime(5000)
  expect(requests).toEqual([])
})
