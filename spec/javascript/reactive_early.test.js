// Unit tests for the early-event capture (issue #273): phlex/reactive/early
// records a trigger event that reaches a reactive root BEFORE its controller
// connects, and the controller's connect() replays it. Wire contract:
//
//   early.js     one capture listener per trigger event type on document; it
//                records { event, el (the descriptor's element), root, descs,
//                at } on the queue at window[Symbol.for("phlex-reactive.early")]
//                and preventDefaults where dispatch()/runOps() would.
//   connect()    marks the root (data-reactive-connected + the shared
//                `connected` WeakSet), emits a bubbling reactive:connect, then
//                drains its own entries: dropped when older than the TTL or
//                when the element left the root (warned under verbose),
//                replayed otherwise — once per descriptor, `:once` consumed.
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll, beforeEach, afterEach } from "bun:test"
import { gzipSync } from "bun"
import { readFileSync } from "node:fs"
import { join } from "node:path"
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
  ;({ startEarly } = await import("../../app/javascript/phlex/reactive/early.js"))
  ReactiveController = (await import("../../app/javascript/phlex/reactive/reactive_controller.js")).default
})

const realWarn = console.warn
let warns = []

beforeEach(() => {
  globalThis.document = window.document
  globalThis.CustomEvent = window.CustomEvent
  document.head.innerHTML = ""
  document.body.innerHTML = ""
  state().queue.length = 0
  startEarly(document)
  warns = []
  console.warn = (...args) => warns.push(args.join(" "))
})

afterEach(() => {
  console.warn = realWarn
  performance.now = realNow
})

// Age the queued entries: move the clock both modules read (performance.now).
const realNow = performance.now
function advanceClock(ms) {
  const base = realNow.call(performance)
  performance.now = () => base + ms
}

const state = () => globalThis[KEY]
const flush = () => new Promise((resolve) => setTimeout(resolve, 0))

// Mount markup and let the MutationObserver register its trigger event types.
// happy-dom delivers mutation records on its own timers: wait for them rather
// than for one tick (one tick lost the race under a loaded full-suite run).
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

function connect(root) {
  const controller = new ReactiveController()
  controller.element = root
  const calls = []
  controller.dispatch = (event) => calls.push({ method: "dispatch", event })
  controller.runOps = (event) => calls.push({ method: "runOps", event })
  controller.connect()
  return { controller, calls }
}

// --- early.js: recording ------------------------------------------------------

test("records a click on an on() trigger inside a root that has not connected", async () => {
  const root = await mount(`
    <div id="panel" data-controller="reactive">
      <button data-action="click->reactive#dispatch" data-reactive-action-param="load"><span>Go</span></button>
    </div>`)
  const button = root.querySelector("button")
  const event = click(button.querySelector("span"))

  expect(state().queue).toHaveLength(1)
  const [entry] = state().queue
  expect(entry.el).toBe(button)
  expect(entry.root).toBe(root)
  expect(entry.event).toBe(event)
  expect(event.defaultPrevented).toBe(true)
})

test("records a custom event fired on the root itself", async () => {
  const root = await mount(`<div id="panel" data-controller="reactive" data-action="panel:opened->reactive#dispatch:once"></div>`)
  root.dispatchEvent(new window.CustomEvent("panel:opened", { detail: { from: "menu" } }))

  expect(state().queue).toHaveLength(1)
  expect(state().queue[0].event.detail).toEqual({ from: "menu" })
})

test("preventDefaults a submit trigger and a link click, like dispatch() would", async () => {
  const root = await mount(`
    <div id="f" data-controller="reactive">
      <form data-action="submit->reactive#dispatch"><input name="q"></form>
      <a href="/elsewhere" data-action="click->reactive#dispatch">Link</a>
    </div>`)
  const submit = new window.Event("submit", { bubbles: true, cancelable: true })
  root.querySelector("form").dispatchEvent(submit)
  const linkClick = click(root.querySelector("a"))

  expect(submit.defaultPrevented).toBe(true)
  expect(linkClick.defaultPrevented).toBe(true)
  expect(state().queue).toHaveLength(2)
})

test("keeps the native toggle of a checked: :keep checkbox, like dispatch() does", async () => {
  const root = await mount(`
    <div id="c" data-controller="reactive">
      <input type="checkbox" data-action="click->reactive#dispatch" data-reactive-optimistic-param='{"checked":"keep"}'>
    </div>`)
  const event = click(root.querySelector("input"))

  expect(event.defaultPrevented).toBe(false)
  expect(state().queue).toHaveLength(1)
})

test("ignores roots whose controller already connected (no double fire)", async () => {
  const root = await mount(`<div id="p" data-controller="reactive"><button data-action="click->reactive#dispatch">Go</button></div>`)
  state().connected.add(root)
  const event = click(root.querySelector("button"))

  expect(state().queue).toHaveLength(0)
  expect(event.defaultPrevented).toBe(false)
})

test("prevents every firing of a :once trigger (the replay, not the recorder, dedupes)", async () => {
  const root = await mount(`<div id="p" data-controller="reactive"><button data-action="click->reactive#dispatch:once">Go</button></div>`)
  const button = root.querySelector("button")
  const events = [click(button), click(button), click(button)]

  expect(events.every((event) => event.defaultPrevented)).toBe(true)
})

test("does not record foreign controllers' bindings, window-bound or not", async () => {
  const root = await mount(`
    <div id="p" data-controller="reactive">
      <button id="o" data-action="click->other#go click@window->other#go">O</button>
    </div>`)
  const event = click(root.querySelector("#o"))

  expect(state().queue).toHaveLength(0)
  expect(event.defaultPrevented).toBe(false)
})

// --- early.js: window-bound triggers (issue #303) ------------------------------

function press(target, key, init = {}) {
  const event = new window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...init })
  target.dispatchEvent(event)
  return event
}

const HOTKEY = `<div id="p" data-controller="reactive"><button id="h" data-action="keydown.k@window->reactive#dispatch" data-reactive-action-param="toggle" data-reactive-window-param="true">Panel</button></div>`

test("records a window-bound hotkey pressed anywhere on the page, without preventing it", async () => {
  const root = await mount(HOTKEY)
  const event = press(document.body, "k")

  expect(state().queue).toHaveLength(1)
  const [entry] = state().queue
  expect(entry.win).toBe(true)
  expect(entry.el).toBe(root.querySelector("#h"))
  expect(entry.root).toBe(root)
  // A window binding is never prevented (dispatch() does not either): a
  // browser shortcut on the same key keeps working.
  expect(event.defaultPrevented).toBe(false)
})

test("records a window-bound on_client trigger", async () => {
  await mount(`<div id="p" data-controller="reactive" data-action="click@window->reactive#runOps" data-reactive-ops-param='{"on":"click","window":true,"ops":[]}'></div>`)
  click(document.body)

  expect(state().queue.map((entry) => [entry.win, entry.descs[0].method])).toEqual([[true, "runOps"]])
})

test("a window-bound key filter must match, modifiers included", async () => {
  await mount(`<div id="p" data-controller="reactive"><span data-action="keydown.ctrl+k@window->reactive#dispatch"></span></div>`)
  press(document.body, "j", { ctrlKey: true })
  press(document.body, "k")
  expect(state().queue).toHaveLength(0)

  press(document.body, "k", { ctrlKey: true })
  expect(state().queue).toHaveLength(1)
})

test("outside: triggers are not recorded; a window binding beside one still is", async () => {
  await mount(`
    <div>
      <div id="a" data-controller="reactive"><span data-action="click@window->reactive#dispatch" data-reactive-window-param="true" data-reactive-outside-param="true"></span></div>
      <div id="b" data-controller="reactive" data-action="click@window->reactive#runOps" data-reactive-ops-param='{"on":"click","window":true,"outside":true,"ops":[]}'></div>
      <div id="c" data-controller="reactive" data-action="click@window->reactive#runOps" data-reactive-ops-param='{"on":"click","window":true,"outside":true,"ops":[]} {"on":"click","window":true,"ops":[]}'></div>
    </div>`)
  click(document.body)

  expect(state().queue.map((entry) => entry.root.id)).toEqual(["c"])
})

test("an element bound to click AND click@window records one entry per listener", async () => {
  const root = await mount(`<div id="p" data-controller="reactive"><button data-action="click->reactive#dispatch click@window->reactive#dispatch">Go</button></div>`)
  click(root.querySelector("button"))

  expect(state().queue.map((entry) => Boolean(entry.win)).sort()).toEqual([false, true])
})

test("a window-bound hotkey wakes a dormant root once, however often it is pressed", async () => {
  const root = await mount(`<div id="p" data-controller="menu" data-reactive-dormant="reactive"><span data-action="keydown.k@window->reactive#dispatch"></span></div>`)
  press(document.body, "k")
  press(document.body, "k")
  press(document.body, "k")

  expect(root.dataset.controller).toBe("menu reactive")
  expect(root.hasAttribute("data-reactive-dormant")).toBe(false)
  expect(state().queue).toHaveLength(3)
})

test("a window-bound trigger that left the page is not recorded", async () => {
  const root = await mount(HOTKEY)
  root.querySelector("#h").remove()
  press(document.body, "k")

  expect(state().queue).toHaveLength(0)
})

test("picks up window-bound triggers added after start", async () => {
  await mount(`<div id="p" data-controller="reactive"></div>`)
  document.querySelector("#p").innerHTML = `<span data-action="keydown.esc@window->reactive#dispatch"></span>`
  await window.happyDOM.waitUntilComplete()
  await flush()
  press(document.body, "Escape")

  expect(state().queue).toHaveLength(1)
})

test("connect() replays a window-bound entry as the window listener would see it", async () => {
  const root = await mount(HOTKEY)
  press(document.body, "k")
  const { calls } = connect(root)

  expect(calls).toHaveLength(1)
  const replay = calls[0].event
  expect(calls[0].method).toBe("dispatch")
  expect(replay.currentTarget).toBe(window)
  expect(replay.key).toBe("k")
  expect(replay.params).toEqual({ action: "toggle", window: true })
})

test("connect() replays both entries of an element bound to click AND click@window", async () => {
  const root = await mount(`<div id="p" data-controller="reactive"><button data-action="click->reactive#dispatch click@window->reactive#dispatch">Go</button></div>`)
  const button = root.querySelector("button")
  click(button)
  const { calls } = connect(root)

  const targets = calls.map((call) => call.event.currentTarget)
  expect(targets).toHaveLength(2)
  expect(targets).toContain(button)
  expect(targets).toContain(window)
})

test("a hotkey replayed while its original still propagates is not run again by the window listener", async () => {
  const root = await mount(HOTKEY)
  const seen = countDispatches(root)
  let controller
  // The waking keypress connects the controller mid-propagation (an eagerly
  // registered controller), then reaches Stimulus's freshly bound window
  // listener — bubble phase on window, after everything else.
  document.addEventListener("keydown", () => (controller ??= realConnect(root)))
  window.addEventListener("keydown", (event) => {
    event.params = { action: "toggle", window: true }
    controller.dispatch(event)
  })
  press(document.body, "k")

  expect(seen).toEqual(["toggle"])
})

test("a spent :once hotkey swallows the still-armed window listener's firing; an element-bound call is not that binding", async () => {
  const root = await mount(HOTKEY.replace("#dispatch", "#dispatch:once"))
  const seen = countDispatches(root)
  press(document.body, "k")
  press(document.body, "k")
  const controller = realConnect(root)
  expect(seen).toEqual(["toggle"])

  controller.dispatch(liveWindowEvent("k"))
  expect(seen).toEqual(["toggle"])
  controller.dispatch({ ...liveEvent(root, "keydown"), key: "k", params: { action: "toggle" } })
  expect(seen).toEqual(["toggle", "toggle"])
})

test("a window-bound entry older than 1.5 s is dropped (warned under verbose); an element-bound one of that age is kept", async () => {
  const root = await mount(`<div id="p" data-controller="reactive" data-reactive-verbose="true"><button data-action="click->reactive#dispatch keydown.k@window->reactive#dispatch">Go</button></div>`)
  click(root.querySelector("button"))
  press(document.body, "k")
  advanceClock(1_600)
  const { calls } = connect(root)

  expect(calls.map((call) => call.event.type)).toEqual(["click"])
  expect(warns.join("\n")).toContain("1500 ms window-trigger TTL")
})

test("a window-bound entry younger than 1.5 s is replayed", async () => {
  const root = await mount(HOTKEY)
  press(document.body, "k")
  advanceClock(1_400)
  const { calls } = connect(root)

  expect(calls).toHaveLength(1)
})

test("a shorter configured TTL also shortens the window-bound one", async () => {
  document.head.innerHTML = `<meta name="phlex-reactive-early-ttl" content="500">`
  const root = await mount(HOTKEY)
  press(document.body, "k")
  advanceClock(600)
  const { calls } = connect(root)

  expect(calls).toHaveLength(0)
})

test("a replayed window-bound on_client entry never runs an outside: record", async () => {
  const root = await mount(`<div id="p" data-controller="reactive" data-action="click@window->reactive#runOps" data-reactive-ops-param='{"on":"click","window":true,"outside":true,"ops":[["add_class",{"to":"@root","classes":["outside"]}]]} {"on":"click","window":true,"ops":[["add_class",{"to":"@root","classes":["hotkey"]}]]}'></div>`)
  click(document.body)
  expect(state().queue).toHaveLength(1)
  realConnect(root)
  await flush()

  expect(root.classList.contains("hotkey")).toBe(true)
  expect(root.classList.contains("outside")).toBe(false)
})

test("a dotted custom event name is an event name, not a key filter", async () => {
  const root = await mount(`<div id="p" data-controller="reactive" data-action="panel.opened->reactive#dispatch"></div>`)
  root.dispatchEvent(new window.CustomEvent("panel.opened"))

  expect(state().queue).toHaveLength(1)
})

test("checked: :keep on anything but a checkbox/radio is still prevented, like dispatch()", async () => {
  const root = await mount(`
    <form id="c" data-controller="reactive">
      <button data-action="click->reactive#dispatch" data-reactive-optimistic-param='{"checked":"keep"}'>Save</button>
    </form>`)
  const event = click(root.querySelector("button"))

  expect(event.defaultPrevented).toBe(true)
})

test("a key filter's modifiers must match: plain Enter is neither queued nor prevented for ctrl+enter", async () => {
  const root = await mount(`<div id="k" data-controller="reactive"><input data-action="keydown.ctrl+enter->reactive#dispatch"></div>`)
  const input = root.querySelector("input")
  const plain = new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true })
  input.dispatchEvent(plain)
  const withCtrl = new window.KeyboardEvent("keydown", { key: "Enter", ctrlKey: true, bubbles: true, cancelable: true })
  input.dispatchEvent(withCtrl)

  expect(plain.defaultPrevented).toBe(false)
  expect(withCtrl.defaultPrevented).toBe(true)
  expect(state().queue).toHaveLength(1)
})

test("honours a key filter: only the matching key is recorded and prevented", async () => {
  const root = await mount(`<div id="k" data-controller="reactive"><input data-action="keydown.enter->reactive#dispatch"></div>`)
  const input = root.querySelector("input")
  const typed = new window.KeyboardEvent("keydown", { key: "a", bubbles: true, cancelable: true })
  input.dispatchEvent(typed)
  const enter = new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true })
  input.dispatchEvent(enter)

  expect(typed.defaultPrevented).toBe(false)
  expect(enter.defaultPrevented).toBe(true)
  expect(state().queue).toHaveLength(1)
  expect(state().queue[0].event).toBe(enter)
})

test("a non-bubbling event only counts on its own target", async () => {
  const root = await mount(`<div id="f" data-controller="reactive" data-action="focus->reactive#dispatch"><input></div>`)
  root.querySelector("input").dispatchEvent(new window.FocusEvent("focus"))

  expect(state().queue).toHaveLength(0)
})

test("listens for trigger types of roots added after start (MutationObserver)", async () => {
  await mount(`<div id="first"></div>`)
  const root = document.createElement("div")
  root.id = "late"
  root.setAttribute("data-controller", "reactive")
  root.setAttribute("data-action", "late:event->reactive#dispatch")
  document.body.appendChild(root)
  await window.happyDOM.waitUntilComplete()
  await flush()
  root.dispatchEvent(new window.CustomEvent("late:event"))

  expect(state().queue).toHaveLength(1)
})

// The one module every page loads eagerly. 1,024 B before dormant roots (issue
// #274) added the second root selector and the wake.
test("early.min.js gzips to under 1,300 bytes", () => {
  const built = readFileSync(join(import.meta.dir, "../../app/javascript/phlex/reactive/early.min.js"))
  expect(gzipSync(built, { level: 9 }).length).toBeLessThan(1300)
})

// --- reactive_controller.js: connect() marks, announces and drains ------------

test("connect() marks the root, joins the connected set and emits a bubbling reactive:connect", async () => {
  const root = await mount(`<div id="p" data-controller="reactive"></div>`)
  const heard = []
  document.addEventListener("reactive:connect", (event) => heard.push(event))
  connect(root)

  expect(root.hasAttribute("data-reactive-connected")).toBe(true)
  expect(state().connected.has(root)).toBe(true)
  expect(heard).toHaveLength(1)
  expect(heard[0].target).toBe(root)
  expect(heard[0].bubbles).toBe(true)
})

test("connect() replays its own root's entries through dispatch with the trigger's params", async () => {
  const root = await mount(`
    <div>
      <div id="mine" data-controller="reactive">
        <button data-action="click->reactive#dispatch" data-reactive-action-param="load" data-reactive-params-param='{"page":2}'>Go</button>
      </div>
      <div id="other" data-controller="reactive"><button data-action="click->reactive#dispatch">Other</button></div>
    </div>`)
  const mine = root.querySelector("#mine")
  const button = mine.querySelector("button")
  click(button)
  click(root.querySelector("#other button"))

  const { calls } = connect(mine)

  expect(calls).toHaveLength(1)
  const replay = calls[0].event
  expect(calls[0].method).toBe("dispatch")
  expect(replay.type).toBe("click")
  expect(replay.currentTarget).toBe(button)
  expect(replay.params).toEqual({ action: "load", params: { page: 2 } })
  expect(replay[KEY]).toBe(true)
  // The other root's entry waits for ITS controller.
  expect(state().queue).toHaveLength(1)
  expect(state().queue[0].root).toBe(root.querySelector("#other"))
})

test("connect() replays an on_client trigger through runOps, carrying the custom event detail", async () => {
  const root = await mount(`<div id="p" data-controller="reactive" data-action="menu:open->reactive#runOps"></div>`)
  root.dispatchEvent(new window.CustomEvent("menu:open", { detail: { n: 1 } }))
  const { calls } = connect(root)

  expect(calls.map((call) => call.method)).toEqual(["runOps"])
  expect(calls[0].event.detail).toEqual({ n: 1 })
})

test("a :once trigger fired three times replays once, leaving the markup alone", async () => {
  const root = await mount(`<div id="p" data-controller="reactive"><button data-action="click->reactive#dispatch:once mouseover->reactive#dispatch">Go</button></div>`)
  const button = root.querySelector("button")
  click(button)
  click(button)
  click(button)
  const { calls } = connect(root)

  expect(calls).toHaveLength(1)
  // Untouched: a morph writing the same data-action back re-arms nothing.
  expect(button.getAttribute("data-action")).toBe("click->reactive#dispatch:once mouseover->reactive#dispatch")
})

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

function realConnect(root) {
  const controller = new ReactiveController()
  controller.element = root
  controller.connect()
  return controller
}

const liveEvent = (el, type) => ({ type, target: el, currentTarget: el, params: { action: "load" }, preventDefault() {} })

// Stimulus's window listener: currentTarget is the window, params come from
// the element carrying the descriptor.
const liveWindowEvent = (key) => ({
  type: "keydown",
  key,
  target: document.body,
  currentTarget: window,
  params: { action: "toggle", window: true },
  preventDefault() {},
})

test("after a :once replay, the still-armed Stimulus listener's one firing is swallowed", async () => {
  const root = await mount(`<div id="p" data-controller="reactive"><button data-action="click->reactive#dispatch:once" data-reactive-action-param="load">Go</button></div>`)
  const button = root.querySelector("button")
  const seen = countDispatches(root)
  click(button)
  click(button)
  const controller = realConnect(root)
  expect(seen).toEqual(["load"])

  controller.dispatch(liveEvent(button, "click"))
  expect(seen).toEqual(["load"])
})

test("a sibling descriptor with another key filter is not swallowed by a spent :once", async () => {
  const root = await mount(`<div id="p" data-controller="reactive"><input data-action="keydown.enter->reactive#dispatch:once keydown.esc->reactive#dispatch" data-reactive-action-param="load"></div>`)
  const input = root.querySelector("input")
  const seen = countDispatches(root)
  input.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }))
  const controller = realConnect(root)
  expect(seen).toEqual(["load"])

  // Escape comes from the OTHER descriptor: it must run.
  controller.dispatch({ ...liveEvent(input, "keydown"), key: "Escape" })
  expect(seen).toEqual(["load", "load"])
  // Enter comes from the spent one: swallowed.
  controller.dispatch({ ...liveEvent(input, "keydown"), key: "Enter" })
  expect(seen).toEqual(["load", "load"])
})

test("a regular sibling descriptor of the same type still fires after a :once replay", async () => {
  const root = await mount(`<div id="p" data-controller="reactive"><button data-action="click->reactive#dispatch:once click->reactive#dispatch" data-reactive-action-param="load">Go</button></div>`)
  const button = root.querySelector("button")
  const seen = countDispatches(root)
  click(button)
  const controller = realConnect(root)
  expect(seen).toEqual(["load", "load"])

  // The next live click reaches dispatch twice (once binding + regular one):
  // the spent once call is swallowed, the regular one runs.
  const event = liveEvent(button, "click")
  controller.dispatch(event)
  controller.dispatch(event)
  expect(seen).toEqual(["load", "load", "load"])
})

test("entries of a root that left the page are purged by the next connect, warned under verbose", async () => {
  const wrapper = await mount(`
    <div>
      <div id="gone" data-controller="reactive"><button data-action="click->reactive#dispatch">Go</button></div>
      <div id="here" data-controller="reactive" data-reactive-verbose="true"></div>
    </div>`)
  const gone = wrapper.querySelector("#gone")
  click(gone.querySelector("button"))
  gone.remove()
  connect(wrapper.querySelector("#here"))

  expect(state().queue).toHaveLength(0)
  expect(warns.join("\n")).toContain("left the page")
})

test("an entry whose element left the root warns under verbose", async () => {
  const root = await mount(`<div id="p" data-controller="reactive" data-reactive-verbose="true"><button data-action="click->reactive#dispatch">Go</button></div>`)
  const button = root.querySelector("button")
  click(button)
  button.remove()
  const { calls } = connect(root)

  expect(calls).toHaveLength(0)
  expect(warns.join("\n")).toContain("left the root")
})

test("the replay re-checks a key filter against the app's own key mappings", async () => {
  const root = await mount(`<div id="k" data-controller="reactive"><input data-action="keydown.enter->reactive#dispatch"></div>`)
  root.querySelector("input").dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }))
  const controller = new ReactiveController()
  controller.element = root
  // An app schema that remapped `enter` to another key: Stimulus would not fire.
  controller.application = { schema: { keyMappings: { enter: "F13" } } }
  const calls = []
  controller.dispatch = (event) => calls.push(event)
  controller.connect()

  expect(calls).toHaveLength(0)
})

test("the root stops being recorded from the START of connect() (connect-time seeds dispatch real events)", async () => {
  const root = await mount(`<div data-controller="reactive"></div>`)
  let joinedBeforeSetup = null
  // connect() reads the root's id first thing (the root-id guard).
  Object.defineProperty(root, "id", {
    get() {
      joinedBeforeSetup ??= state().connected.has(root)
      return "p"
    },
  })
  connect(root)

  expect(joinedBeforeSetup).toBe(true)
})

test("connect() drops entries older than the TTL, warning under verbose", async () => {
  document.head.innerHTML = `<meta name="phlex-reactive-early-ttl" content="50">`
  const root = await mount(`<div id="p" data-controller="reactive" data-reactive-verbose="true"><button data-action="click->reactive#dispatch">Go</button></div>`)
  click(root.querySelector("button"))
  advanceClock(51)
  const { calls } = connect(root)

  expect(calls).toHaveLength(0)
  expect(state().queue).toHaveLength(0)
  expect(warns.join("\n")).toContain("TTL")
})

test("connect() drops entries whose element left the root, silently without verbose", async () => {
  const root = await mount(`<div id="p" data-controller="reactive"><button data-action="click->reactive#dispatch">Go</button></div>`)
  const button = root.querySelector("button")
  click(button)
  button.remove()
  const { calls } = connect(root)

  expect(calls).toHaveLength(0)
  expect(state().queue).toHaveLength(0)
  expect(warns).toHaveLength(0)
})

test("an entry's age counts from CAPTURE, not from when its event object was created", async () => {
  document.head.innerHTML = `<meta name="phlex-reactive-early-ttl" content="50">`
  const root = await mount(`<div id="p" data-controller="reactive" data-action="panel:opened->reactive#dispatch"></div>`)
  // An app may build an event once and dispatch it much later.
  const reused = new window.CustomEvent("panel:opened")
  Object.defineProperty(reused, "timeStamp", { value: performance.now() - 60_000 })
  root.dispatchEvent(reused)
  const { calls } = connect(root)

  expect(calls).toHaveLength(1)
})

test("two instances of early.js (a bundled copy beside the pinned one) still replay an event once", async () => {
  const { startEarly: startSecond } = await import("../../app/javascript/phlex/reactive/early.js?second-instance")
  expect(startSecond).not.toBe(startEarly)
  startSecond(document)
  const root = await mount(`<div id="p" data-controller="reactive"><button data-action="click->reactive#dispatch">Go</button></div>`)
  click(root.querySelector("button"))
  expect(state().queue).toHaveLength(2)
  const { calls } = connect(root)

  expect(calls).toHaveLength(1)
  expect(state().queue).toHaveLength(0)
})

test("the default TTL is 10 seconds", async () => {
  const root = await mount(`<div id="p" data-controller="reactive"><button data-action="click->reactive#dispatch">Go</button></div>`)
  click(root.querySelector("button"))
  advanceClock(9_000)
  const { calls } = connect(root)

  expect(calls).toHaveLength(1)
})

test("disconnect() clears the marker and the connected membership", async () => {
  const root = await mount(`<div id="p" data-controller="reactive"></div>`)
  const { controller } = connect(root)
  controller.disconnect()

  expect(root.hasAttribute("data-reactive-connected")).toBe(false)
  expect(state().connected.has(root)).toBe(false)
})
