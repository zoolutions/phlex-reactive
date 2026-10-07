// Cross-root group targets (issue #343), in features/bindings.js:
//
//   data-reactive-group-targets='{"ids[]": {"count": ["#c"], "enable": {"#b": {"any": …}}}}'
//
// declared on the root that OWNS a checkbox group: it drives outside, id-only
// elements — a count (textContent) and an enable (`disabled`) — from the
// group's owned ticked boxes, on the same triggers as the in-root bindings
// (every change, a morph, rows added or removed).
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

const attr = (value) => JSON.stringify(value).replaceAll('"', "&quot;")

const TARGETS = attr({
  "ids[]": { count: ["#c"], enable: { "#b": { any: [[{ field: "ids[]", checked_gte: 1 }]] } } },
})

// The bar sits OUTSIDE the owning root (and outside any reactive root).
const PAGE = (targets = TARGETS) => `
  <div id="items-table" data-controller="reactive" data-reactive-group-targets="${targets}">
    <ul id="rows">
      <li><input type="checkbox" name="ids[]" value="1"></li>
      <li><input type="checkbox" name="ids[]" value="2"></li>
      <li><input type="checkbox" name="ids[]" value="3"></li>
    </ul>
  </div>
  <div id="bulk-bar"><span id="c">0</span><button type="button" id="b" disabled>Archive</button></div>`

function mount(html, selector = "#items-table") {
  document.body.innerHTML = html
  const root = document.querySelector(selector)
  const controller = new ReactiveController()
  controller.element = root
  controller.connect()
  return { root, controller, boxes: () => [...root.querySelectorAll('[name="ids[]"]')] }
}

function tick(box, checked) {
  box.checked = checked
  box.dispatchEvent(new window.Event("input", { bubbles: true }))
  box.dispatchEvent(new window.Event("change", { bubbles: true }))
}

const $ = (sel) => document.querySelector(sel)

test("ticking two boxes sets the outside count to 2 and enables the outside button", () => {
  const { boxes } = mount(PAGE())
  tick(boxes()[0], true)
  tick(boxes()[1], true)
  expect($("#c").textContent).toBe("2")
  expect($("#b").disabled).toBe(false)
})

test("unticking all sets the count to 0 and disables the button", () => {
  const { boxes } = mount(PAGE())
  tick(boxes()[0], true)
  tick(boxes()[0], false)
  expect($("#c").textContent).toBe("0")
  expect($("#b").disabled).toBe(true)
})

test("connect seeds the targets from server-rendered ticked boxes", () => {
  mount(PAGE().replace('value="2"', 'value="2" checked'))
  expect($("#c").textContent).toBe("1")
  expect($("#b").disabled).toBe(false)
})

test("an exact-count enable (checked_eq) toggles only at that count", () => {
  const targets = attr({ "ids[]": { enable: { "#b": { any: [[{ field: "ids[]", checked_eq: 2 }]] } } } })
  const { boxes } = mount(PAGE(targets))
  tick(boxes()[0], true)
  expect($("#b").disabled).toBe(true)
  tick(boxes()[1], true)
  expect($("#b").disabled).toBe(false)
  tick(boxes()[2], true)
  expect($("#b").disabled).toBe(true)
})

test("the header's flip re-syncs the outside targets once, with the final count", () => {
  const html = PAGE().replace('<ul id="rows">', '<input type="checkbox" id="all" data-reactive-select-all="ids[]"><ul id="rows">')
  mount(html)
  tick($("#all"), true)
  expect($("#c").textContent).toBe("3")
  expect($("#b").disabled).toBe(false)
})

test("the targets live inside another reactive root: the owner drives them, the other root leaves them alone", () => {
  const { boxes } = mount(`<div id="page" data-controller="reactive">${PAGE()}</div>`)
  const outer = new ReactiveController()
  outer.element = $("#page")
  outer.connect()
  tick(boxes()[0], true)
  expect($("#c").textContent).toBe("1")
  expect($("#b").disabled).toBe(false)
})

test("a nested root's boxes with the same name are not counted", () => {
  const html = PAGE().replace(
    "</ul>",
    `</ul><div data-controller="reactive" id="inner"><input type="checkbox" name="ids[]" value="99" id="nested" checked></div>`,
  )
  mount(html)
  tick($("#nested"), true)
  expect($("#c").textContent).toBe("0")
  expect($("#b").disabled).toBe(true)
})

test("an appended ticked row re-syncs the targets", async () => {
  mount(PAGE())
  $("#rows").insertAdjacentHTML("beforeend", '<li><input type="checkbox" name="ids[]" value="4" checked></li>')
  await flush()
  expect($("#c").textContent).toBe("1")
  expect($("#b").disabled).toBe(false)
})

test("a removed ticked row re-syncs the targets", async () => {
  const { boxes } = mount(PAGE())
  tick(boxes()[0], true)
  boxes()[0].closest("li").remove()
  await flush()
  expect($("#c").textContent).toBe("0")
  expect($("#b").disabled).toBe(true)
})

test("a morph of the owning root (new rows) re-syncs the targets", () => {
  const { root, boxes } = mount(PAGE())
  tick(boxes()[0], true)
  root.querySelector("#rows").innerHTML =
    '<li><input type="checkbox" name="ids[]" value="7" checked></li><li><input type="checkbox" name="ids[]" value="8" checked></li>'
  root.dispatchEvent(new window.CustomEvent("turbo:morph-element", { bubbles: true }))
  expect($("#c").textContent).toBe("2")
})

test("a non-id selector is warn-skipped while its siblings still apply", () => {
  const warn = mock(() => {})
  const original = console.warn
  console.warn = warn
  try {
    const targets = attr({ "ids[]": { count: [".bad", "#c"], enable: { "div > #b": { any: [[{ field: "ids[]", checked_gte: 1 }]] } } } })
    const { boxes } = mount(PAGE(targets))
    tick(boxes()[0], true)
    expect($("#c").textContent).toBe("1")
    expect($("#b").disabled).toBe(true) // the refused enable target is left alone
    expect(warn.mock.calls.some(([msg]) => String(msg).includes("refused cross-root group target"))).toBe(true)
  } finally {
    console.warn = original
  }
})

test("a missing target is skipped and never throws", () => {
  const targets = attr({ "ids[]": { count: ["#nope"], enable: { "#gone": { any: [[{ field: "ids[]", checked_gte: 1 }]] } } } })
  const { boxes } = mount(PAGE(targets))
  expect(() => tick(boxes()[0], true)).not.toThrow()
})

test("a malformed attr warns and is ignored", () => {
  const warn = mock(() => {})
  const original = console.warn
  console.warn = warn
  try {
    const { boxes } = mount(PAGE("{not json"))
    expect(() => tick(boxes()[0], true)).not.toThrow()
    expect($("#c").textContent).toBe("0")
    expect(warn.mock.calls.some(([msg]) => String(msg).includes("data-reactive-group-targets"))).toBe(true)
  } finally {
    console.warn = original
  }
})

test("the count write is change-guarded", () => {
  const { boxes } = mount(PAGE())
  tick(boxes()[0], true)
  const node = $("#c").firstChild
  tick(boxes()[1], false) // count stays 1
  expect($("#c").firstChild).toBe(node)
})
