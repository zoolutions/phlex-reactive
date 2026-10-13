// Issue #380: reactive_media leaves the preview alone until the field has
// `take` characters (and, with `match`, until the key matches).
//
//   data-reactive-media='{field, take?, match?, pending?, pool, label?, blank?}'
//
// A key shorter than `take`, or one `match` (an anchored JS source) rejects,
// is PENDING: `blank` is never written. pending "clear" (the default) clears
// the preview and writes "" to the label; "keep" leaves both untouched. The
// preview carries data-reactive-media-state = pending | hit | miss.
//
// happy-dom, so selectors and events are real.
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll, beforeEach, afterEach } from "bun:test"
import { Window } from "happy-dom"

const window = new Window()
let ReactiveController
const SAVED = {}
let warnings

beforeAll(async () => {
  mock.module("@hotwired/stimulus", () => ({ Controller: class {} }))
  ReactiveController = (await import("../../app/javascript/phlex/reactive/reactive_controller.js")).default
})

beforeEach(() => {
  for (const key of ["document", "window", "Event", "CustomEvent", "MutationObserver"]) SAVED[key] = globalThis[key]
  SAVED.warn = console.warn
  warnings = []
  console.warn = (...args) => warnings.push(args.join(" "))
  globalThis.document = window.document
  globalThis.window = window
  globalThis.Event = window.Event
  globalThis.CustomEvent = window.CustomEvent
  globalThis.MutationObserver = window.MutationObserver
  document.body.innerHTML = ""
})

afterEach(() => {
  console.warn = SAVED.warn
  delete SAVED.warn
  for (const [key, value] of Object.entries(SAVED)) globalThis[key] = value
})

const flush = () => new Promise((resolve) => setTimeout(resolve, 0))

const POOL = `<img id="bank-007" src="/banks/007.svg" alt="Attijariwafa" hidden>`

function media(wire) {
  return JSON.stringify(wire).replaceAll('"', "&quot;")
}

// The issue's RibPreview: take 3, a pool of one, a label and a blank_label.
const RIB = { field: "rib", take: 3, pool: { "007": "#bank-007" }, label: "#bank-name", blank: "Unknown bank" }

async function mount(wire, { value = "", logo = `alt=""` } = {}) {
  document.body.innerHTML = `<div id="r" data-controller="reactive" data-reactive-token-value="t">
    <input name="rib" value="${value}">
    <img id="bank-logo" ${logo} data-reactive-media="${media(wire)}"><span id="bank-name"></span>${POOL}</div>`
  const controller = new ReactiveController()
  controller.element = document.getElementById("r")
  controller.connect()
  await flush()
  return (sel) => document.querySelector(sel)
}

function type(input, value) {
  input.value = value
  input.dispatchEvent(new window.Event("input", { bubbles: true }))
}

const state = ($) => $("#bank-logo").getAttribute("data-reactive-media-state")

test("with take: 3, '', '0' and '00' never write blank_label", async () => {
  const $ = await mount(RIB)
  expect($("#bank-name").textContent).toBe("")
  expect(state($)).toBe("pending")

  for (const value of ["0", "00", ""]) {
    type($("[name=rib]"), value)
    expect($("#bank-name").textContent).toBe("")
    expect(state($)).toBe("pending")
  }
})

test("a full-length key that misses writes blank_label; '007' copies the pool image", async () => {
  const $ = await mount(RIB)

  type($("[name=rib]"), "009")
  expect($("#bank-name").textContent).toBe("Unknown bank")
  expect($("#bank-logo").hasAttribute("src")).toBe(false)
  expect(state($)).toBe("miss")

  type($("[name=rib]"), "007")
  expect($("#bank-logo").getAttribute("src")).toBe("/banks/007.svg")
  expect($("#bank-name").textContent).toBe("Attijariwafa")
  expect(state($)).toBe("hit")
})

test("pending (clear) after a hit clears the preview and empties the label", async () => {
  const $ = await mount(RIB, { value: "007" })
  expect(state($)).toBe("hit")

  type($("[name=rib]"), "00")
  expect($("#bank-logo").hasAttribute("src")).toBe(false)
  expect($("#bank-logo").getAttribute("alt")).toBe("")
  expect($("#bank-name").textContent).toBe("")
  expect(state($)).toBe("pending")
})

test("pending: keep leaves the preview and the label untouched", async () => {
  const $ = await mount({ ...RIB, pending: "keep" }, { value: "007" })
  expect($("#bank-name").textContent).toBe("Attijariwafa")

  type($("[name=rib]"), "0")
  expect($("#bank-logo").getAttribute("src")).toBe("/banks/007.svg")
  expect($("#bank-logo").getAttribute("alt")).toBe("Attijariwafa")
  expect($("#bank-name").textContent).toBe("Attijariwafa")
  expect(state($)).toBe("pending")
})

test("pending: keep at connect leaves a server-rendered preview alone", async () => {
  const $ = await mount({ ...RIB, pending: "keep" }, { logo: `src="/banks/old.svg" alt="Old"` })

  expect($("#bank-logo").getAttribute("src")).toBe("/banks/old.svg")
  expect(state($)).toBe("pending")
})

test("with match, a full-length key that fails the pattern is pending, not a miss", async () => {
  const $ = await mount({ ...RIB, match: "\\d{3}" })

  type($("[name=rib]"), "ab1")
  expect($("#bank-name").textContent).toBe("")
  expect(state($)).toBe("pending")

  type($("[name=rib]"), "009")
  expect($("#bank-name").textContent).toBe("Unknown bank")
  expect(state($)).toBe("miss")
})

test("match is anchored: a pattern that matches only part of the key is pending", async () => {
  const $ = await mount({ ...RIB, match: "\\d" })

  type($("[name=rib]"), "0a9")
  expect(state($)).toBe("pending")
  expect($("#bank-name").textContent).toBe("")
})

test("match applies to the whole value when take is omitted", async () => {
  const $ = await mount({ field: "rib", match: "\\d{3}", pool: { "007": "#bank-007" }, label: "#bank-name", blank: "Unknown bank" })

  type($("[name=rib]"), "7")
  expect(state($)).toBe("pending")
  type($("[name=rib]"), "0071")
  expect(state($)).toBe("pending")
  type($("[name=rib]"), "007")
  expect(state($)).toBe("hit")
})

test("without take or match there is no pending state: an empty value is a miss (unchanged)", async () => {
  const $ = await mount({ field: "rib", pool: { "007": "#bank-007" }, label: "#bank-name", blank: "Unknown bank" })

  expect(state($)).toBe("miss")
  expect($("#bank-name").textContent).toBe("Unknown bank")
})

test("a match that is not a valid JS pattern warns and skips the binding", async () => {
  const $ = await mount({ ...RIB, match: "(" }, { value: "007", logo: `src="/banks/old.svg" alt="Old"` })

  expect($("#bank-logo").getAttribute("src")).toBe("/banks/old.svg")
  expect($("#bank-logo").hasAttribute("data-reactive-media-state")).toBe(false)
  expect(warnings.some((w) => w.includes("malformed data-reactive-media"))).toBe(true)
})

test("take counts characters: one emoji of a take-2 key is pending", async () => {
  const $ = await mount({ field: "rib", take: 2, pool: { "🦊🦊": "#bank-007" }, label: "#bank-name", blank: "Unknown bank" })

  type($("[name=rib]"), "🦊")
  expect(state($)).toBe("pending")
  type($("[name=rib]"), "🦊🦊")
  expect(state($)).toBe("hit")
})

test("the state attribute is written only when it changes", async () => {
  const $ = await mount(RIB, { value: "0" })
  const logo = $("#bank-logo")
  const writes = []
  const set = logo.setAttribute.bind(logo)
  logo.setAttribute = (name, value) => {
    writes.push(name)
    set(name, value)
  }

  type($("[name=rib]"), "00")
  expect(writes).toEqual([])
})

test("a morph that strips the state attribute gets it back", async () => {
  const $ = await mount(RIB, { value: "0" })
  expect(state($)).toBe("pending")

  $("#bank-logo").removeAttribute("data-reactive-media-state")
  $("#r").dispatchEvent(new window.CustomEvent("turbo:morph-element", { bubbles: true }))
  expect(state($)).toBe("pending")
})

test("an unowned field writes no state", async () => {
  document.body.innerHTML = `<div id="r" data-controller="reactive" data-reactive-token-value="t">
    <img id="bank-logo" alt="" data-reactive-media="${media(RIB)}">${POOL}</div>`
  const controller = new ReactiveController()
  controller.element = document.getElementById("r")
  controller.connect()
  await flush()

  expect(document.querySelector("#bank-logo").hasAttribute("data-reactive-media-state")).toBe(false)
})
