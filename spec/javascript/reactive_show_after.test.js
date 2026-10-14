// The digits: format term and the after: gate (issue #396), in
// features/bindings.js. A show binding with data-reactive-show-after="code"
// stays hidden until the owned `code` field has fired blur (focusout) once
// since connect; after that, every input re-evaluates it at once. A morph
// keeps the flag; a new controller (a full navigation) starts without it.
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
  return { root, controller, $: (sel) => root.querySelector(sel) }
}

const attr = (payload) => JSON.stringify({ any: payload }).replaceAll('"', "&quot;")
const fire = (el, type) => el.dispatchEvent(new window.Event(type, { bubbles: true }))

function type(field, value) {
  field.value = value
  fire(field, "input")
}

const BAD_CODE = [[{ field: "code", digits_eq: 10, prefix: "9", negate: true }]]

const FORM = (scope = "") => `
  <form id="f" data-controller="reactive"${scope ? ` data-reactive-scope="${scope}"` : ""}>
    <input id="code" name="${scope ? `${scope}[code]` : "code"}">
    <input id="other" name="other">
    <p id="hint" hidden data-reactive-show="${attr(BAD_CODE)}" data-reactive-show-after="code">Enter 10 digits starting with 9</p>
    <p id="live" data-reactive-show="${attr(BAD_CODE)}">live</p>
  </form>`

test("the hint stays hidden while typing, and appears on blur when the format fails", () => {
  const { $ } = mount(FORM())
  expect($("#hint").hidden).toBe(true)

  type($("#code"), "12")
  expect($("#hint").hidden).toBe(true) // not blurred yet, even though the value is wrong
  expect($("#live").hidden).toBe(false) // a binding without after: tracks input as today

  fire($("#code"), "focusout")
  expect($("#hint").hidden).toBe(false)
})

test("after that blur, input events update the hint immediately", () => {
  const { $ } = mount(FORM())
  type($("#code"), "12")
  fire($("#code"), "focusout")
  expect($("#hint").hidden).toBe(false)

  type($("#code"), "9123456789")
  expect($("#hint").hidden).toBe(true)
  type($("#code"), "912345678a")
  expect($("#hint").hidden).toBe(false)
})

test("a blur on another field does not open the gate", () => {
  const { $ } = mount(FORM())
  type($("#code"), "12")
  fire($("#other"), "focusout")
  expect($("#hint").hidden).toBe(true)
})

test("the gate resolves its field through data-reactive-scope", () => {
  const { $ } = mount(FORM("acct"))
  type($("#code"), "12")
  expect($("#hint").hidden).toBe(true)
  fire($("#code"), "focusout")
  expect($("#hint").hidden).toBe(false)
})

test("a morph keeps the touched flag; a new controller starts without it", () => {
  const { root, controller, $ } = mount(FORM())
  type($("#code"), "12")
  fire($("#code"), "focusout")
  expect($("#hint").hidden).toBe(false)

  // The morph rewrote the hint to the server's hidden; the re-sync keeps it open.
  $("#hint").hidden = true
  fire($("#hint"), "turbo:morph-element")
  expect($("#hint").hidden).toBe(false)

  controller.disconnect()
  $("#hint").hidden = true
  const fresh = new ReactiveController()
  fresh.element = root
  fresh.connect()
  expect($("#hint").hidden).toBe(true)
})
