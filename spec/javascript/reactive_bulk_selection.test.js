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
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"

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

test("a morph that touches the header derives it from the group — it never pushes it onto the rows", () => {
  const { $, $$ } = mount(LIST)
  const boxes = $$('[name="ids[]"]')
  tick(boxes[0], true)
  tick(boxes[1], true)

  const header = $("#all")
  header.checked = false // the server-rendered header after the morph
  header.dispatchEvent(new window.Event("turbo:morph-element", { bubbles: true }))

  expect(boxes.map((b) => b.checked)).toEqual([true, true, false])
  expect([header.checked, header.indeterminate]).toEqual([false, true])
})

test("a flipped box also dispatches input, so input-bound computes re-run", () => {
  const { root, $ } = mount(LIST)
  const inputs = []
  root.addEventListener("input", (e) => e.target.name === "ids[]" && inputs.push(e.target.value))
  tick($("#all"), true)
  expect(inputs).toEqual(["1", "2", "3"])
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

  // Each header action runs against the nested box in the OPPOSITE state, so
  // a flip that reached it would show.
  nested.checked = false
  tick($("#all"), true)
  expect($$('#rows [name="ids[]"]').every((b) => b.checked)).toBe(true)
  expect($("#count").textContent).toBe("3")
  expect(nested.checked).toBe(false)

  nested.checked = true
  tick($("#all"), false)
  expect($$('#rows [name="ids[]"]').some((b) => b.checked)).toBe(false)
  expect(nested.checked).toBe(true)
})

test("reactive_show takes a checked count too", () => {
  const show = JSON.stringify({ any: [[{ field: "ids[]", checked_gte: 2 }]] }).replaceAll('"', "&quot;")
  const { $, $$ } = mount(LIST.replace("</form>", `<p id="many" data-reactive-show="${show}">bulk</p></form>`))
  expect($("#many").hidden).toBe(true)
  tick($$('[name="ids[]"]')[0], true)
  tick($$('[name="ids[]"]')[1], true)
  expect($("#many").hidden).toBe(false)
})

test("a cross-root show target counts a group in both the field-keyed and the #id-keyed form", () => {
  const targets = JSON.stringify({
    "ids[]": { "#some": [{ field: "ids[]", checked_gte: 1 }] },
    "#two": { any: [[{ field: "ids[]", checked_eq: 2 }]] },
  }).replaceAll('"', "&quot;")
  const { $$ } = mount(
    `<p id="some">some</p><p id="two">two</p>` +
      LIST.replace('data-controller="reactive"', `data-controller="reactive" data-reactive-show-targets="${targets}"`),
  )
  const some = document.getElementById("some")
  const two = document.getElementById("two")
  expect([some.hidden, two.hidden]).toEqual([true, true])

  tick($$('[name="ids[]"]')[0], true)
  expect([some.hidden, two.hidden]).toEqual([false, true])
  tick($$('[name="ids[]"]')[2], true)
  expect([some.hidden, two.hidden]).toEqual([false, false])
})

test("reactive_on_complete fires on the rising edge of a checked count", () => {
  const onComplete = JSON.stringify([
    { any: [[{ field: "ids[]", checked_gte: 2 }]], ops: [["add_class", { to: "@root", classes: ["many"] }]] },
  ]).replaceAll('"', "&quot;")
  const { root, $$ } = mount(LIST.replace('data-controller="reactive"', `data-controller="reactive" data-reactive-on-complete="${onComplete}"`))
  tick($$('[name="ids[]"]')[0], true)
  expect(root.classList.contains("many")).toBe(false)
  tick($$('[name="ids[]"]')[1], true)
  expect(root.classList.contains("many")).toBe(true)
})

test("the count write is change-guarded (an unchanged count leaves the text node alone)", () => {
  const { $, $$ } = mount(LIST)
  const node = $("#count").firstChild
  tick($$('[name="ids[]"]')[0], false)
  expect($("#count").firstChild).toBe(node)
})

test("a show-only root never walks for group bindings on a keystroke", () => {
  const show = JSON.stringify({ any: [[{ field: "mode", equals: "a" }]] }).replaceAll('"', "&quot;")
  const { root, $ } = mount(
    `<div data-controller="reactive"><input name="mode" value="a"><p id="p" data-reactive-show="${show}">x</p></div>`,
  )
  const seen = []
  const original = root.querySelectorAll.bind(root)
  root.querySelectorAll = (sel) => (seen.push(sel), original(sel))
  $("[name=mode]").dispatchEvent(new window.Event("input", { bubbles: true }))
  expect(seen.some((sel) => sel.includes("data-reactive-count"))).toBe(false)
})

test("a group binding a morph adds is picked up by the morph's re-sync", () => {
  const { root, $ } = mount(LIST.replace('<span id="count" data-reactive-count="ids[]">0</span>', ""))
  $("[name='ids[]']").checked = true
  root.insertAdjacentHTML("beforeend", '<span id="late" data-reactive-count="ids[]">?</span>')
  root.dispatchEvent(new window.Event("turbo:morph-element", { bubbles: true }))
  expect($("#late").textContent).toBe("1")
})

test("a group binding a morph adds also gets the observer: a later append re-syncs it", async () => {
  const show = JSON.stringify({ any: [[{ field: "mode", equals: "a" }]] }).replaceAll('"', "&quot;")
  const { root, $ } = mount(
    `<form id="late-root" data-controller="reactive"><input name="mode" value="a"><p data-reactive-show="${show}">x</p>` +
      `<ul id="rows"><li><input type="checkbox" name="ids[]" value="1" checked></li></ul></form>`,
  )
  root.insertAdjacentHTML("beforeend", '<span id="late" data-reactive-count="ids[]">?</span>')
  root.dispatchEvent(new window.Event("turbo:morph-element", { bubbles: true }))
  expect($("#late").textContent).toBe("1")

  $("#rows").insertAdjacentHTML("beforeend", '<li><input type="checkbox" name="ids[]" value="2" checked></li>')
  await flush()
  expect($("#late").textContent).toBe("2")
})

test("a checked-count show target alone gets the observer: removing a ticked row re-hides it", async () => {
  const targets = JSON.stringify({ "#some": { any: [[{ field: "ids[]", checked_gte: 1 }]] } }).replaceAll('"', "&quot;")
  const { $ } = mount(
    `<p id="some">some</p><form id="targets-root" data-controller="reactive" data-reactive-show-targets="${targets}">` +
      `<ul id="rows"><li id="r1"><input type="checkbox" name="ids[]" value="1"></li>` +
      `<li id="r2"><input type="checkbox" name="ids[]" value="2"></li></ul></form>`,
  )
  const some = document.getElementById("some")
  tick($("#r1 input"), true)
  expect(some.hidden).toBe(false)

  $("#r1").remove()
  await flush()
  expect(some.hidden).toBe(true)
})

test("a removed ticked row re-arms a checked-count reactive_on_complete, so the next selection fires", async () => {
  const onComplete = JSON.stringify([
    { any: [[{ field: "ids[]", checked_gte: 2 }]], ops: [["add_class", { to: "@root", classes: ["many"] }]] },
  ]).replaceAll('"', "&quot;")
  const { root, $, $$ } = mount(
    `<form id="complete-root" data-controller="reactive" data-reactive-on-complete="${onComplete}"><ul id="rows">` +
      `<li id="r1"><input type="checkbox" name="ids[]" value="1"></li>` +
      `<li id="r2"><input type="checkbox" name="ids[]" value="2"></li>` +
      `<li id="r3"><input type="checkbox" name="ids[]" value="3"></li></ul></form>`,
  )
  tick($$("[name='ids[]']")[0], true)
  tick($$("[name='ids[]']")[1], true)
  expect(root.classList.contains("many")).toBe(true)
  root.classList.remove("many")

  $("#r1").remove()
  await flush()
  tick($("#r3 input"), true)
  expect(root.classList.contains("many")).toBe(true)
})

test("the header sets every box before dispatching, so a checked-count on_complete sees the final count", () => {
  const onComplete = JSON.stringify([
    { any: [[{ field: "ids[]", checked_eq: 2 }]], ops: [["add_class", { to: "@root", classes: ["two"] }]] },
  ]).replaceAll('"', "&quot;")
  const { root, $ } = mount(LIST.replace('data-controller="reactive"', `data-controller="reactive" data-reactive-on-complete="${onComplete}"`))
  tick($("#all"), true)
  expect(root.classList.contains("two")).toBe(false)
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

// Issue #348: a show target referencing a group ONLY through checked_* terms
// is always decidable — a group with no owned boxes counts 0 — so it is
// evaluated (and hidden) even when the root owns none of the group's boxes.
// A value term whose field is unowned still leaves its target alone.
const showTargetsRoot = (targets, rows) =>
  `<p id="bar">bar</p><form id="targets-root" data-controller="reactive" ` +
  `data-reactive-show-targets="${JSON.stringify(targets).replaceAll('"', "&quot;")}"><ul id="rows">${rows}</ul></form>`

const ONE_ROW = '<li id="r1"><input type="checkbox" name="ids[]" value="1"></li>'
const CHECKED_BAR = { "#bar": { any: [[{ field: "ids[]", checked_gte: 1 }]] } }

test("removing the last owned box of a group hides a checked-count show target (#348)", async () => {
  const { $ } = mount(showTargetsRoot(CHECKED_BAR, ONE_ROW))
  const bar = document.getElementById("bar")
  tick($("#r1 input"), true)
  expect(bar.hidden).toBe(false)

  $("#r1").remove()
  await flush()
  expect(bar.hidden).toBe(true)
})

test("a morph that leaves no box of the group hides a checked-count show target (#348)", () => {
  const { root, $ } = mount(showTargetsRoot(CHECKED_BAR, ONE_ROW))
  const bar = document.getElementById("bar")
  tick($("#r1 input"), true)
  expect(bar.hidden).toBe(false)

  $("#rows").innerHTML = ""
  root.dispatchEvent(new window.Event("turbo:morph-element", { bubbles: true }))
  expect(bar.hidden).toBe(true)
})

test("a root that never owned a box of the group paints a checked-count show target hidden (#348)", () => {
  mount(showTargetsRoot(CHECKED_BAR, ""))
  expect(document.getElementById("bar").hidden).toBe(true)
})

for (const hidden of [true, false]) {
  test(`a value-term show target whose field is unowned is left alone (starts hidden=${hidden}, #348)`, () => {
    const { root } = mount(showTargetsRoot({ "#bar": { any: [[{ field: "mode", equals: "advanced" }]] } }, ONE_ROW))
    const bar = document.getElementById("bar")
    bar.hidden = hidden
    root.dispatchEvent(new window.Event("turbo:morph-element", { bubbles: true }))
    expect(bar.hidden).toBe(hidden)
  })

  test(`a mixed payload keeps the skip while none of its fields is owned (starts hidden=${hidden}, #348)`, () => {
    const mixed = { "#bar": { any: [[{ field: "mode", equals: "x" }, { field: "ids[]", checked_gte: 1 }]] } }
    const { root } = mount(showTargetsRoot(mixed, ""))
    const bar = document.getElementById("bar")
    bar.hidden = hidden
    root.dispatchEvent(new window.Event("turbo:morph-element", { bubbles: true }))
    expect(bar.hidden).toBe(hidden)
  })
}

// The cross-root and the in-root paths agree on every checked-only vector of
// the shared fixture — zero boxes included.
const CHECKED_VECTORS = JSON.parse(
  readFileSync(fileURLToPath(new URL("../fixtures/show_predicate_vectors.json", import.meta.url)), "utf8"),
).vectors.filter((vector) => vector.groups.flat().every((term) => Object.keys(term).some((key) => key.startsWith("checked_"))))

test("the fixture has checked-only vectors to compare", () => {
  expect(CHECKED_VECTORS.length).toBeGreaterThanOrEqual(5)
})

for (const vector of CHECKED_VECTORS) {
  test(`cross-root agrees with in-root: ${vector.name}`, () => {
    const boxes = Object.entries(vector.values).flatMap(([name, values]) =>
      values.map((value) => `<input type="checkbox" name="${name}" value="${value}" checked>`))
    const show = JSON.stringify({ any: vector.groups }).replaceAll('"', "&quot;")
    mount(showTargetsRoot({ "#bar": { any: vector.groups } }, `${boxes.join("")}<p id="inside" data-reactive-show="${show}">in</p>`))
    expect(document.getElementById("bar").hidden).toBe(!vector.expect)
    expect(document.getElementById("inside").hidden).toBe(!vector.expect)
  })
}
