// Issue #365: modal dialogs. Two client ops reach the browser's own modal
// dialog — js.show_modal (HTMLDialogElement#showModal: top layer, focus trap,
// ::backdrop, Escape, focus restored to the opener) and js.close_dialog — and a
// marker, data-reactive-modal, upgrades a dialog the SERVER rendered open
// (a full page, a reply, a broadcast) to a modal one.
//
// happy-dom has HTMLDialogElement#showModal/#close, but `:modal` never
// matches there, so these tests spy on the calls and read `open`; every
// `:modal`, focus-trap, Escape and focus-return assertion lives in
// spec/system/modal_dialog_spec.rb (Chromium).
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
  mod.__resetReactiveStreamRenderForTest()
  mod.registerReactiveStreamRender()
  mod.__resetReactiveModalsForTest()
  mod.registerReactiveModals()
})

afterAll(() => {
  mod.__resetReactiveStreamRenderForTest()
  mod.__resetReactiveModalsForTest()
})

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

// Record showModal/close calls on a dialog, in order, and let a test say
// whether it is :modal (happy-dom never matches the pseudo-class).
function spy(dialog, { modal = false } = {}) {
  const calls = []
  const showModal = dialog.showModal.bind(dialog)
  const close = dialog.close.bind(dialog)
  dialog.showModal = () => {
    calls.push("showModal")
    showModal()
  }
  dialog.close = () => {
    calls.push("close")
    close()
  }
  const matches = dialog.matches.bind(dialog)
  dialog.matches = (sel) => (sel === ":modal" ? modal : matches(sel))
  return calls
}

function mount(html, { id = "r", attrs = 'data-reactive-token-value="t"' } = {}) {
  document.body.insertAdjacentHTML("beforeend", `<div id="${id}" data-controller="reactive" ${attrs}>${html}</div>`)
  const root = document.getElementById(id)
  const controller = new ReactiveController()
  controller.element = root
  return { root, controller }
}

function run(controller, ops) {
  controller.runOps({ params: { ops }, target: controller.element, preventDefault() {} })
}

// --- the ops -----------------------------------------------------------------

test("show_modal opens a closed dialog with showModal()", () => {
  const { root, controller } = mount(`<dialog id="d"><button>x</button></dialog>`)
  const dialog = root.querySelector("dialog")
  const calls = spy(dialog)

  run(controller, [["show_modal", { to: "#d" }]])

  expect(calls).toEqual(["showModal"])
  expect(dialog.open).toBe(true)
})

test("show_modal closes and reopens a dialog that is open but not modal", () => {
  const { root, controller } = mount(`<dialog id="d" open></dialog>`)
  const dialog = root.querySelector("dialog")
  const calls = spy(dialog)

  run(controller, [["show_modal", { to: "#d" }]])

  expect(calls).toEqual(["close", "showModal"])
  expect(dialog.open).toBe(true)
})

test("show_modal leaves a dialog that is already modal alone", () => {
  const { root, controller } = mount(`<dialog id="d" open></dialog>`)
  const calls = spy(root.querySelector("dialog"), { modal: true })

  run(controller, [["show_modal", { to: "#d" }]])

  expect(calls).toEqual([])
})

test("show_modal on an element that is not a dialog does nothing", () => {
  const { root, controller } = mount(`<div id="d"></div>`)
  const div = root.querySelector("#d")
  div.showModal = () => {
    throw new Error("must not be called")
  }

  run(controller, [["show_modal", { to: "#d" }]])

  expect(div.hasAttribute("open")).toBe(false)
})

test("close_dialog closes an open dialog and leaves a closed one alone", () => {
  const { root, controller } = mount(`<dialog id="a" open></dialog><dialog id="b"></dialog>`)
  const a = spy(root.querySelector("#a"))
  const b = spy(root.querySelector("#b"))

  run(controller, [["close_dialog", { to: "#a" }], ["close_dialog", { to: "#b" }]])

  expect(a).toEqual(["close"])
  expect(b).toEqual([])
  expect(root.querySelector("#a").open).toBe(false)
})

// --- the marker --------------------------------------------------------------

test("connect upgrades an open dialog[data-reactive-modal] and leaves an unmarked one alone", () => {
  const { root, controller } = mount(`<dialog id="m" open data-reactive-modal></dialog><dialog id="plain" open></dialog>`)
  const marked = spy(root.querySelector("#m"))
  const plain = spy(root.querySelector("#plain"))

  controller.connect()

  expect(marked).toEqual(["close", "showModal"])
  expect(plain).toEqual([])
})

test("connect leaves a closed marked dialog closed", () => {
  const { root, controller } = mount(`<dialog id="m" data-reactive-modal></dialog>`)
  const calls = spy(root.querySelector("#m"))

  controller.connect()

  expect(calls).toEqual([])
  expect(root.querySelector("#m").open).toBe(false)
})

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
}

test("a stream that inserts an open marked dialog makes it modal after the render", async () => {
  document.body.insertAdjacentHTML("beforeend", `<div id="slot"></div>`)
  let calls = null
  await stream("update", "slot", `<dialog id="m" open data-reactive-modal></dialog>`, (t, html) => {
    t.innerHTML = html
    calls = spy(t.querySelector("dialog"))
  })

  expect(calls).toEqual(["close", "showModal"])
})

test("a stream without a dialog in it does not scan the page", async () => {
  document.body.insertAdjacentHTML("beforeend", `<div id="slot"></div><dialog id="m" open data-reactive-modal></dialog>`)
  const calls = spy(document.getElementById("m"))

  await stream("update", "slot", `<p>hi</p>`, (t, html) => (t.innerHTML = html))

  expect(calls).toEqual([])
})

test("a morph of a root upgrades the marked dialog it now holds", () => {
  const { root } = mount(`<dialog id="m" data-reactive-modal></dialog>`)
  const dialog = root.querySelector("#m")
  const calls = spy(dialog)
  dialog.setAttribute("open", "")

  root.dispatchEvent(new window.CustomEvent("turbo:morph-element", { bubbles: true }))

  expect(calls).toEqual(["close", "showModal"])
})

test("a page morph upgrades every marked dialog on the page", () => {
  document.body.innerHTML = `<dialog id="m" open data-reactive-modal></dialog>`
  const calls = spy(document.getElementById("m"))

  document.dispatchEvent(new window.CustomEvent("turbo:morph"))

  expect(calls).toEqual(["close", "showModal"])
})

// --- a morph that removes `open` ----------------------------------------------

// What Idiomorph does to one dialog, as Turbo drives it: the cancelable
// before-morph-element with the new render, then — for EVERY attribute of the
// old element, whether or not the new one still has it — a "remove" ask.
function removeOpen(dialog, nextHtml = `<dialog id="m"></dialog>`) {
  const holder = document.createElement("div")
  holder.innerHTML = nextHtml
  const newElement = holder.firstElementChild
  dialog.dispatchEvent(
    new window.CustomEvent("turbo:before-morph-element", {
      bubbles: true,
      cancelable: true,
      detail: { currentElement: dialog, newElement },
    }),
  )
  const event = new window.CustomEvent("turbo:before-morph-attribute", {
    bubbles: true,
    cancelable: true,
    detail: { attributeName: "open", mutationType: "remove" },
  })
  dialog.dispatchEvent(event)
  return event.defaultPrevented
}

test("a morph that removes `open` from a modal dialog closes it with close()", () => {
  const { root } = mount(`<dialog id="m" open data-reactive-modal></dialog>`)
  const dialog = root.querySelector("#m")
  const calls = spy(dialog, { modal: true })

  expect(removeOpen(dialog)).toBe(true)
  expect(calls).toEqual(["close"])
  expect(dialog.open).toBe(false)
})

test("a morph that renders a modal dialog open again leaves it modal", () => {
  const { root } = mount(`<dialog id="m" open data-reactive-modal></dialog>`)
  const dialog = root.querySelector("#m")
  const calls = spy(dialog, { modal: true })

  expect(removeOpen(dialog, `<dialog id="m" open data-reactive-modal><p>errors</p></dialog>`)).toBe(false)
  expect(calls).toEqual([])
  expect(dialog.open).toBe(true)
})

test("a morph that removes `open` from a non-modal dialog is left to Idiomorph", () => {
  const { root } = mount(`<dialog id="m" open></dialog>`)
  const dialog = root.querySelector("#m")
  const calls = spy(dialog)

  expect(removeOpen(dialog)).toBe(false)
  expect(calls).toEqual([])
})
