// Issue #383: an image fallback that recovers when its src changes.
//
//   data-reactive-image-fallback='{"hide":true,"alt":"#name"}'
//
// One document-level, capture-phase listener (registerReactiveImageFallback)
// sees every <img> `error` and `load` — neither bubbles. On `error` a marked
// img gets data-reactive-image-state="error" (and `hidden` with hide:, and its
// alt written into the `alt` node, which is shown). On `load` it gets
// "loaded". copy_media and preview_file reset the state themselves when they
// change the src; a morph that keeps the src keeps the state; one that
// changes it lets the browser try again. An error with no src is not an error.
//
// happy-dom loads no images, so `error`/`load` are dispatched by hand, and
// the registration sweep reads `complete`/`naturalWidth` defined per element.
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll, beforeEach, afterEach, afterAll } from "bun:test"
import { Window } from "happy-dom"

let mod
let ReactiveController
const window = new Window()
const SAVED = {}
let originalDocument

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
  SAVED.createObjectURL = URL.createObjectURL
  SAVED.revokeObjectURL = URL.revokeObjectURL
  globalThis.document = window.document
  globalThis.window = window
  globalThis.Event = window.Event
  globalThis.CustomEvent = window.CustomEvent
  globalThis.MutationObserver = window.MutationObserver
  URL.createObjectURL = () => "blob:test/1"
  URL.revokeObjectURL = () => {}
  document.body.innerHTML = ""
})

afterEach(() => {
  mod.__resetReactivePreviewsForTest()
  URL.createObjectURL = SAVED.createObjectURL
  URL.revokeObjectURL = SAVED.revokeObjectURL
  delete SAVED.createObjectURL
  delete SAVED.revokeObjectURL
  for (const [key, value] of Object.entries(SAVED)) {
    if (value === undefined) delete globalThis[key]
    else globalThis[key] = value
  }
})

const flush = () => new Promise((resolve) => setTimeout(resolve, 0))

const wire = (value) => JSON.stringify(value).replaceAll('"', "&quot;")
const HIDE = wire({ hide: true })

function mount(html, { connect = false } = {}) {
  document.body.insertAdjacentHTML("beforeend", `<div id="r" data-controller="reactive" data-reactive-token-value="t">${html}</div>`)
  const root = document.getElementById("r")
  const controller = new ReactiveController()
  controller.element = root
  if (connect) controller.connect()
  return { root, controller, $: (sel) => document.querySelector(sel) }
}

function run(controller, ops) {
  controller.runOps({ params: { ops }, target: controller.element, preventDefault() {} })
}

// What the browser does when an img's request ends. Neither event bubbles.
const fail = (img) => img.dispatchEvent(new window.Event("error"))
const load = (img) => img.dispatchEvent(new window.Event("load"))
const state = (img) => img.getAttribute("data-reactive-image-state")

// happy-dom fires `error` SYNCHRONOUSLY when a src is set (it loads nothing);
// a browser fires it later, in its own task. Swallow those fake events while
// fn runs (window capture runs before the runtime's document capture).
function quietly(fn) {
  const stop = (event) => event.stopImmediatePropagation()
  window.addEventListener("error", stop, true)
  window.addEventListener("load", stop, true)
  try {
    fn()
  } finally {
    window.removeEventListener("error", stop, true)
    window.removeEventListener("load", stop, true)
  }
}

// Turbo 8 + Idiomorph on ONE element: turbo:before-morph-element (with the new
// render), the attributes synced from the render, then turbo:morph-element.
function morph(el, html) {
  const holder = document.createElement("div")
  holder.innerHTML = html
  const next = holder.firstElementChild
  el.dispatchEvent(new window.CustomEvent("turbo:before-morph-element", { bubbles: true, cancelable: true, detail: { newElement: next } }))
  quietly(() => {
    for (const { name } of [...el.attributes]) if (!next.hasAttribute(name)) el.removeAttribute(name)
    for (const { name, value } of next.attributes) if (el.getAttribute(name) !== value) el.setAttribute(name, value)
  })
  el.dispatchEvent(new window.CustomEvent("turbo:morph-element", { bubbles: true, detail: { currentElement: el, newElement: next } }))
}

// --- error and load -----------------------------------------------------------

test("an img whose src fails is marked error and hidden (hide: true)", () => {
  const { $ } = mount(`<img id="logo" src="/missing.svg" alt="Broken" data-reactive-image-fallback="${HIDE}">`)

  fail($("#logo"))

  expect(state($("#logo"))).toBe("error")
  expect($("#logo").hidden).toBe(true)
})

test("hide: false marks the state only, for CSS to style", () => {
  const { $ } = mount(`<img id="logo" src="/missing.svg" alt="" data-reactive-image-fallback="${wire({ hide: false })}">`)

  fail($("#logo"))

  expect(state($("#logo"))).toBe("error")
  expect($("#logo").hidden).toBe(false)
})

test("a load marks it loaded", () => {
  const { $ } = mount(`<img id="logo" src="/logos/007.svg" alt="" data-reactive-image-fallback="${HIDE}">`)

  load($("#logo"))

  expect(state($("#logo"))).toBe("loaded")
  expect($("#logo").hidden).toBe(false)
})

test("a load after an error (any later src that loads) shows it again", () => {
  const { $ } = mount(`<img id="logo" src="/missing.svg" alt="" data-reactive-image-fallback="${HIDE}">`)
  fail($("#logo"))

  $("#logo").setAttribute("src", "/logos/007.svg")
  load($("#logo"))

  expect(state($("#logo"))).toBe("loaded")
  expect($("#logo").hidden).toBe(false)
})

test("an img without the marker is left alone", () => {
  const { $ } = mount(`<img id="logo" src="/missing.svg" alt="">`)

  fail($("#logo"))

  expect($("#logo").hasAttribute("data-reactive-image-state")).toBe(false)
  expect($("#logo").hidden).toBe(false)
})

test("an error with no src (removed, or empty) is not an error", () => {
  const { $ } = mount(`<img id="a" alt="" data-reactive-image-fallback="${HIDE}"><img id="b" src="" alt="" data-reactive-image-fallback="${HIDE}">`)

  fail($("#a"))
  fail($("#b"))

  for (const img of [$("#a"), $("#b")]) {
    expect(img.hasAttribute("data-reactive-image-state")).toBe(false)
    expect(img.hidden).toBe(false)
  }
})

test("a malformed marker never throws: the img is marked, nothing else", () => {
  const { $ } = mount(`<img id="logo" src="/missing.svg" alt="" data-reactive-image-fallback="{nope">`)

  expect(() => fail($("#logo"))).not.toThrow()
  expect(state($("#logo"))).toBe("error")
  expect($("#logo").hidden).toBe(false)
})

test("an author's own hidden survives a reset: only the hidden the fallback set is undone", () => {
  const { controller, $ } = mount(
    `<img id="logo" src="/logos/007.svg" alt="" hidden data-reactive-image-fallback="${HIDE}"><img id="other" src="/logos/011.svg" alt="South" hidden>`,
  )
  load($("#logo"))

  run(controller, [["copy_media", { to: "#logo", from: "#other" }]])

  expect($("#logo").hidden).toBe(true)
})

// --- show_alt -------------------------------------------------------------------

test("show_alt: the alt node shows the img's alt on error, and hides again when the src changes", () => {
  const ALT = wire({ hide: true, alt: "#bank-name" })
  const { controller, $ } = mount(
    `<img id="logo" src="/missing.svg" alt="Broken Bank" data-reactive-image-fallback="${ALT}">` +
      `<span id="bank-name" hidden></span><img id="bank-007" src="/banks/007.svg" alt="Attijariwafa" hidden>`,
  )

  fail($("#logo"))
  expect($("#bank-name").hidden).toBe(false)
  expect($("#bank-name").textContent).toBe("Broken Bank")

  run(controller, [["copy_media", { to: "#logo", from: "#bank-007" }]])
  expect($("#bank-name").hidden).toBe(true)
  expect($("#logo").hidden).toBe(false)
})

test("show_alt resolves inside the img's own reactive root, never the whole document", () => {
  const ALT = wire({ hide: true, alt: "#bank-name" })
  document.body.innerHTML = `<span id="bank-name" hidden>outside</span>`
  const { $ } = mount(`<img id="logo" src="/missing.svg" alt="Broken" data-reactive-image-fallback="${ALT}">`)

  fail($("#logo"))

  expect(document.getElementById("bank-name").hidden).toBe(true)
  expect(document.getElementById("bank-name").textContent).toBe("outside")
})

// --- a later src recovers -------------------------------------------------------

test("copy_media onto a broken img clears the error and shows it", () => {
  const { controller, $ } = mount(
    `<img id="logo" src="/banks/missing.svg" alt="" data-reactive-image-fallback="${HIDE}">` +
      `<img id="bank-007" src="/banks/007.svg" alt="Attijariwafa" hidden>`,
  )
  fail($("#logo"))

  run(controller, [["copy_media", { to: "#logo", from: "#bank-007" }]])

  expect($("#logo").getAttribute("src")).toBe("/banks/007.svg")
  expect($("#logo").hasAttribute("data-reactive-image-state")).toBe(false)
  expect($("#logo").hidden).toBe(false)
})

test("copy_media that clears the src (a missing source) clears the error, and nothing marks it again", () => {
  const { controller, $ } = mount(`<img id="logo" src="/banks/missing.svg" alt="" data-reactive-image-fallback="${HIDE}">`)
  fail($("#logo"))

  run(controller, [["copy_media", { to: "#logo", from: "#nope" }]])
  fail($("#logo")) // a browser may report the emptied request

  expect($("#logo").hasAttribute("src")).toBe(false)
  expect($("#logo").hasAttribute("data-reactive-image-state")).toBe(false)
  expect($("#logo").hidden).toBe(false)
})

test("copy_media of the same URL keeps the state: the image does not reload", () => {
  const { controller, $ } = mount(
    `<img id="logo" src="/banks/missing.svg" alt="" data-reactive-image-fallback="${HIDE}">` +
      `<img id="same" src="/banks/missing.svg" alt="" hidden>`,
  )
  fail($("#logo"))

  run(controller, [["copy_media", { to: "#logo", from: "#same" }]])

  expect(state($("#logo"))).toBe("error")
  expect($("#logo").hidden).toBe(true)
})

test("reactive_media: a key whose image breaks hides the preview, the next key shows it", async () => {
  const MEDIA = wire({ field: "rib", take: 3, pool: { "001": "#bank-001", "007": "#bank-007" } })
  const { $ } = mount(
    `<input name="rib"><img id="logo" alt="" data-reactive-media="${MEDIA}" data-reactive-image-fallback="${HIDE}">` +
      `<img id="bank-001" src="/banks/missing.svg" alt="Broken" hidden><img id="bank-007" src="/banks/007.svg" alt="Attijariwafa" hidden>`,
    { connect: true },
  )
  await flush()
  const type = (value) => {
    $("[name=rib]").value = value
    $("[name=rib]").dispatchEvent(new window.Event("input", { bubbles: true }))
  }

  type("001")
  fail($("#logo"))
  expect($("#logo").hidden).toBe(true)

  type("007")
  expect($("#logo").getAttribute("src")).toBe("/banks/007.svg")
  expect($("#logo").hidden).toBe(false)
  expect($("#logo").hasAttribute("data-reactive-image-state")).toBe(false)
})

test("preview_file onto a broken img clears the error and shows it", () => {
  const { controller, $ } = mount(
    `<input type="file" id="photo-file"><img id="photo" src="/missing.png" alt="" data-reactive-image-fallback="${HIDE}">`,
  )
  fail($("#photo"))
  Object.defineProperty($("#photo-file"), "files", { value: [new File(["png"], "a.png", { type: "image/png" })], configurable: true })

  run(controller, [["preview_file", { to: "#photo-file", into: "#photo" }]])

  expect($("#photo").getAttribute("src")).toBe("blob:test/1")
  expect($("#photo").hasAttribute("data-reactive-image-state")).toBe(false)
  expect($("#photo").hidden).toBe(false)
})

test("preview_file of a non-image clears the src and the error", () => {
  const { controller, $ } = mount(
    `<input type="file" id="photo-file"><img id="photo" src="/missing.png" alt="" data-reactive-image-fallback="${HIDE}">`,
  )
  fail($("#photo"))
  Object.defineProperty($("#photo-file"), "files", { value: [new File(["t"], "a.txt", { type: "text/plain" })], configurable: true })

  run(controller, [["preview_file", { to: "#photo-file", into: "#photo" }]])

  expect($("#photo").hasAttribute("src")).toBe(false)
  expect($("#photo").hasAttribute("data-reactive-image-state")).toBe(false)
  expect($("#photo").hidden).toBe(false)
})

// --- morphs -----------------------------------------------------------------------

test("a morph to a new src clears the error: the browser tries the new one", async () => {
  const { $ } = mount(`<img id="logo" src="/missing.svg" alt="" data-reactive-image-fallback="${HIDE}">`)
  fail($("#logo"))

  morph($("#logo"), `<img id="logo" src="/logos/007.svg" alt="" data-reactive-image-fallback="${HIDE}">`)
  await flush()

  expect($("#logo").hasAttribute("data-reactive-image-state")).toBe(false)
  expect($("#logo").hidden).toBe(false)
})

test("a morph that keeps a broken src keeps it hidden and marked", async () => {
  const ALT = wire({ hide: true, alt: "#name" })
  const { $ } = mount(`<img id="logo" src="/missing.svg" alt="Broken" data-reactive-image-fallback="${ALT}"><span id="name" hidden></span>`)
  fail($("#logo"))

  morph($("#logo"), `<img id="logo" src="/missing.svg" alt="Broken" data-reactive-image-fallback="${ALT}">`)
  morph($("#name"), `<span id="name" hidden></span>`)
  await flush()

  expect(state($("#logo"))).toBe("error")
  expect($("#logo").hidden).toBe(true)
  expect($("#name").hidden).toBe(false)
  expect($("#name").textContent).toBe("Broken")
})

test("a morph that keeps a loaded src keeps it marked loaded", async () => {
  const { $ } = mount(`<img id="logo" src="/logos/007.svg" alt="" data-reactive-image-fallback="${HIDE}">`)
  load($("#logo"))

  morph($("#logo"), `<img id="logo" src="/logos/007.svg" alt="" data-reactive-image-fallback="${HIDE}">`)
  await flush()

  expect(state($("#logo"))).toBe("loaded")
})

// --- an image that broke before the runtime registered ---------------------------

test("registration marks an img that already failed, and one that already loaded", async () => {
  document.body.innerHTML =
    `<img id="broken" src="/missing.svg" alt="" data-reactive-image-fallback="${HIDE}">` +
    `<img id="fine" src="/logos/007.svg" alt="" data-reactive-image-fallback="${HIDE}">` +
    `<img id="pending" src="/slow.svg" alt="" data-reactive-image-fallback="${HIDE}">`
  const define = (id, complete, naturalWidth) => {
    const img = document.getElementById(id)
    Object.defineProperty(img, "complete", { value: complete, configurable: true })
    Object.defineProperty(img, "naturalWidth", { value: naturalWidth, configurable: true })
    return img
  }
  const broken = define("broken", true, 0)
  broken.decode = () => Promise.reject(new Error("EncodingError"))
  const fine = define("fine", true, 64)
  const pending = define("pending", false, 0)

  mod.__resetReactiveImageFallbackForTest()
  mod.registerReactiveImageFallback()
  await flush()

  expect(state(broken)).toBe("error")
  expect(broken.hidden).toBe(true)
  expect(state(fine)).toBe("loaded")
  expect(pending.hasAttribute("data-reactive-image-state")).toBe(false)
})

test("registration asks decode() before calling a complete img with naturalWidth 0 broken (a viewBox-only SVG)", async () => {
  document.body.innerHTML =
    `<img id="svg" src="/logos/viewbox.svg" alt="" data-reactive-image-fallback="${HIDE}">` +
    `<img id="broken" src="/missing.svg" alt="" data-reactive-image-fallback="${HIDE}">`
  const define = (id, decodes) => {
    const img = document.getElementById(id)
    Object.defineProperty(img, "complete", { value: true, configurable: true })
    Object.defineProperty(img, "naturalWidth", { value: 0, configurable: true })
    img.decode = () => (decodes ? Promise.resolve() : Promise.reject(new Error("EncodingError")))
    return img
  }
  const svg = define("svg", true)
  const broken = define("broken", false)

  mod.__resetReactiveImageFallbackForTest()
  mod.registerReactiveImageFallback()
  await flush()

  expect(state(svg)).toBe("loaded")
  expect(svg.hidden).toBe(false)
  expect(state(broken)).toBe("error")
  expect(broken.hidden).toBe(true)
})

test("a sweep decode() that rejects after the src was removed does not mark an error", async () => {
  document.body.innerHTML = `<img id="logo" src="/missing.svg" alt="" data-reactive-image-fallback="${HIDE}">`
  const img = document.getElementById("logo")
  Object.defineProperty(img, "complete", { value: true, configurable: true })
  Object.defineProperty(img, "naturalWidth", { value: 0, configurable: true })
  img.decode = () => Promise.reject(new Error("EncodingError"))

  mod.__resetReactiveImageFallbackForTest()
  mod.registerReactiveImageFallback()
  img.removeAttribute("src")
  await flush()

  expect(img.hasAttribute("data-reactive-image-state")).toBe(false)
  expect(img.hidden).toBe(false)
})

test("an img restored from a snapshot (hidden + error already in the DOM) is shown again by a new src", () => {
  // A Turbo restoration visit hands back a NEW element carrying what the
  // fallback wrote — its hidden must still be undoable.
  const { controller, $ } = mount(
    `<img id="logo" src="/missing.svg" alt="" hidden data-reactive-image-hidden data-reactive-image-state="error" data-reactive-image-fallback="${HIDE}">` +
      `<img id="bank-007" src="/banks/007.svg" alt="Attijariwafa" hidden>`,
  )
  fail($("#logo")) // the browser re-fires error for the restored node

  run(controller, [["copy_media", { to: "#logo", from: "#bank-007" }]])

  expect($("#logo").hidden).toBe(false)
  expect($("#logo").hasAttribute("data-reactive-image-hidden")).toBe(false)
})

test("a show_alt node that contains the img is never written (it would wipe the img)", () => {
  const ALT = wire({ hide: true, alt: ".wrap" })
  const { $ } = mount(`<div class="wrap"><img id="logo" src="/missing.svg" alt="Broken" data-reactive-image-fallback="${ALT}"></div>`)

  fail($("#logo"))

  expect($("#logo")).not.toBeNull()
  expect(state($("#logo"))).toBe("error")
})

test("registering twice adds one listener", () => {
  const { $ } = mount(`<img id="logo" src="/missing.svg" alt="Broken" data-reactive-image-fallback="${wire({ hide: false, alt: "#n" })}"><span id="n" hidden></span>`)
  mod.registerReactiveImageFallback()
  let writes = 0
  const set = $("#logo").setAttribute.bind($("#logo"))
  $("#logo").setAttribute = (name, value) => {
    if (name === "data-reactive-image-state") writes++
    set(name, value)
  }

  fail($("#logo"))

  expect(writes).toBe(1)
})
