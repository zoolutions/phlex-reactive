// Unit tests for issue #356: a stream that renders into a reactive root that
// is already connected (append, prepend, update, before, after, replace of a
// child) makes the root re-read its feature markers, as a morph of the root
// itself does, and re-run the seeds of the features already connected — so a
// marker the stream brought is wired, and a binding wired before it covers
// the new content too.
//
// happy-dom, the default entry (and, under the default define, the split
// runtime with every feature handed over). The stream is the shape Turbo
// dispatches: turbo:before-stream-render on the document with
// { newStream, render }, then `await detail.render(stream)`.
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll, beforeEach, afterEach, afterAll } from "bun:test"
import { Window } from "happy-dom"

let mod
let ReactiveController
const window = new Window()
const SAVED = {}

beforeAll(async () => {
  mock.module("@hotwired/stimulus", () => ({ Controller: class {} }))
  globalThis.document = window.document
  mod = await import("../../app/javascript/phlex/reactive/reactive_controller.js")
  ReactiveController = mod.default
  // One stream-render listener on THIS file's document.
  mod.__resetReactiveStreamRenderForTest()
  mod.registerReactiveStreamRender()
})

afterAll(() => mod.__resetReactiveStreamRenderForTest())

beforeEach(() => {
  for (const key of ["document", "window", "Event", "CustomEvent", "navigator"]) SAVED[key] = globalThis[key]
  globalThis.document = window.document
  globalThis.window = window
  globalThis.Event = window.Event
  globalThis.CustomEvent = window.CustomEvent
  document.body.innerHTML = ""
})

afterEach(() => {
  for (const [key, value] of Object.entries(SAVED)) {
    if (value === undefined) delete globalThis[key]
    else globalThis[key] = value
  }
})

const SHOW_B = `data-reactive-show-field="mode" data-reactive-show-equals="b"`
const EDITABLE = `<h3 name="title" contenteditable="plaintext-only" data-reactive-editable="single">Hi</h3>`

function mount(html, { id = "r", attrs = 'data-reactive-token-value="t"' } = {}) {
  document.body.insertAdjacentHTML("beforeend", `<div id="${id}" data-controller="reactive" ${attrs}>${html}</div>`)
  const root = document.getElementById(id)
  const controller = new ReactiveController()
  controller.element = root
  controller.connect()
  return { root, controller }
}

// What Turbo does for one <turbo-stream>: the event, then the (maybe wrapped)
// render. `apply` is Turbo's own DOM write for the action.
async function stream(action, target, html, apply) {
  const el = document.createElement("turbo-stream")
  el.setAttribute("action", action)
  el.setAttribute("target", target)
  const template = document.createElement("template")
  template.innerHTML = html
  el.appendChild(template)
  const detail = { newStream: el, render: async () => apply(document.getElementById(target), html) }
  document.dispatchEvent(new window.CustomEvent("turbo:before-stream-render", { detail }))
  await detail.render(el)
  return detail
}

const append = (action, target, html) => stream(action, target, html, (t) => t.insertAdjacentHTML("beforeend", html))

function edit(input, value) {
  input.value = value
  input.dispatchEvent(new window.Event("input", { bubbles: true }))
}

test("a show target a stream appends into a root without bindings is seeded and follows its field", async () => {
  const { root } = mount(`<input name="mode" value="a"><div id="slot"></div>`)
  await append("append", "slot", `<p ${SHOW_B}>b only</p>`)

  const p = root.querySelector("p")
  expect(p.hidden).toBe(true)
  edit(root.querySelector("input"), "b")
  expect(p.hidden).toBe(false)
})

test("a root whose bindings connected for another marker wires a show binding a stream brings", async () => {
  const { root } = mount(`<input name="mode" value="a">${EDITABLE}<div id="slot"></div>`)
  await append("append", "slot", `<p ${SHOW_B}>b only</p>`)

  const p = root.querySelector("p")
  expect(p.hidden).toBe(true)
  edit(root.querySelector("input"), "b")
  expect(p.hidden).toBe(false)
})

test("a show binding already wired covers a target a stream appends, from the field's current value", async () => {
  const { root } = mount(`<input name="mode" value="a"><p id="first" ${SHOW_B}>1</p><div id="slot"></div>`)
  edit(root.querySelector("input"), "b")
  await append("append", "slot", `<p id="second" hidden ${SHOW_B}>2</p>`)

  expect(root.querySelector("#second").hidden).toBe(false)
})

test("an update of the root itself wires what its new children need", async () => {
  const { root } = mount(`<p>empty</p>`)
  await stream("update", "r", `<input name="mode" value="a"><p ${SHOW_B}>b only</p>`, (t, html) => {
    t.innerHTML = html
  })

  expect(root.querySelector("p").hidden).toBe(true)
  edit(root.querySelector("input"), "b")
  expect(root.querySelector("p").hidden).toBe(false)
})

test("content a stream puts after a child belongs to that child's root", async () => {
  const { root } = mount(`<input name="mode" value="a"><span id="anchor"></span>`)
  await stream("after", "anchor", `<p ${SHOW_B}>b only</p>`, (t, html) => t.insertAdjacentHTML("afterend", html))

  expect(root.querySelector("p").hidden).toBe(true)
})

test("a stream into a nested root wires the nested root, not its parent", async () => {
  const { root: outer, controller: parent } = mount(`<div id="inner-slot"></div>`, { id: "outer" })
  const inner = document.createElement("div")
  inner.id = "inner"
  inner.setAttribute("data-controller", "reactive")
  inner.setAttribute("data-reactive-token-value", "t")
  inner.innerHTML = `<input name="mode" value="a"><div id="slot"></div>`
  outer.appendChild(inner)
  const child = new ReactiveController()
  child.element = inner
  child.connect()

  await append("append", "slot", `<p ${SHOW_B}>b only</p>`)

  expect(inner.querySelector("p").hidden).toBe(true)
  parent.disconnect()
  child.disconnect()
})

test("a replace of a root re-reads nothing on the element it detached", async () => {
  const { root, controller } = mount(`<p>old</p>`)
  const errors = []
  const realError = console.error
  console.error = (...args) => errors.push(args)
  try {
    await stream("replace", "r", `<div id="r"><p ${SHOW_B}>x</p></div>`, (t, html) => {
      controller.disconnect() // what Stimulus does as the element leaves
      t.outerHTML = html
    })
  } finally {
    console.error = realError
  }
  expect(errors).toEqual([])
  expect(root.isConnected).toBe(false)
  expect(root.querySelector("p").hidden).toBe(false) // the detached old root was not wired
})

test("a paste trigger a stream brings into a dirty-tracking root is gated like one rendered at connect", async () => {
  globalThis.navigator = { clipboard: { readText: () => Promise.resolve("") } }
  const { root } = mount(`<input name="a" value="x"><div id="slot"></div>`, {
    attrs: 'data-reactive-token-value="t" data-action="input->reactive#trackDirty"',
  })
  await append("append", "slot", `<button hidden data-reactive-clipboard="true">Paste</button>`)

  expect(root.querySelector("button").hidden).toBe(false)
})
