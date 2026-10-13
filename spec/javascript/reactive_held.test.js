// Issue #370: tell the action when a morph held a focused field over a changed
// server value. Since #338 a morph keeps the value of the field being typed in
// and writes the render's value as the field's DEFAULT. When that render
// differs from the old default, someone else changed the field under the
// user: the runtime marks it data-reactive-held, dispatches a bubbling
// `reactive:held` { name, theirs }, and the root's next action request sends
// the held names as X-Reactive-Held. The root's own reply never marks, and
// once it has been applied the root holds nothing.
//
// `morph()` replays Turbo 8 + Idiomorph on ONE element, as in
// reactive_morph_focus.test.js.
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll, beforeEach, afterEach } from "bun:test"
import { Window } from "happy-dom"

const window = new Window({ url: "http://localhost/" })
let ReactiveController
const SAVED = {}
const GLOBALS = ["document", "window", "Event", "CustomEvent", "MutationObserver", "fetch", "location"]

beforeAll(async () => {
  mock.module("@hotwired/stimulus", () => ({ Controller: class {} }))
  const runtime = await import("../../app/javascript/phlex/reactive/reactive_controller.js")
  ReactiveController = runtime.default
  // Turbo is not on the page when the module loads: register the document
  // listeners on this window's document once, as turbo:load would.
  const saved = globalThis.document
  globalThis.document = window.document
  runtime.__resetReactiveMorphFocusForTest()
  runtime.registerReactiveMorphFocus()
  runtime.__resetReactiveStreamRenderForTest()
  runtime.registerReactiveStreamRender()
  globalThis.document = saved
})

let requests
let controllers
let reply

beforeEach(() => {
  for (const key of GLOBALS) SAVED[key] = globalThis[key]
  globalThis.document = window.document
  globalThis.window = window
  globalThis.Event = window.Event
  globalThis.CustomEvent = window.CustomEvent
  globalThis.MutationObserver = window.MutationObserver
  globalThis.location = window.location
  // What the reply's stream does to the page, run as Turbo would: the stream
  // render is announced synchronously inside renderStreamMessage, applied after
  // a repaint.
  reply = null
  window.Turbo = {
    renderStreamMessage: () => {
      if (!reply) return
      const stream = document.createElement("turbo-stream")
      stream.setAttribute("action", "replace")
      stream.setAttribute("target", "r")
      const apply = reply
      const event = new window.CustomEvent("turbo:before-stream-render", {
        bubbles: true,
        cancelable: true,
        detail: { newStream: stream, render: async () => apply() },
      })
      document.dispatchEvent(event)
      if (!event.defaultPrevented) setTimeout(() => event.detail.render(stream), 0)
    },
  }
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

afterEach(() => {
  for (const controller of controllers) controller.disconnect?.()
  for (const [key, value] of Object.entries(SAVED)) globalThis[key] = value
})

const flush = async () => {
  for (let i = 0; i < 5; i++) await new Promise((resolve) => setTimeout(resolve, 0))
}

function connect(root) {
  const controller = new ReactiveController()
  controller.element = root
  controller.tokenValue = root.getAttribute("data-reactive-token-value") ?? ""
  controller.connect()
  controllers.push(controller)
  return controller
}

function mount(inner) {
  document.body.innerHTML = `<div id="r" data-controller="reactive" data-reactive-token-value="tok">${inner}</div>`
  return connect(document.getElementById("r"))
}

function dispatchEvent(name, target, detail) {
  const event = new window.CustomEvent(name, { bubbles: true, cancelable: true, detail })
  target.dispatchEvent(event)
  return !event.defaultPrevented
}

// Idiomorph's morphNode for an input/textarea/editable, as Turbo drives it.
function morph(oldEl, html) {
  const holder = document.createElement("div")
  holder.innerHTML = html
  const newEl = holder.firstElementChild
  if (!dispatchEvent("turbo:before-morph-element", oldEl, { currentElement: oldEl, newElement: newEl })) return
  for (const attr of [...newEl.attributes]) {
    if (!dispatchEvent("turbo:before-morph-attribute", oldEl, { attributeName: attr.name, mutationType: "update" })) continue
    if (oldEl.getAttribute(attr.name) !== attr.value) oldEl.setAttribute(attr.name, attr.value)
  }
  for (const attr of [...oldEl.attributes]) {
    if (newEl.hasAttribute(attr.name)) continue
    if (!dispatchEvent("turbo:before-morph-attribute", oldEl, { attributeName: attr.name, mutationType: "remove" })) continue
    oldEl.removeAttribute(attr.name)
  }
  const allowed = (name) => dispatchEvent("turbo:before-morph-attribute", oldEl, { attributeName: name, mutationType: "update" })
  if (oldEl.localName === "input") {
    if (oldEl.value !== newEl.value && allowed("value")) {
      oldEl.setAttribute("value", newEl.value)
      oldEl.value = newEl.value
    }
  } else if (oldEl.localName === "textarea") {
    if (allowed("value") && oldEl.value !== newEl.value) oldEl.value = newEl.value
    if (oldEl.firstChild && oldEl.firstChild.nodeValue !== newEl.textContent) oldEl.firstChild.nodeValue = newEl.textContent
  } else if (oldEl.textContent !== newEl.textContent) {
    oldEl.textContent = newEl.textContent
  }
}

function type(field, text) {
  field.focus()
  if (field.hasAttribute("data-reactive-editable")) field.textContent = text
  else field.value = text
}

function heldEvents() {
  const events = []
  document.addEventListener("reactive:held", (event) => events.push(event.detail))
  return events
}

const act = (controller) => controller.dispatch({ params: { action: "save" }, preventDefault() {} })

test("a focused input held over a changed render is marked and reported with the server's value", () => {
  mount(`<input name="title" value="Original">`)
  const events = heldEvents()
  const field = document.querySelector("input")
  type(field, "Draft by B")

  morph(field, `<input name="title" value="Final by A">`)

  expect(field.value).toBe("Draft by B")
  expect(field.defaultValue).toBe("Final by A")
  expect(field.hasAttribute("data-reactive-held")).toBe(true)
  expect(events).toEqual([{ name: "title", theirs: "Final by A" }])
})

test("a render equal to the field's default marks nothing", () => {
  mount(`<input name="title" value="Original">`)
  const events = heldEvents()
  const field = document.querySelector("input")
  type(field, "Draft by B")

  morph(field, `<input name="title" value="Original">`)

  expect(field.hasAttribute("data-reactive-held")).toBe(false)
  expect(events).toEqual([])
})

test("an unfocused field is never marked", () => {
  mount(`<input name="title" value="Original"><input name="body" value="old">`)
  const events = heldEvents()
  const [title, body] = document.querySelectorAll("input")
  type(title, "Draft by B")

  morph(body, `<input name="body" value="new">`)

  expect(body.hasAttribute("data-reactive-held")).toBe(false)
  expect(events).toEqual([])
})

test("a focused textarea held over a changed render is marked", () => {
  mount(`<textarea name="body">Original</textarea>`)
  const events = heldEvents()
  const field = document.querySelector("textarea")
  type(field, "Mine")

  morph(field, `<textarea name="body">Theirs</textarea>`)

  expect(field.value).toBe("Mine")
  expect(field.hasAttribute("data-reactive-held")).toBe(true)
  expect(events).toEqual([{ name: "body", theirs: "Theirs" }])
})

test("a focused reactive_editable held over a changed render is marked", () => {
  mount(`<h3 name="title" data-reactive-editable="single" contenteditable="true" tabindex="0">Original</h3>`)
  const events = heldEvents()
  const field = document.querySelector("h3")
  type(field, "Mine")

  morph(field, `<h3 name="title" data-reactive-editable="single" contenteditable="true" tabindex="0">Theirs</h3>`)

  expect(field.textContent).toBe("Mine")
  expect(field.hasAttribute("data-reactive-held")).toBe(true)
  expect(events).toEqual([{ name: "title", theirs: "Theirs" }])
})

test("the mark survives a later morph while the field is still focused", () => {
  mount(`<input name="title" value="Original">`)
  const field = document.querySelector("input")
  type(field, "Draft by B")
  morph(field, `<input name="title" value="Final by A">`)

  morph(field, `<input name="title" value="Final by A">`)

  expect(field.hasAttribute("data-reactive-held")).toBe(true)
})

test("setting the value back to its default clears the mark (the user took theirs)", () => {
  mount(`<input name="title" value="Original">`)
  const field = document.querySelector("input")
  type(field, "Draft by B")
  morph(field, `<input name="title" value="Final by A">`)

  field.value = "Final by A"
  field.dispatchEvent(new window.Event("input", { bubbles: true }))

  expect(field.hasAttribute("data-reactive-held")).toBe(false)
})

test("the next action sends X-Reactive-Held; a request with nothing held sends no such header", async () => {
  const controller = mount(`<input name="title" value="Original"><input name="body" value="b">`)
  act(controller)
  await flush()
  expect("X-Reactive-Held" in requests[0].headers).toBe(false)

  const field = document.querySelector("input")
  type(field, "Draft by B")
  morph(field, `<input name="title" value="Final by A">`)
  act(controller)
  await flush()

  expect(requests[1].headers["X-Reactive-Held"]).toBe('["title"]')
})

test("after its own reply is applied the root holds nothing, and the reply itself marks nothing", async () => {
  const controller = mount(`<input name="title" value="Original">`)
  const field = document.querySelector("input")
  type(field, "Draft by B")
  morph(field, `<input name="title" value="Final by A">`)
  // The reply renders what the server saved, different from the default.
  reply = () => morph(field, `<input name="title" value="Draft by B saved">`)
  const events = heldEvents()

  act(controller)
  await flush()

  expect(requests[0].headers["X-Reactive-Held"]).toBe('["title"]')
  expect(events).toEqual([])
  expect(field.hasAttribute("data-reactive-held")).toBe(false)

  reply = null
  act(controller)
  await flush()
  expect("X-Reactive-Held" in requests[1].headers).toBe(false)
})

test("a held field inside a nested root belongs to that root, not the outer one", async () => {
  document.body.innerHTML = `<div id="outer" data-controller="reactive" data-reactive-token-value="o">
      <div id="inner" data-controller="reactive" data-reactive-token-value="i"><input name="title" value="a"></div>
    </div>`
  const outer = connect(document.getElementById("outer"))
  const field = document.querySelector("input")
  type(field, "mine")
  morph(field, `<input name="title" value="theirs">`)

  act(outer)
  await flush()

  expect("X-Reactive-Held" in requests[0].headers).toBe(false)
})

test("a non-ASCII field name is escaped so the header stays a valid byte string", async () => {
  const controller = mount(`<input name="titel_ä" value="a">`)
  const field = document.querySelector("input")
  type(field, "mine")
  morph(field, `<input name="titel_ä" value="theirs">`)

  act(controller)
  await flush()

  const header = requests[0].headers["X-Reactive-Held"]
  expect(/^[\x20-\x7e]*$/.test(header)).toBe(true)
  expect(JSON.parse(header)).toEqual(["titel_ä"])
})
