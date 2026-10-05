// Unit tests for dormant roots (issue #274). reactive_root(dormant: true)
// renders data-reactive-dormant="reactive" where an awake root has
// data-controller="reactive": no controller is mounted (or fetched, when it
// loads lazily) until one of the root's triggers fires. Wire contract:
//
//   early.js     also treats [data-reactive-dormant~="reactive"] as a root. On
//                the first recorded trigger it WAKES the root — moves the
//                identifier into data-controller, keeping the controllers
//                already listed — synchronously, in the capture phase.
//   connect()    replays the queued trigger exactly as for any early event
//                (issue #273); the live event that woke the root is not
//                dispatched a second time when it reaches the listener
//                Stimulus bound during that same event.
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll, beforeEach } from "bun:test"
import { Window } from "happy-dom"

const KEY = Symbol.for("phlex-reactive.early")
const window = new Window()
let startEarly
let ReactiveController

beforeAll(async () => {
  globalThis.document = window.document
  globalThis.CustomEvent = window.CustomEvent
  globalThis.MutationObserver = window.MutationObserver
  mock.module("@hotwired/stimulus", () => ({ Controller: class {} }))
  // early.js binds the shared state object once, at import — and another test
  // file may have replaced it since. A fresh module instance over a fresh
  // state keeps this file independent of the order the suite runs in.
  delete globalThis[KEY]
  ;({ startEarly } = await import("../../app/javascript/phlex/reactive/early.js?dormant"))
  const mod = await import("../../app/javascript/phlex/reactive/reactive_controller.js")
  // The opt-in entry: it tells the shared runtime where each feature module
  // lives, which the load-up-front seam below goes through.
  await import("../../app/javascript/phlex/reactive/core.js")
  ReactiveController = mod.default
  // The defer code is a feature module (issue #275). Loaded up front, so a
  // connect or a `reactive:defer` stream reaches it in the same tick; the
  // not-yet-loaded path is covered in reactive_features.test.js.
  await mod.__loadReactiveFeatureForTest("defer")
})

beforeEach(() => {
  globalThis.document = window.document
  globalThis.CustomEvent = window.CustomEvent
  document.head.innerHTML = ""
  document.body.innerHTML = ""
  state().queue.length = 0
  startEarly(document)
})

const state = () => globalThis[KEY]
const flush = () => new Promise((resolve) => setTimeout(resolve, 0))

async function mount(html) {
  document.body.innerHTML = html
  await window.happyDOM.waitUntilComplete()
  await flush()
  return document.body.firstElementChild
}

function click(el) {
  const event = new window.MouseEvent("click", { bubbles: true, cancelable: true })
  el.dispatchEvent(event)
  return event
}

// A controller whose dispatch/runOps are recorded instead of run.
function connect(root) {
  const controller = new ReactiveController()
  controller.element = root
  const calls = []
  controller.dispatch = (event) => calls.push({ method: "dispatch", event })
  controller.runOps = (event) => calls.push({ method: "runOps", event })
  controller.connect()
  return { controller, calls }
}

function realConnect(root) {
  const controller = new ReactiveController()
  controller.element = root
  controller.connect()
  return controller
}

// Count real dispatches through the reactive:before-dispatch veto point (the
// veto also keeps the test from enqueueing a fetch).
function countDispatches(root) {
  const seen = []
  root.addEventListener("reactive:before-dispatch", (event) => {
    seen.push(event.detail.action)
    event.preventDefault()
  })
  return seen
}

// The ORIGINAL event object as Stimulus's binding hands it over once it reaches
// `el` (currentTarget is only set during propagation, so it is pinned here).
function liveEventFor(event, el) {
  Object.defineProperty(event, "currentTarget", { value: el, configurable: true })
  Object.defineProperty(event, "params", {
    value: { action: el.getAttribute("data-reactive-action-param") },
    configurable: true,
  })
  return event
}

// --- early.js: waking -----------------------------------------------------------

test("the first trigger on a dormant root queues it and wakes the root", async () => {
  const root = await mount(`
    <div id="menu" data-reactive-dormant="reactive">
      <button data-action="click->reactive#dispatch" data-reactive-action-param="load">Open</button>
    </div>`)
  const event = click(root.querySelector("button"))

  expect(state().queue).toHaveLength(1)
  expect(state().queue[0].root).toBe(root)
  expect(event.defaultPrevented).toBe(true)
  expect(root.hasAttribute("data-reactive-dormant")).toBe(false)
  expect(root.getAttribute("data-controller")).toBe("reactive")
})

test("waking keeps the other controllers already on the root", async () => {
  const root = await mount(`
    <div id="menu" data-controller="dropdown tooltip" data-reactive-dormant="reactive"
         data-action="panel:opened->reactive#dispatch:once"></div>`)
  root.dispatchEvent(new window.CustomEvent("panel:opened"))

  expect(root.getAttribute("data-controller")).toBe("dropdown tooltip reactive")
  expect(root.hasAttribute("data-reactive-dormant")).toBe(false)
})

test("a dormant root is not woken by an event that is not one of its triggers", async () => {
  const root = await mount(`
    <div id="menu" data-reactive-dormant="reactive">
      <button data-action="click->reactive#dispatch">Open</button>
      <span>plain</span>
    </div>`)
  const event = click(root.querySelector("span"))

  expect(state().queue).toHaveLength(0)
  expect(event.defaultPrevented).toBe(false)
  expect(root.getAttribute("data-reactive-dormant")).toBe("reactive")
  expect(root.hasAttribute("data-controller")).toBe(false)
})

test("an on_client trigger wakes a dormant root too", async () => {
  const root = await mount(`
    <div id="menu" data-reactive-dormant="reactive">
      <button data-action="click->reactive#runOps">Toggle</button>
    </div>`)
  click(root.querySelector("button"))
  const { calls } = connect(root)

  expect(calls.map((call) => call.method)).toEqual(["runOps"])
})

test("two triggers before connect wake once and replay in order", async () => {
  const root = await mount(`
    <div id="menu" data-reactive-dormant="reactive">
      <button id="a" data-action="click->reactive#dispatch" data-reactive-action-param="first">A</button>
      <button id="b" data-action="click->reactive#dispatch" data-reactive-action-param="second">B</button>
    </div>`)
  click(root.querySelector("#a"))
  click(root.querySelector("#b"))

  expect(root.getAttribute("data-controller")).toBe("reactive")
  const { calls } = connect(root)
  expect(calls.map((call) => call.event.params.action)).toEqual(["first", "second"])
})

test("a :once trigger fired three times on a dormant root replays once", async () => {
  const root = await mount(
    `<div id="menu" data-reactive-dormant="reactive" data-action="panel:opened->reactive#dispatch:once"></div>`,
  )
  for (let i = 0; i < 3; i++) root.dispatchEvent(new window.CustomEvent("panel:opened"))
  const { calls } = connect(root)

  expect(calls).toHaveLength(1)
})

test("a dormant root inside a connected root owns its own triggers", async () => {
  const outer = await mount(`
    <div id="outer" data-controller="reactive">
      <div id="inner" data-reactive-dormant="reactive">
        <button data-action="click->reactive#dispatch">Open</button>
      </div>
    </div>`)
  state().connected.add(outer)
  const inner = outer.querySelector("#inner")
  click(inner.querySelector("button"))

  expect(state().queue).toHaveLength(1)
  expect(state().queue[0].root).toBe(inner)
  // Woken synchronously, in the capture phase: by the time the click bubbles
  // to Stimulus's listener the button is in the INNER root's scope, so the
  // outer controller's binding does not take it.
  expect(inner.getAttribute("data-controller")).toBe("reactive")
})

test("a connected root inside a dormant root does not wake it", async () => {
  const outer = await mount(`
    <div id="outer" data-reactive-dormant="reactive" data-action="panel:opened->reactive#dispatch">
      <div id="inner" data-controller="reactive"><button data-action="click->reactive#dispatch">Go</button></div>
    </div>`)
  state().connected.add(outer.querySelector("#inner"))
  click(outer.querySelector("button"))

  expect(state().queue).toHaveLength(0)
  expect(outer.getAttribute("data-reactive-dormant")).toBe("reactive")
})

test("a morph that renders a woken root dormant again lets the next trigger re-wake it", async () => {
  const root = await mount(
    `<div id="menu" data-reactive-dormant="reactive"><button data-action="click->reactive#dispatch">Open</button></div>`,
  )
  const button = root.querySelector("button")
  click(button)
  const first = connect(root)
  expect(first.calls).toHaveLength(1)

  // The morph writes the server's attributes back; Stimulus disconnects.
  root.removeAttribute("data-controller")
  root.setAttribute("data-reactive-dormant", "reactive")
  first.controller.disconnect()

  click(button)
  expect(root.getAttribute("data-controller")).toBe("reactive")
  const second = connect(root)
  expect(second.calls).toHaveLength(1)
})

// A replayed :once trigger is remembered as spent per element, so a morph REPLY
// (root still connected) cannot re-arm it. A dormant morph-back DISCONNECTS the
// root, and Stimulus binds a fresh `once` when it reconnects — the spent memory
// must go with the disconnect, or the trigger is dead on that element for good.
test("a replayed :once trigger fires again after the root went back to sleep and re-woke", async () => {
  const root = await mount(
    `<div id="menu" data-reactive-dormant="reactive" data-action="panel:opened->reactive#dispatch:once"></div>`,
  )
  root.dispatchEvent(new window.CustomEvent("panel:opened"))
  const first = connect(root)
  expect(first.calls).toHaveLength(1)

  root.removeAttribute("data-controller")
  root.setAttribute("data-reactive-dormant", "reactive")
  first.controller.disconnect()

  root.dispatchEvent(new window.CustomEvent("panel:opened"))
  root.dispatchEvent(new window.CustomEvent("panel:opened"))
  const second = connect(root)
  expect(second.calls).toHaveLength(1)
})

// --- reactive_controller.js: the waking event is handled once ---------------------

// With the controller registered EAGERLY, moving the identifier into
// data-controller connects it in the microtask checkpoint right after the
// capture listener returns (a real user event). connect() replays the click —
// and then the SAME click reaches the listener Stimulus just bound.
test("the live event that woke a root is not dispatched again after its replay", async () => {
  const root = await mount(`
    <div id="menu" data-reactive-dormant="reactive">
      <button data-action="click->reactive#dispatch" data-reactive-action-param="load">Open</button>
    </div>`)
  const button = root.querySelector("button")
  const seen = countDispatches(root)
  const event = click(button)
  const controller = realConnect(root)
  expect(seen).toEqual(["load"])

  controller.dispatch(liveEventFor(event, button))
  expect(seen).toEqual(["load"])

  // A later, different click is live again.
  controller.dispatch(liveEventFor(new window.MouseEvent("click"), button))
  expect(seen).toEqual(["load", "load"])
})

// The mark only has to outlive the propagation the replay happened in: an app
// that dispatches the SAME event object again later must get a live dispatch.
test("the replayed event's object is live again once its propagation is over", async () => {
  const root = await mount(`
    <div id="menu" data-reactive-dormant="reactive">
      <button data-action="click->reactive#dispatch" data-reactive-action-param="load">Open</button>
    </div>`)
  const button = root.querySelector("button")
  const seen = countDispatches(root)
  const event = click(button)
  const controller = realConnect(root)
  expect(seen).toEqual(["load"])

  await flush()
  controller.dispatch(liveEventFor(event, button))
  expect(seen).toEqual(["load", "load"])
})

// reactive_lazy(on: "x") + reactive_dormant (issue #276): the event shell's
// once-bound __materialize trigger is an ordinary descriptor, so it wakes the
// root and is replayed once.
test("a dormant reactive_lazy(on:) event shell wakes and materializes once", async () => {
  const root = await mount(`
    <div id="panel" class="reactive-defer-placeholder" data-reactive-dormant="reactive"
         data-action="panel:opened->reactive#dispatch:once" data-reactive-action-param="__materialize"
         data-reactive-params-param="{}" data-reactive-lazy-on="panel:opened"></div>`)
  root.dispatchEvent(new window.CustomEvent("panel:opened"))
  root.dispatchEvent(new window.CustomEvent("panel:opened"))
  expect(root.getAttribute("data-controller")).toBe("reactive")
  const { calls } = connect(root)

  expect(calls.map((call) => call.event.params.action)).toEqual(["__materialize"])
})

// Only what the replay actually RAN is dropped when the original arrives live.
// A binding early.js could not see (a key filter under the app's own Stimulus
// key mapping) was never replayed, so its live call must go through.
test("a live binding the replay did not run is not swallowed", async () => {
  const root = await mount(`
    <div id="menu" data-reactive-dormant="reactive">
      <input data-action="keydown.enter->reactive#dispatch keydown.submit->reactive#dispatch" data-reactive-action-param="save">
    </div>`)
  const input = root.querySelector("input")
  const seen = countDispatches(root)
  const event = new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true })
  input.dispatchEvent(event)
  const controller = realConnect(root)
  // early.js queued the event for keydown.enter only ("submit" is not a
  // default key name), and without the app's mapping the replay skips it too.
  expect(seen).toEqual(["save"])

  // Stimulus (with the app's `submit: "Enter"` mapping) calls both bindings.
  controller.dispatch(liveEventFor(event, input))
  expect(seen).toEqual(["save"])
  controller.dispatch(liveEventFor(event, input))
  expect(seen).toEqual(["save", "save"])
})

test("the same goes for an on_client trigger", async () => {
  const root = await mount(`
    <div id="menu" data-reactive-dormant="reactive">
      <button data-action="click->reactive#runOps" data-reactive-ops-param='[["toggle_class",{"to":"@root","classes":["open"]}]]'>Toggle</button>
    </div>`)
  const button = root.querySelector("button")
  const event = click(button)
  const controller = realConnect(root)
  expect(root.classList.contains("open")).toBe(true)

  Object.defineProperty(event, "currentTarget", { value: button, configurable: true })
  Object.defineProperty(event, "params", {
    value: { ops: JSON.parse(button.getAttribute("data-reactive-ops-param")) },
    configurable: true,
  })
  controller.runOps(event)
  expect(root.classList.contains("open")).toBe(true)
})

test("an outer root's own binding still runs for the event an inner root replayed", async () => {
  const outer = await mount(`
    <div id="outer" data-controller="reactive" data-action="click->reactive#dispatch" data-reactive-action-param="outer">
      <div id="inner" data-reactive-dormant="reactive">
        <button data-action="click->reactive#dispatch" data-reactive-action-param="inner">Open</button>
      </div>
    </div>`)
  const outerController = realConnect(outer)
  const seen = countDispatches(outer)
  const inner = outer.querySelector("#inner")
  const button = inner.querySelector("button")
  const event = click(button)
  realConnect(inner)
  expect(seen).toEqual(["inner"])

  outerController.dispatch(liveEventFor(event, outer))
  expect(seen).toEqual(["inner", "outer"])
})
