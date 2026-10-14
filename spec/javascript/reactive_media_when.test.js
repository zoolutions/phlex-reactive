// Issue #390: reactive_media's `when` (an anchored JS source) is tested
// against the WHOLE field value, before the pool lookup, while the pool key
// stays the first `take` characters. A value it rejects is PENDING — even
// under pending "keep" — so blank_label never applies and a row hiding on
// data-reactive-media-state stays hidden. `match` still tests the key only.
//
//   data-reactive-media='{field, take?, match?, when?, pending?, pool, label?, blank?}'
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

const RIB = { field: "rib", take: 3, pool: { "007": "#bank-007" }, label: "#bank-name", blank: "Unknown bank" }
const WHEN = { ...RIB, when: "\\d{3,24}" }

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

test("a prefix that is a pool key but a whole value when rejects is pending, and copies nothing", async () => {
  const $ = await mount(WHEN)

  type($("[name=rib]"), "007bad")
  expect(state($)).toBe("pending")
  expect($("#bank-logo").hasAttribute("src")).toBe(false)
  expect($("#bank-name").textContent).toBe("")
})

test("a whole value when accepts is a hit on the prefix key", async () => {
  const $ = await mount(WHEN)

  type($("[name=rib]"), "007123")
  expect(state($)).toBe("hit")
  expect($("#bank-logo").getAttribute("src")).toBe("/banks/007.svg")
  expect($("#bank-name").textContent).toBe("Attijariwafa")
})

test("a whole value when accepts that misses the pool is a miss with blank_label", async () => {
  const $ = await mount(WHEN)

  type($("[name=rib]"), "009123")
  expect(state($)).toBe("miss")
  expect($("#bank-logo").hasAttribute("src")).toBe(false)
  expect($("#bank-name").textContent).toBe("Unknown bank")
})

test("when is anchored to the whole value", async () => {
  const $ = await mount({ ...RIB, when: "\\d+" })

  type($("[name=rib]"), "007a")
  expect(state($)).toBe("pending")
  type($("[name=rib]"), "0071")
  expect(state($)).toBe("hit")
})

test("a hit that turns into a when failure goes pending and clears the preview", async () => {
  const $ = await mount(WHEN, { value: "007123" })
  expect(state($)).toBe("hit")

  type($("[name=rib]"), "007123x")
  expect(state($)).toBe("pending")
  expect($("#bank-logo").hasAttribute("src")).toBe(false)
  expect($("#bank-name").textContent).toBe("")
})

test("under pending: keep, a when failure is pending and leaves the preview alone", async () => {
  const $ = await mount({ ...WHEN, pending: "keep" }, { value: "007123" })
  expect(state($)).toBe("hit")

  type($("[name=rib]"), "007bad")
  expect(state($)).toBe("pending")
  expect($("#bank-logo").getAttribute("src")).toBe("/banks/007.svg")
  expect($("#bank-name").textContent).toBe("Attijariwafa")
})

test("match without when still tests the key only: 007bad is a hit (issue #380 unchanged)", async () => {
  const $ = await mount({ ...RIB, match: "\\d{3}" })

  type($("[name=rib]"), "007bad")
  expect(state($)).toBe("hit")
  expect($("#bank-logo").getAttribute("src")).toBe("/banks/007.svg")
})

test("match and when together: the key must pass match and the whole value when", async () => {
  const $ = await mount({ ...WHEN, match: "\\d{3}" })

  type($("[name=rib]"), "ab1234")
  expect(state($)).toBe("pending")
  type($("[name=rib]"), "007bad")
  expect(state($)).toBe("pending")
  type($("[name=rib]"), "007123")
  expect(state($)).toBe("hit")
})

test("when applies with take omitted (the key is the whole value)", async () => {
  const $ = await mount({ field: "rib", when: "\\d{3}", pool: { "007": "#bank-007" }, label: "#bank-name", blank: "Unknown bank" })

  type($("[name=rib]"), "07")
  expect(state($)).toBe("pending")
  type($("[name=rib]"), "009")
  expect(state($)).toBe("miss")
  type($("[name=rib]"), "007")
  expect(state($)).toBe("hit")
})

test("a when that is not a valid JS pattern warns and skips the binding", async () => {
  const $ = await mount({ ...RIB, match: "\\d{3}", when: "(" }, { value: "007", logo: `src="/banks/old.svg" alt="Old"` })

  expect($("#bank-logo").getAttribute("src")).toBe("/banks/old.svg")
  expect($("#bank-logo").hasAttribute("data-reactive-media-state")).toBe(false)
  expect(warnings.some((w) => w.includes("malformed data-reactive-media"))).toBe(true)
})
