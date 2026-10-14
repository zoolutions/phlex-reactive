// Nested checkbox groups (issue #398), in features/bindings.js:
//
//   data-reactive-select-all="perms[]"                       the flat header: every owned box of the name
//   data-reactive-select-all="perms[]"
//   data-reactive-select-all-under="library"                 a branch header: the owned boxes of the name
//                                                            whose data-reactive-group is "library" or
//                                                            below it ("library.books")
//   <input name="perms[]" data-reactive-group="library.books">   a leaf: posts under the shared name
//
// A branch header ticks/unticks its leaves (input + change on each flipped
// one) and is checked / indeterminate / unchecked from them. A nested header
// is derived from the same leaves, so its parent follows it. Headers have no
// name, so they never post and never count.
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

function mount(html) {
  document.body.innerHTML = html
  const root = document.querySelector("[data-controller='reactive']")
  const controller = new ReactiveController()
  controller.element = root
  controller.connect()
  const $ = (sel) => root.querySelector(sel)
  return { root, controller, $ }
}

const TREE = `
  <form id="perms" data-controller="reactive">
    <input type="checkbox" id="all" data-reactive-select-all="perms[]">
    <input type="checkbox" id="library" data-reactive-select-all="perms[]" data-reactive-select-all-under="library">
    <input type="checkbox" id="notes" name="perms[]" value="notes" data-reactive-group="library">
    <input type="checkbox" id="books" data-reactive-select-all="perms[]" data-reactive-select-all-under="library.books">
    <input type="checkbox" id="view" name="perms[]" value="view" data-reactive-group="library.books">
    <input type="checkbox" id="edit" name="perms[]" value="edit" data-reactive-group="library.books">
    <input type="checkbox" id="billing" name="perms[]" value="billing" data-reactive-group="billing">
    <input type="checkbox" id="libraryx" name="perms[]" value="libraryx" data-reactive-group="libraryx">
    <span id="count" data-reactive-count="perms[]">0</span>
    <div data-controller="reactive">
      <input type="checkbox" id="nested" name="perms[]" value="nested" data-reactive-group="library">
    </div>
  </form>`

function tick(box, checked) {
  box.checked = checked
  box.dispatchEvent(new window.Event("input", { bubbles: true }))
  box.dispatchEvent(new window.Event("change", { bubbles: true }))
}

const state = (el) => [el.checked, el.indeterminate]
const checkedIds = ($) => ["notes", "view", "edit", "billing", "libraryx", "nested"].filter((id) => $(`#${id}`).checked)

test("checking a parent checks every descendant leaf, and only those", () => {
  const { $ } = mount(TREE)
  tick($("#library"), true)
  expect(checkedIds($)).toEqual(["notes", "view", "edit"])
})

test("a parent dispatches input and change on each leaf it flips, and on no other box", () => {
  const { root, $ } = mount(TREE)
  tick($("#view"), true) // already ticked: no re-dispatch
  const events = []
  for (const type of ["input", "change"]) {
    root.addEventListener(type, (e) => e.target.name === "perms[]" && events.push(`${type}:${e.target.value}`))
  }

  tick($("#library"), true)
  expect(events).toEqual(["input:notes", "change:notes", "input:edit", "change:edit"])

  events.length = 0
  tick($("#library"), false)
  expect(checkedIds($)).toEqual([])
  expect(events).toEqual(["input:notes", "change:notes", "input:view", "change:view", "input:edit", "change:edit"])
})

test("a parent is indeterminate on some, checked on all, unchecked on none of its leaves", () => {
  const { $ } = mount(TREE)
  expect(state($("#library"))).toEqual([false, false])

  tick($("#notes"), true)
  expect(state($("#library"))).toEqual([false, true])

  tick($("#view"), true)
  tick($("#edit"), true)
  expect(state($("#library"))).toEqual([true, false])

  for (const id of ["notes", "view", "edit"]) tick($(`#${id}`), false)
  expect(state($("#library"))).toEqual([false, false])
})

test("a nested header reports its own leaves, and its parent follows it", () => {
  const { $ } = mount(TREE)
  tick($("#view"), true)
  expect(state($("#books"))).toEqual([false, true])
  expect(state($("#library"))).toEqual([false, true])
  expect(state($("#all"))).toEqual([false, true])

  tick($("#books"), true)
  expect(checkedIds($)).toEqual(["view", "edit"])
  expect(state($("#books"))).toEqual([true, false])
  expect(state($("#library"))).toEqual([false, true]) // notes is still unticked

  tick($("#notes"), true)
  expect(state($("#library"))).toEqual([true, false])

  tick($("#books"), false)
  expect(state($("#books"))).toEqual([false, false])
  expect(state($("#library"))).toEqual([false, true])
})

test("the root header toggles every leaf of the name and syncs the branch headers", () => {
  const { $ } = mount(TREE)
  tick($("#all"), true)
  expect(checkedIds($)).toEqual(["notes", "view", "edit", "billing", "libraryx"])
  expect(state($("#library"))).toEqual([true, false])
  expect(state($("#books"))).toEqual([true, false])
  expect(state($("#all"))).toEqual([true, false])

  tick($("#billing"), false)
  expect(state($("#all"))).toEqual([false, true])
  expect(state($("#library"))).toEqual([true, false])
})

test("headers never count: reactive_count stays the ticked leaves of the wire name", () => {
  const { $ } = mount(TREE)
  tick($("#library"), true)
  expect($("#count").textContent).toBe("3")
  tick($("#all"), true)
  expect($("#count").textContent).toBe("5")
})

test("a path prefix matches whole segments: library never owns libraryx", () => {
  const { $ } = mount(TREE)
  tick($("#libraryx"), true)
  expect(state($("#library"))).toEqual([false, false])
})

test("a nested reactive root's leaf stays its own root's", () => {
  const { $ } = mount(TREE)
  tick($("#library"), true)
  expect($("#nested").checked).toBe(false)
  expect(state($("#library"))).toEqual([true, false])
})

test("the branch headers are seeded at connect from server-rendered checked leaves", () => {
  const { $ } = mount(TREE.replace('value="edit"', 'value="edit" checked'))
  expect(state($("#books"))).toEqual([false, true])
  expect(state($("#library"))).toEqual([false, true])
})

test("a leaf appended into a fully-checked branch makes it indeterminate", async () => {
  const { $ } = mount(TREE)
  tick($("#books"), true)
  expect(state($("#books"))).toEqual([true, false])

  $("#edit").insertAdjacentHTML(
    "afterend",
    '<input type="checkbox" id="share" name="perms[]" value="share" data-reactive-group="library.books">',
  )
  await flush()
  expect(state($("#books"))).toEqual([false, true])
})

test("a morph that touches a branch header derives it from its leaves, never pushes it onto them", () => {
  const { $ } = mount(TREE)
  tick($("#view"), true)
  const books = $("#books")
  books.checked = true
  books.dispatchEvent(new window.Event("turbo:morph-element", { bubbles: true }))
  expect(checkedIds($)).toEqual(["view"])
  expect(state(books)).toEqual([false, true])
})
