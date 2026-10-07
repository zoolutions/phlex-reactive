// js.check_group (issue #342): a client op that ticks or unticks every OWNED
// box of a named checkbox group from any control — the "Clear selection ✕"
// button of a bulk-action bar — and re-syncs the group bindings once, exactly
// as the select-all header's own edit does. Plus: a form `reset` inside the
// root re-syncs the group bindings.
//
// happy-dom, so selectors, events and MutationObserver are real.
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll, beforeEach, afterEach } from "bun:test"
import { Window } from "happy-dom"

const window = new Window()
let ReactiveController
const SAVED = {}

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
})

const flush = () => new Promise((resolve) => setTimeout(resolve, 0))

function connect(root) {
  const controller = new ReactiveController()
  controller.element = root
  controller.connect()
  return controller
}

function mount(html) {
  document.body.innerHTML = html
  const root = document.querySelector("[data-controller='reactive']")
  const controller = connect(root)
  const $ = (sel) => document.querySelector(sel)
  const $$ = (sel) => [...root.querySelectorAll(sel)]
  return { root, controller, $, $$ }
}

const ENABLE = JSON.stringify({ any: [[{ field: "ids[]", checked_gte: 1 }]] }).replaceAll('"', "&quot;")
const SHOW = ENABLE

const LIST = `
  <div id="table" data-controller="reactive">
    <form id="bulk">
      <input type="search" name="q" value="">
      <input type="checkbox" id="all" data-reactive-select-all="ids[]">
      <ul id="rows">
        <li><input type="checkbox" name="ids[]" value="1"></li>
        <li><input type="checkbox" name="ids[]" value="2"></li>
        <li><input type="checkbox" name="ids[]" value="3"></li>
      </ul>
      <button type="reset" id="reset">Reset</button>
    </form>
    <div id="bar" data-reactive-show="${SHOW}" hidden>
      <span id="count" data-reactive-count="ids[]">0</span>
      <button type="button" id="archive" data-reactive-enable="${ENABLE}" disabled>Archive</button>
    </div>
  </div>`

function tick(box, checked) {
  box.checked = checked
  box.dispatchEvent(new window.Event("input", { bubbles: true }))
  box.dispatchEvent(new window.Event("change", { bubbles: true }))
}

function runOps(controller, ops) {
  controller.runOps({ preventDefault() {}, params: { ops: JSON.stringify(ops) } })
}

const clear = (extra = {}) => [["check_group", { to: "@root", group: "ids[]", checked: false, ...extra }]]
const checkAll = [["check_group", { to: "@root", group: "ids[]", checked: true }]]

test("check_group false unticks every owned box and re-syncs header, count, show and enable", () => {
  const { controller, $, $$ } = mount(LIST)
  const boxes = $$('[name="ids[]"]')
  tick(boxes[0], true)
  tick(boxes[1], true)
  expect($("#count").textContent).toBe("2")
  expect($("#bar").hidden).toBe(false)
  expect($("#all").indeterminate).toBe(true)

  runOps(controller, clear())

  expect(boxes.map((b) => b.checked)).toEqual([false, false, false])
  expect($("#all").checked).toBe(false)
  expect($("#all").indeterminate).toBe(false)
  expect($("#count").textContent).toBe("0")
  expect($("#bar").hidden).toBe(true)
  expect($("#archive").disabled).toBe(true)
})

test("check_group true ticks every owned box and the header becomes checked", () => {
  const { controller, $, $$ } = mount(LIST)
  runOps(controller, checkAll)

  expect($$('[name="ids[]"]').every((b) => b.checked)).toBe(true)
  expect($("#all").checked).toBe(true)
  expect($("#all").indeterminate).toBe(false)
  expect($("#count").textContent).toBe("3")
  expect($("#archive").disabled).toBe(false)
})

test("each flipped box receives input then change; boxes already in the target state receive nothing", () => {
  const { root, controller, $$ } = mount(LIST)
  const boxes = $$('[name="ids[]"]')
  tick(boxes[1], true)
  const seen = []
  for (const type of ["input", "change"]) {
    root.addEventListener(type, (e) => e.target.name === "ids[]" && seen.push(`${e.target.value}:${type}`))
  }

  runOps(controller, clear())

  expect(seen).toEqual(["2:input", "2:change"])
})

test("a nested reactive root's boxes with the same name are neither flipped nor counted", () => {
  const { controller, $, $$ } = mount(
    LIST.replace(
      "</ul>",
      `</ul><div data-controller="reactive" id="inner"><input type="checkbox" name="ids[]" value="99" id="nested"></div>`,
    ),
  )
  const nested = $("#nested")
  nested.checked = true
  tick($$('#rows [name="ids[]"]')[0], true)

  runOps(controller, clear())
  expect(nested.checked).toBe(true)
  expect($("#count").textContent).toBe("0")

  nested.checked = false
  runOps(controller, checkAll)
  expect(nested.checked).toBe(false)
  expect($("#count").textContent).toBe("3")
})

test("a listener on the group sees the final count, never a half-flipped group", () => {
  const { root, controller, $$ } = mount(LIST)
  $$('[name="ids[]"]').forEach((b) => tick(b, true))
  const counts = []
  root.addEventListener("change", () => counts.push($$('[name="ids[]"]').filter((b) => b.checked).length))

  runOps(controller, clear())

  expect(counts).toEqual([0, 0, 0])
})

test("a bare group name takes the root's reactive_scope; a bracketed one is used verbatim", () => {
  const { controller, $ } = mount(`
    <div data-controller="reactive" data-reactive-scope="post">
      <input type="checkbox" name="post[flag]" value="1" checked id="scoped">
      <input type="checkbox" name="flag" value="x" checked id="bare">
      <input type="checkbox" name="ids[]" value="1" checked id="raw">
      <span id="count" data-reactive-count="flag">1</span>
    </div>`)

  runOps(controller, [["check_group", { to: "@root", group: "flag", checked: false }]])
  expect($("#scoped").checked).toBe(false)
  expect($("#bare").checked).toBe(true)
  expect($("#count").textContent).toBe("0")

  runOps(controller, [["check_group", { to: "@root", group: "ids[]", checked: false }]])
  expect($("#raw").checked).toBe(false)
})

test("works on a root with no group bindings at all (only the boxes)", () => {
  const { controller, $$ } = mount(`
    <div data-controller="reactive">
      <input type="checkbox" name="ids[]" value="1" checked>
      <input type="checkbox" name="ids[]" value="2" checked>
    </div>`)

  runOps(controller, clear())

  expect($$('[name="ids[]"]').some((b) => b.checked)).toBe(false)
})

test("global: true flips the group in the root that owns the boxes, from a trigger outside it", () => {
  document.body.innerHTML = `
    <div id="page" data-controller="reactive">
      <button id="clear" type="button">✕</button>
      ${LIST}
    </div>`
  const page = document.querySelector("#page")
  const table = document.querySelector("#table")
  const pageController = connect(page)
  connect(table)
  const boxes = [...table.querySelectorAll('[name="ids[]"]')]
  tick(boxes[0], true)
  expect(document.querySelector("#count").textContent).toBe("1")

  runOps(pageController, clear({ global: true }))

  expect(boxes.some((b) => b.checked)).toBe(false)
  expect(document.querySelector("#count").textContent).toBe("0")
  expect(document.querySelector("#bar").hidden).toBe(true)
})

test("global: true reaches every root that owns boxes of the group, a nested one included", () => {
  document.body.innerHTML = `
    <div id="page" data-controller="reactive">
      <div id="a" data-controller="reactive"><input type="checkbox" name="ids[]" value="1" checked></div>
      <div id="b" data-controller="reactive"><input type="checkbox" name="ids[]" value="2" checked></div>
    </div>`
  const pageController = connect(document.querySelector("#page"))
  for (const id of ["#a", "#b"]) connect(document.querySelector(id))

  runOps(pageController, clear({ global: true }))

  expect([...document.querySelectorAll('[name="ids[]"]')].some((b) => b.checked)).toBe(false)
})

test("without global:, a trigger's own root that owns no boxes flips nothing (ownership)", () => {
  document.body.innerHTML = `<div id="page" data-controller="reactive">${LIST}</div>`
  const page = document.querySelector("#page")
  const table = document.querySelector("#table")
  const pageController = connect(page)
  connect(table)
  const box = table.querySelector('[name="ids[]"]')
  tick(box, true)

  runOps(pageController, clear())

  expect(box.checked).toBe(true)
})

test("it chains like any op", () => {
  const { controller, $, $$ } = mount(LIST)
  tick($$('[name="ids[]"]')[0], true)

  runOps(controller, [...clear(), ["add_class", { to: "@root", classes: ["cleared"] }]])

  expect($("#table").classList.contains("cleared")).toBe(true)
  expect($("#count").textContent).toBe("0")
})

test("a form reset inside the root re-syncs the group bindings after the reset applies", async () => {
  const { $, $$ } = mount(LIST)
  const boxes = $$('[name="ids[]"]')
  tick(boxes[0], true)
  tick(boxes[1], true)
  expect($("#count").textContent).toBe("2")

  $("#bulk").reset()
  await flush()

  expect(boxes.some((b) => b.checked)).toBe(false)
  expect($("#count").textContent).toBe("0")
  expect($("#bar").hidden).toBe(true)
  expect($("#archive").disabled).toBe(true)
  expect($("#all").indeterminate).toBe(false)
})

test("a form reset re-arms a checked-count on_complete, so the next rise fires again", async () => {
  const onComplete = JSON.stringify([
    { any: [[{ field: "ids[]", checked_gte: 1 }]], ops: [["toggle_class", { to: "@root", classes: ["many"] }]] },
  ]).replaceAll('"', "&quot;")
  const { root, $, $$ } = mount(LIST.replace('data-controller="reactive"', `data-controller="reactive" data-reactive-on-complete="${onComplete}"`))
  const boxes = $$('[name="ids[]"]')
  tick(boxes[0], true)
  expect(root.classList.contains("many")).toBe(true)

  $("#bulk").reset()
  await flush()
  tick(boxes[0], true)

  // Re-armed by the reset: the second rise fires again (toggles the class off).
  expect(root.classList.contains("many")).toBe(false)
})
