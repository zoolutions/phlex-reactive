// reactive_show visibility transitions (issue #394), in features/bindings.js:
//
//   data-reactive-show-clear='["notes"]'  on visible -> hidden, empty each owned
//                                         field (set_value's write; a checkbox
//                                         or radio unchecks, a file input is
//                                         skipped) and dispatch one bubbling
//                                         `input` per field that changed
//   data-reactive-show-focus="#notes"     on hidden -> visible, focus the first
//                                         match inside the root
//   data-reactive-show-scroll="true"      on hidden -> visible, scrollIntoView
//
// None of them run on the first sync after connect (first paint), and a morph
// keeps the previous visibility, so a re-sync that changes nothing does nothing.
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll, beforeEach, afterEach } from "bun:test"
import { Window } from "happy-dom"

const window = new Window()
let ReactiveController
const SAVED = {}
const SCROLL_INTO_VIEW = window.HTMLElement.prototype.scrollIntoView

beforeAll(async () => {
  mock.module("@hotwired/stimulus", () => ({ Controller: class {} }))
  ReactiveController = (await import("../../app/javascript/phlex/reactive/reactive_controller.js")).default
})

beforeEach(() => {
  for (const key of ["document", "window", "Event", "CustomEvent", "MutationObserver"]) SAVED[key] = globalThis[key]
  globalThis.document = window.document
  globalThis.window = window
  globalThis.Event = window.Event
  globalThis.CustomEvent = window.CustomEvent
  globalThis.MutationObserver = window.MutationObserver
  document.body.innerHTML = ""
})

afterEach(() => {
  for (const [key, value] of Object.entries(SAVED)) globalThis[key] = value
  window.HTMLElement.prototype.scrollIntoView = SCROLL_INTO_VIEW
})

function mount(html) {
  document.body.innerHTML = html
  const root = document.querySelector("[data-controller='reactive']")
  const controller = new ReactiveController()
  controller.element = root
  controller.connect()
  return { root, controller, $: (sel) => root.querySelector(sel) }
}

const attr = (payload) => JSON.stringify(payload).replaceAll('"', "&quot;")
const fire = (el, type) => el.dispatchEvent(new window.Event(type, { bubbles: true }))

function choose(radio) {
  radio.checked = true
  fire(radio, "input")
  fire(radio, "change")
}

const OTHER = { any: [[{ field: "kind", equals: "other" }]] }

const FORM = ({ kind = "", notes = "", agree = false, hidden = true } = {}) => `
  <form id="f" data-controller="reactive">
    <input type="radio" id="other" name="kind" value="other"${kind === "other" ? " checked" : ""}>
    <input type="radio" id="listed" name="kind" value="listed"${kind === "listed" ? " checked" : ""}>
    <div id="section"${hidden ? " hidden" : ""} data-reactive-show="${attr(OTHER)}"
         data-reactive-show-clear="${attr(["notes", "agree", "photo", "size"])}"
         data-reactive-show-focus="#notes" data-reactive-show-scroll="true">
      <input id="notes" name="notes" value="${notes}">
      <input type="checkbox" id="agree" name="agree"${agree ? " checked" : ""}>
      <input type="file" id="photo" name="photo">
      <select id="size" name="size"><option value="">-</option><option value="l" selected>L</option></select>
    </div>
  </form>`

function spy(root) {
  const inputs = []
  root.addEventListener("input", (e) => inputs.push(e.target.id))
  return inputs
}

test("first paint of a hidden section does not clear server-rendered values", () => {
  const { $ } = mount(FORM({ kind: "listed", notes: "saved", agree: true }))
  expect($("#section").hidden).toBe(true)
  expect($("#notes").value).toBe("saved")
  expect($("#agree").checked).toBe(true)
  expect($("#size").value).toBe("l")
})

test("first paint of a visible section does not move focus or scroll", () => {
  let scrolled = 0
  window.HTMLElement.prototype.scrollIntoView = () => scrolled++
  const { $ } = mount(FORM({ kind: "other", hidden: false }))
  expect($("#section").hidden).toBe(false)
  expect(document.activeElement).not.toBe($("#notes"))
  expect(scrolled).toBe(0)
})

test("going hidden clears each clear: field and dispatches one input per field that changed", () => {
  const { root, $ } = mount(FORM({ kind: "other", notes: "typed", agree: true, hidden: false }))
  const inputs = spy(root)

  choose($("#listed"))

  expect($("#section").hidden).toBe(true)
  expect($("#notes").value).toBe("")
  expect($("#agree").checked).toBe(false)
  expect($("#size").value).toBe("")
  expect(inputs.filter((id) => id !== "listed").sort()).toEqual(["agree", "notes", "size"])
})

test("a field that is already empty is not announced", () => {
  const { root, $ } = mount(FORM({ kind: "other", hidden: false }))
  $("#size").value = ""
  const inputs = spy(root)
  choose($("#listed"))
  expect(inputs.filter((id) => id !== "listed")).toEqual([])
})

test("going visible focuses focus: and scrolls the section into view", () => {
  const scrolled = []
  window.HTMLElement.prototype.scrollIntoView = function () {
    scrolled.push(this.id)
  }
  const { $ } = mount(FORM({ kind: "listed" }))

  choose($("#other"))

  expect($("#section").hidden).toBe(false)
  expect(document.activeElement).toBe($("#notes"))
  expect(scrolled).toEqual(["section"])
})

test("a morph that leaves the predicate unchanged runs nothing", () => {
  const { root, $ } = mount(FORM({ kind: "other", notes: "typed", hidden: false }))
  const inputs = spy(root)
  fire($("#section"), "turbo:morph-element")
  expect($("#notes").value).toBe("typed")
  expect(inputs).toEqual([])
})

test("a binding without these attrs only toggles hidden", () => {
  const { $ } = mount(`
    <form id="g" data-controller="reactive">
      <input type="radio" id="other" name="kind" value="other" checked>
      <input type="radio" id="listed" name="kind" value="listed">
      <div id="plain" data-reactive-show="${attr(OTHER)}"><input id="notes" name="notes" value="kept"></div>
    </form>`)
  choose($("#listed"))
  expect($("#plain").hidden).toBe(true)
  expect($("#notes").value).toBe("kept")
})

test("a clear: name with CSS-special characters clears its field without throwing", () => {
  const { $ } = mount(`
    <form id="q" data-controller="reactive">
      <input type="radio" id="other" name="kind" value="other" checked>
      <input type="radio" id="listed" name="kind" value="listed">
      <div id="section" data-reactive-show="${attr(OTHER)}" data-reactive-show-clear="${attr(['a"b\\c'])}">
        <input id="odd" name='a"b\\c' value="typed">
      </div>
    </form>`)
  expect($("#odd").getAttribute("name")).toBe('a"b\\c')
  choose($("#listed"))
  expect($("#section").hidden).toBe(true)
  expect($("#odd").value).toBe("")
})

test("a morph that drops then restores the attrs does not replay a stale transition", () => {
  const { $ } = mount(FORM({ kind: "other", notes: "typed", hidden: false }))
  const section = $("#section")
  const clear = section.getAttribute("data-reactive-show-clear")
  for (const name of ["clear", "focus", "scroll"]) section.removeAttribute(`data-reactive-show-${name}`)
  fire(section, "turbo:morph-element")

  choose($("#listed")) // hidden while the binding declares no transition work
  expect(section.hidden).toBe(true)
  $("#notes").value = "kept"

  section.setAttribute("data-reactive-show-clear", clear)
  fire(section, "turbo:morph-element") // still hidden: no change, nothing to clear
  expect($("#notes").value).toBe("kept")
})
