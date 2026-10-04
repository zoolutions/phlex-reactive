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
})

const state = () => globalThis[KEY]
const flush = () => new Promise((resolve) => setTimeout(resolve, 0))

// Mount markup and let the MutationObserver register its trigger event types.
async function mount(html) {
  document.body.innerHTML = html
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

test("does not record @window bindings, foreign controllers, or replayed events", async () => {
  const root = await mount(`
    <div id="p" data-controller="reactive">
      <button id="w" data-action="click@window->reactive#dispatch">W</button>
      <button id="o" data-action="click->other#go">O</button>
      <button id="r" data-action="click->reactive#dispatch">R</button>
    </div>`)
  click(root.querySelector("#w"))
  click(root.querySelector("#o"))
  const replay = new window.MouseEvent("click", { bubbles: true, cancelable: true })
  replay[KEY] = true
  root.querySelector("#r").dispatchEvent(replay)

  expect(state().queue).toHaveLength(0)
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
  await flush()
  root.dispatchEvent(new window.CustomEvent("late:event"))

  expect(state().queue).toHaveLength(1)
})

test("early.min.js gzips to under 1 KB", () => {
  const built = readFileSync(join(import.meta.dir, "../../app/javascript/phlex/reactive/early.min.js"))
  expect(gzipSync(built, { level: 9 }).length).toBeLessThan(1024)
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

test("a :once trigger replays once and its descriptor is consumed", async () => {
  const root = await mount(`<div id="p" data-controller="reactive"><button data-action="click->reactive#dispatch:once mouseover->reactive#dispatch">Go</button></div>`)
  const button = root.querySelector("button")
  click(button)
  click(button)
  click(button)
  const { calls } = connect(root)

  expect(calls).toHaveLength(1)
  expect(button.getAttribute("data-action")).toBe("mouseover->reactive#dispatch")
})

test("the replay re-checks a key filter in full (modifiers included)", async () => {
  const root = await mount(`<div id="k" data-controller="reactive"><input data-action="keydown.ctrl+enter->reactive#dispatch"></div>`)
  const input = root.querySelector("input")
  input.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }))
  input.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", ctrlKey: true, bubbles: true, cancelable: true }))
  const { calls } = connect(root)

  expect(calls).toHaveLength(1)
  expect(calls[0].event.ctrlKey).toBe(true)
})

test("connect() drops entries older than the TTL, warning under verbose", async () => {
  document.head.innerHTML = `<meta name="phlex-reactive-early-ttl" content="50">`
  const root = await mount(`<div id="p" data-controller="reactive" data-reactive-verbose="true"><button data-action="click->reactive#dispatch">Go</button></div>`)
  click(root.querySelector("button"))
  state().queue[0].at -= 51
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

test("the default TTL is 10 seconds", async () => {
  const root = await mount(`<div id="p" data-controller="reactive"><button data-action="click->reactive#dispatch">Go</button></div>`)
  click(root.querySelector("button"))
  state().queue[0].at -= 9_000
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
