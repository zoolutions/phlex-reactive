// Issue #392: reactive_image_fallback(wrap:) — hide the box around a broken
// img, not just the img.
//
//   data-reactive-image-fallback='{"hide":false,"wrap":"#badge"}'
//
// On `error` the wrapper (a selector resolved inside the img's own reactive
// root, like show_alt) is hidden and the hide marked as the runtime's own
// (data-reactive-wrap-hidden, shared with preview_file's wrap:). Recovery shows
// it again only when it carries that mark. The wrapper may hold the img, so
// nothing ever writes its text.
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll, beforeEach, afterEach, afterAll } from "bun:test"
import { Window } from "happy-dom"

let mod
let ReactiveController
const window = new Window()
const SAVED = {}
let originalDocument
let warnings

beforeAll(async () => {
  mock.module("@hotwired/stimulus", () => ({ Controller: class {} }))
  originalDocument = globalThis.document
  globalThis.document = window.document
  mod = await import("../../app/javascript/phlex/reactive/reactive_controller.js")
  ReactiveController = mod.default
  mod.__resetReactiveImageFallbackForTest()
  mod.registerReactiveImageFallback()
})

afterAll(() => {
  mod.__resetReactiveImageFallbackForTest()
  if (originalDocument === undefined) delete globalThis.document
  else globalThis.document = originalDocument
})

beforeEach(() => {
  for (const key of ["document", "window", "Event", "CustomEvent", "MutationObserver"]) SAVED[key] = globalThis[key]
  SAVED.warn = console.warn
  globalThis.document = window.document
  globalThis.window = window
  globalThis.Event = window.Event
  globalThis.CustomEvent = window.CustomEvent
  globalThis.MutationObserver = window.MutationObserver
  warnings = []
  console.warn = (...args) => warnings.push(args.join(" "))
  document.body.innerHTML = ""
})

afterEach(() => {
  console.warn = SAVED.warn
  delete SAVED.warn
  for (const [key, value] of Object.entries(SAVED)) {
    if (value === undefined) delete globalThis[key]
    else globalThis[key] = value
  }
})

const flush = () => new Promise((resolve) => setTimeout(resolve, 0))
const wire = (value) => JSON.stringify(value).replaceAll('"', "&quot;")

function mount(html) {
  document.body.insertAdjacentHTML("beforeend", `<div id="r" data-controller="reactive" data-reactive-token-value="t">${html}</div>`)
  const root = document.getElementById("r")
  const controller = new ReactiveController()
  controller.element = root
  return { root, controller, $: (sel) => document.querySelector(sel) }
}

const fail = (img) => img.dispatchEvent(new window.Event("error"))
const load = (img) => img.dispatchEvent(new window.Event("load"))
const state = (img) => img.getAttribute("data-reactive-image-state")

const BADGE = (fallback, attrs = "") =>
  `<span id="badge" class="rounded-full p-1"${attrs}><img id="logo" src="/missing.svg" alt="Bank" data-reactive-image-fallback="${wire(fallback)}"></span>`

test("wrap: hides the wrapper on error and marks the img", () => {
  const { $ } = mount(BADGE({ hide: false, wrap: "#badge" }))

  fail($("#logo"))

  expect(state($("#logo"))).toBe("error")
  expect($("#badge").hidden).toBe(true)
  expect($("#badge").hasAttribute("data-reactive-wrap-hidden")).toBe(true)
  expect($("#logo").hidden).toBe(false) // hide: false hides the wrapper only
})

test("a later src that loads shows the wrapper again and clears the state", () => {
  const { $ } = mount(BADGE({ hide: false, wrap: "#badge" }))
  fail($("#logo"))

  $("#logo").setAttribute("src", "/logos/007.svg")
  load($("#logo"))

  expect(state($("#logo"))).toBe("loaded")
  expect($("#badge").hidden).toBe(false)
  expect($("#badge").hasAttribute("data-reactive-wrap-hidden")).toBe(false)
})

test("recovery never removes hidden from a wrapper the author hid", () => {
  const { $ } = mount(BADGE({ hide: false, wrap: "#badge" }, " hidden"))

  fail($("#logo"))
  expect($("#badge").hasAttribute("data-reactive-wrap-hidden")).toBe(false)
  $("#logo").setAttribute("src", "/logos/007.svg")
  load($("#logo"))

  expect($("#badge").hidden).toBe(true)
})

test("a wrapper that contains the img is never given text", () => {
  // show_alt and wrap: on the same node: the alt node refuses it (it holds the
  // img), the wrapper only toggles hidden.
  const { $ } = mount(BADGE({ hide: false, wrap: "#badge", alt: "#badge" }))

  fail($("#logo"))

  expect($("#badge").querySelector("#logo")).not.toBeNull()
  expect($("#badge").textContent).toBe("")
})

test("wrap: and show_alt together: the wrapper hides, the alt node shows", () => {
  const { $ } = mount(`${BADGE({ hide: true, wrap: "#badge", alt: "#bank-name" })}<b id="bank-name" hidden></b>`)

  fail($("#logo"))

  expect($("#badge").hidden).toBe(true)
  expect($("#logo").hidden).toBe(true)
  expect($("#bank-name").hidden).toBe(false)
  expect($("#bank-name").textContent).toBe("Bank")
})

test("hide: true with no wrap: still hides only the img", () => {
  const { $ } = mount(BADGE({ hide: true }))

  fail($("#logo"))

  expect($("#logo").hidden).toBe(true)
  expect($("#badge").hidden).toBe(false)
})

test("a missing wrap: warns and skips the wrapper; the img fallback still runs", () => {
  const { $ } = mount(BADGE({ hide: true, wrap: "#nope" }))

  fail($("#logo"))

  expect(state($("#logo"))).toBe("error")
  expect($("#logo").hidden).toBe(true)
  expect(warnings.join("\n")).toContain("#nope")
})

test("wrap: resolves inside the img's own root, never the whole document", () => {
  document.body.innerHTML = `<span id="badge"></span>`
  const { $ } = mount(`<img id="logo" src="/missing.svg" alt="" data-reactive-image-fallback="${wire({ hide: false, wrap: "#badge" })}">`)

  fail($("#logo"))

  expect(document.getElementById("badge").hidden).toBe(false)
})

test("an invalid wrap: selector never throws", () => {
  const { $ } = mount(BADGE({ hide: true, wrap: "#[" }))

  fail($("#logo"))

  expect(state($("#logo"))).toBe("error")
})

test("a morph that keeps the broken src keeps the wrapper hidden", async () => {
  const fallback = { hide: false, wrap: "#badge" }
  const { $ } = mount(BADGE(fallback))
  fail($("#logo"))
  const img = $("#logo")
  const badge = $("#badge")

  img.dispatchEvent(new window.CustomEvent("turbo:before-morph-element", { detail: { newElement: img.cloneNode() } }))
  // The render carries neither hidden nor the mark: the morph strips both.
  badge.removeAttribute("hidden")
  badge.removeAttribute("data-reactive-wrap-hidden")
  img.removeAttribute("data-reactive-image-state")
  img.dispatchEvent(new window.CustomEvent("turbo:morph-element", { detail: {} }))
  await flush()

  expect(state(img)).toBe("error")
  expect(badge.hidden).toBe(true)
  expect(badge.hasAttribute("data-reactive-wrap-hidden")).toBe(true)
})
