// Bulk-selection bindings (issue #319), in features/bindings.js:
//
//   data-reactive-select-all="ids[]"  the header box: its change ticks/unticks
//                                     every OWNED box of the group (dispatching
//                                     change on each flipped one); its checked /
//                                     indeterminate state follows the group.
//   data-reactive-count="ids[]"       textContent = the ticked count.
//   data-reactive-enable='{"any":…}'  the reactive_show conditions, flipping the
//                                     element's own `disabled`.
//   { checked_*: n } terms            count the ticked owned boxes of a group.
//
// Boxes added or removed later (a stream append, a removal) re-sync through a
// MutationObserver installed only on a root that owns a group binding.
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

// MutationObserver callbacks run as microtasks; let them (and their re-sync) land.
const flush = () => new Promise((resolve) => setTimeout(resolve, 0))

function mount(html) {
  document.body.innerHTML = html
  const root = document.querySelector("[data-controller='reactive']")
  const controller = new ReactiveController()
  controller.element = root
  controller.connect()
  const $ = (sel) => root.querySelector(sel)
  const $$ = (sel) => [...root.querySelectorAll(sel)]
  return { root, controller, $, $$ }
}

const ENABLE = JSON.stringify({ any: [[{ field: "ids[]", checked_gte: 1 }]] }).replaceAll('"', "&quot;")

const LIST = `
  <form id="bulk" data-controller="reactive">
    <input type="checkbox" id="all" data-reactive-select-all="ids[]">
    <ul id="rows">
      <li id="r1"><input type="checkbox" name="ids[]" value="1"></li>
      <li id="r2"><input type="checkbox" name="ids[]" value="2"></li>
      <li id="r3"><input type="checkbox" name="ids[]" value="3"></li>
    </ul>
    <span id="count" data-reactive-count="ids[]">0</span>
    <button type="button" id="delete" data-reactive-enable="${ENABLE}">Delete</button>
    <fieldset id="actions" data-reactive-enable="${ENABLE}"></fieldset>
  </form>`

// What a browser does on a checkbox click: flip, then `input`, then `change`.
// (The `input` re-sync runs BEFORE `change` — the header must not be reset to
// its group's state in between.)
function tick(box, checked) {
  box.checked = checked
  box.dispatchEvent(new window.Event("input", { bubbles: true }))
  box.dispatchEvent(new window.Event("change", { bubbles: true }))
}

test("ticking the header ticks every owned box and dispatches change on each flipped one", () => {
  const { root, $, $$ } = mount(LIST)
  const boxes = $$('[name="ids[]"]')
  tick(boxes[0], true) // already ticked: must not be re-dispatched
  const changed = []
  root.addEventListener("change", (e) => e.target.name === "ids[]" && changed.push(e.target.value))

  tick($("#all"), true)

  expect(boxes.map((b) => b.checked)).toEqual([true, true, true])
  expect(changed).toEqual(["2", "3"])
})

test("unticking the header unticks them all", () => {
  const { $, $$ } = mount(LIST)
  tick($("#all"), true)
  tick($("#all"), false)

  expect($$('[name="ids[]"]').map((b) => b.checked)).toEqual([false, false, false])
  expect($("#all").checked).toBe(false)
  expect($("#all").indeterminate).toBe(false)
})

test("the header follows the group: none → unchecked, some → indeterminate, all → checked", () => {
  const { $, $$ } = mount(LIST)
  const all = $("#all")
  const boxes = $$('[name="ids[]"]')
  expect([all.checked, all.indeterminate]).toEqual([false, false])

  tick(boxes[0], true)
  expect([all.checked, all.indeterminate]).toEqual([false, true])

  tick(boxes[1], true)
  tick(boxes[2], true)
  expect([all.checked, all.indeterminate]).toEqual([true, false])

  for (const box of boxes) tick(box, false)
  expect([all.checked, all.indeterminate]).toEqual([false, false])
})

test("the header is seeded at connect from server-rendered checked boxes", () => {
  const { $ } = mount(LIST.replace('value="2"', 'value="2" checked'))
  expect($("#all").indeterminate).toBe(true)
  expect($("#count").textContent).toBe("1")
})

test("reactive_count shows the ticked count and updates on every change", () => {
  const { $, $$ } = mount(LIST)
  const boxes = $$('[name="ids[]"]')
  expect($("#count").textContent).toBe("0")

  tick(boxes[0], true)
  expect($("#count").textContent).toBe("1")
  tick($("#all"), true)
  expect($("#count").textContent).toBe("3")
})

test("reactive_enable keeps a button and a fieldset disabled at 0 and enables them at 1+", () => {
  const { $, $$ } = mount(LIST)
  expect($("#delete").disabled).toBe(true)
  expect($("#actions").disabled).toBe(true)

  tick($$('[name="ids[]"]')[1], true)
  expect($("#delete").disabled).toBe(false)
  expect($("#actions").disabled).toBe(false)

  tick($$('[name="ids[]"]')[1], false)
  expect($("#delete").disabled).toBe(true)
})

test("a row appended after the header was ticked leaves the header indeterminate", async () => {
  const { $ } = mount(LIST)
  tick($("#all"), true)
  expect($("#all").checked).toBe(true)

  $("#rows").insertAdjacentHTML("beforeend", '<li id="r4"><input type="checkbox" name="ids[]" value="4"></li>')
  await flush()

  expect($("#all").checked).toBe(false)
  expect($("#all").indeterminate).toBe(true)
  expect($("#count").textContent).toBe("3")
})

test("a ticked row removed from the DOM updates the count, the header and enable", async () => {
  const { $, $$ } = mount(LIST)
  tick($$('[name="ids[]"]')[0], true)
  expect($("#count").textContent).toBe("1")

  $("#r1").remove()
  await flush()

  expect($("#count").textContent).toBe("0")
  expect($("#all").indeterminate).toBe(false)
  expect($("#delete").disabled).toBe(true)
})

test("nested reactive roots' boxes are neither counted nor flipped by the outer root", () => {
  const { $, $$ } = mount(
    LIST.replace(
      "</ul>",
      `</ul><div data-controller="reactive" id="inner"><input type="checkbox" name="ids[]" value="99" id="nested"></div>`,
    ),
  )
  const nested = $("#nested")
  tick(nested, true)
  expect($("#count").textContent).toBe("0")
  expect($("#all").indeterminate).toBe(false)

  tick($("#all"), false)
  tick($("#all"), true)
  expect($$('#rows [name="ids[]"]').every((b) => b.checked)).toBe(true)
  expect($("#count").textContent).toBe("3")
  nested.checked = false
  tick($("#all"), false)
  expect(nested.checked).toBe(false)
})

test("reactive_show takes a checked count too", () => {
  const show = JSON.stringify({ any: [[{ field: "ids[]", checked_gte: 2 }]] }).replaceAll('"', "&quot;")
  const { $, $$ } = mount(LIST.replace("</form>", `<p id="many" data-reactive-show="${show}">bulk</p></form>`))
  expect($("#many").hidden).toBe(true)
  tick($$('[name="ids[]"]')[0], true)
  tick($$('[name="ids[]"]')[1], true)
  expect($("#many").hidden).toBe(false)
})

test("the count write is change-guarded (an unchanged count leaves the text node alone)", () => {
  const { $, $$ } = mount(LIST)
  const node = $("#count").firstChild
  tick($$('[name="ids[]"]')[0], false)
  expect($("#count").firstChild).toBe(node)
})

test("a root without a group binding installs no MutationObserver", () => {
  let observed = 0
  globalThis.MutationObserver = class {
    observe() {
      observed++
    }
    disconnect() {}
  }
  mount(`<div data-controller="reactive"><input type="checkbox" name="x"></div>`)
  expect(observed).toBe(0)
  mount(LIST)
  expect(observed).toBe(1)
})

test("disconnect stops the observer: a later append no longer re-syncs", async () => {
  const { $, controller } = mount(LIST)
  tick($("#all"), true)
  controller.disconnect()

  $("#rows").insertAdjacentHTML("beforeend", '<li><input type="checkbox" name="ids[]" value="4"></li>')
  await flush()

  expect($("#all").checked).toBe(true)
})

test("a conditional confirm counts a group through the collected fields", async () => {
  const bindings = await import("../../app/javascript/phlex/reactive/features/bindings.js")
  const { $$, controller } = mount(LIST)
  tick($$('[name="ids[]"]')[0], true)
  const core = { collectFields: () => ({ fields: { "ids[]": ["1"] } }) }
  const when = { groups: { any: [[{ field: "ids[]", checked_gte: 1 }]] }, message: "Delete 1?" }

  expect(bindings.confirmMessage(controller, core, when)).toBe("Delete 1?")
  const none = { collectFields: () => ({ fields: { "ids[]": [] } }) }
  expect(bindings.confirmMessage({}, none, when)).toBe(null)
})
