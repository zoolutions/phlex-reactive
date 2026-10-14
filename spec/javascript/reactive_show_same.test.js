// The same: term (issue #395), in features/bindings.js: a show or enable
// condition that compares one owned field with ANOTHER, live, with an optional
// ASCII-only case fold. The fixture vectors (show_predicate_vectors.json) pin
// the evaluator; these drive it through real events.
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

function mount(html) {
  document.body.innerHTML = html
  const root = document.querySelector("[data-controller='reactive']")
  const controller = new ReactiveController()
  controller.element = root
  controller.connect()
  return { root, $: (sel) => root.querySelector(sel) }
}

const attr = (payload) => JSON.stringify({ any: payload }).replaceAll('"', "&quot;")

function type(field, value) {
  field.value = value
  field.dispatchEvent(new window.Event("input", { bubbles: true }))
}

const FORM = (scope = "") => `
  <form id="f" data-controller="reactive"${scope ? ` data-reactive-scope="${scope}"` : ""}>
    <input id="email" name="${scope ? `${scope}[email]` : "email"}">
    <input id="confirm" name="${scope ? `${scope}[confirm]` : "confirm"}">
    <button id="save" data-reactive-enable="${attr([[{ field: "confirm", same: "email", fold: true }]])}">Save</button>
    <p id="hint" data-reactive-show="${attr([[{ field: "confirm", same: "email", fold: true, negate: true }]])}">differ</p>
  </form>`

test("the enable follows both fields live, folding ASCII case", () => {
  const { $ } = mount(FORM())
  expect($("#save").disabled).toBe(false) // an empty pair is equal
  expect($("#hint").hidden).toBe(true)

  type($("#email"), "a@x.test")
  expect($("#save").disabled).toBe(true)
  expect($("#hint").hidden).toBe(false)

  type($("#confirm"), "A@X.TEST")
  expect($("#save").disabled).toBe(false)
  expect($("#hint").hidden).toBe(true)

  // Editing the OTHER field re-evaluates too.
  type($("#email"), "b@x.test")
  expect($("#save").disabled).toBe(true)
  expect($("#hint").hidden).toBe(false)
})

test("the fold is ASCII-only: a non-ASCII case difference stays unequal", () => {
  const { $ } = mount(FORM())
  type($("#email"), "ä")
  type($("#confirm"), "Ä")
  expect($("#save").disabled).toBe(true)
})

test("same: resolves the other field through data-reactive-scope", () => {
  const { $ } = mount(FORM("user"))
  type($("#email"), "a@x.test")
  type($("#confirm"), "a@x.test")
  expect($("#save").disabled).toBe(false)
  type($("#confirm"), "a@x.tes")
  expect($("#save").disabled).toBe(true)
})
