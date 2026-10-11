// Editable text (issue #351): a [data-reactive-editable] element — what
// reactive_editable renders — is a first-class plain-text field.
//
//   collect      its text, <br> / block boundaries as "\n", one trailing "\n"
//                dropped; a single-line field folds "\n" to spaces. A bare
//                named [contenteditable] keeps today's textContent (#8).
//   morph hold   focused (and without data-reactive-morph-value): the
//                element's attributes are copied from the render, its
//                children are left alone (text + caret survive), and the
//                render's text is remembered as the "server text". Unfocused:
//                the morph applies.
//   bindings     paste / drop insert plain text (natively where the engine
//                has contenteditable=plaintext-only; downgraded to "true" plus
//                a handler where it does not); Enter is swallowed in a
//                single-line field, runs on_enter ops, or submits; IME
//                composition is left alone; Escape reverts to the server text.
//   dirty        an editable is dirty when its text differs from its server text.
//   persist      the draft reads and restores through the same collector.
//
// happy-dom, so selectors, focus and events are real. `morph()` replays what
// Turbo 8 + Idiomorph do to ONE element: the cancelable before-morph-element,
// then (unless cancelled) its attributes and its children.
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll, beforeEach, afterEach } from "bun:test"
import { Window } from "happy-dom"

let mod
let bindings
let ReactiveController
const window = new Window()
const SAVED = {}

beforeAll(async () => {
  mock.module("@hotwired/stimulus", () => ({ Controller: class {} }))
  mod = await import("../../app/javascript/phlex/reactive/reactive_controller.js")
  ReactiveController = mod.default
  bindings = await import("../../app/javascript/phlex/reactive/features/bindings.js")
  mod.__resetReactiveMorphFocusForTest() // once: beforeEach registers on the shared window, no accumulation
})

beforeEach(() => {
  for (const key of ["document", "window", "Event", "CustomEvent", "MutationObserver", "localStorage"]) {
    SAVED[key] = globalThis[key]
  }
  globalThis.document = window.document
  globalThis.window = window
  globalThis.Event = window.Event
  globalThis.CustomEvent = window.CustomEvent
  globalThis.MutationObserver = window.MutationObserver
  document.body.innerHTML = ""
  mod.registerReactiveMorphFocus() // idempotent: the listener is added once (beforeAll)
  bindings.__setPlaintextOnlyForTest(true)
})

afterEach(() => {
  for (const [key, value] of Object.entries(SAVED)) globalThis[key] = value
  bindings.__setPlaintextOnlyForTest(undefined)
})

async function mount(html, { attrs = "" } = {}) {
  document.body.innerHTML = `<div id="r" data-controller="reactive" ${attrs}>${html}</div>`
  const root = document.getElementById("r")
  const controller = new ReactiveController()
  controller.element = root
  controller.connect()
  await controller.featuresReady
  return { root, controller, $: (sel) => root.querySelector(sel) }
}

function dispatch(name, target, detail) {
  const event = new window.CustomEvent(name, { bubbles: true, cancelable: true, detail })
  target.dispatchEvent(event)
  return !event.defaultPrevented
}

function morph(oldEl, html) {
  const holder = document.createElement("div")
  holder.innerHTML = html
  const newEl = holder.firstElementChild
  if (!dispatch("turbo:before-morph-element", oldEl, { currentElement: oldEl, newElement: newEl })) return
  for (const attr of [...oldEl.attributes]) if (!newEl.hasAttribute(attr.name)) oldEl.removeAttribute(attr.name)
  for (const attr of [...newEl.attributes]) oldEl.setAttribute(attr.name, attr.value)
  oldEl.replaceChildren(...newEl.childNodes)
}

function key(el, k, init = {}) {
  const event = new window.KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true, ...init })
  el.dispatchEvent(event)
  return event
}

function fire(el, type) {
  el.dispatchEvent(new window.Event(type, { bubbles: true }))
}

// Put the caret at `offset` inside the editable's first text node.
function caretAt(el, offset) {
  const range = document.createRange()
  range.setStart(el.firstChild, offset)
  range.collapse(true)
  const selection = document.getSelection()
  selection.removeAllRanges()
  selection.addRange(range)
  return selection
}

const SINGLE = `<h3 name="title" contenteditable="plaintext-only" role="textbox" data-reactive-editable="single" data-reactive-editable-escape="revert">Hello</h3>`
const MULTI = `<p name="summary" contenteditable="plaintext-only" role="textbox" data-reactive-editable="multi">one</p>`

// --- collect ------------------------------------------------------------------

test("a multiline editable posts its line breaks as \\n, minus one trailing newline", async () => {
  const { controller, $ } = await mount(MULTI)
  $("p").innerHTML = "one<br>two<div>three</div><div><br></div>"
  expect(await collect(controller)).toEqual({ summary: "one\ntwo\nthree\n" })
})

test("a blank line the browser makes (<div><br></div> between blocks) survives", async () => {
  const { controller, $ } = await mount(MULTI)
  $("p").innerHTML = "<div>a</div><div><br></div><div>b</div>"
  expect(await collect(controller)).toEqual({ summary: "a\n\nb" })
})

test("text nodes keep their own newlines and \\r\\n is normalised", async () => {
  const { controller, $ } = await mount(MULTI)
  $("p").textContent = "a\r\nb\n"
  expect(await collect(controller)).toEqual({ summary: "a\nb" })
})

test("a single-line editable folds line breaks to spaces", async () => {
  const { controller, $ } = await mount(SINGLE)
  $("h3").innerHTML = "Hello<br>world"
  expect(await collect(controller)).toEqual({ title: "Hello world" })
})

test("a bare named [contenteditable] keeps the textContent reading (#8)", async () => {
  const { controller, $ } = await mount(`<div name="raw" contenteditable="true">x</div>`)
  $("div").innerHTML = "a<br>b"
  expect(await collect(controller)).toEqual({ raw: "ab" })
})

// The params a request sends, observed through the POST body (#collectFields
// is private).
async function collect(controller) {
  let captured = null
  const realFetch = globalThis.fetch
  globalThis.fetch = (_path, opts) => {
    captured = JSON.parse(opts.body)
    return Promise.resolve({ redirected: false, ok: true, headers: { get: () => "" }, text: () => Promise.resolve("") })
  }
  try {
    controller.tokenValue = "tok"
    await controller.dispatch({ params: { action: "save", params: "{}" }, preventDefault: () => {} })
  } finally {
    globalThis.fetch = realFetch
  }
  return captured.params
}

// --- morph hold ---------------------------------------------------------------

test("a focused editable keeps its text and caret through a morph; its attributes still morph", async () => {
  const { $ } = await mount(SINGLE)
  const h3 = $("h3")
  h3.focus()
  h3.textContent = "Hello wor" // typed while the request was in flight
  const node = h3.firstChild
  caretAt(h3, 9)

  morph(h3, `<h3 name="title" contenteditable="plaintext-only" role="textbox" data-reactive-editable="single" data-reactive-editable-escape="revert" class="invalid" aria-invalid="true">Hello</h3>`)

  expect(h3.textContent).toBe("Hello wor")
  expect(h3.firstChild).toBe(node) // children untouched → the caret's node survives
  expect(document.getSelection().anchorOffset).toBe(9)
  expect(h3.getAttribute("class")).toBe("invalid")
  expect(h3.getAttribute("aria-invalid")).toBe("true")
})

test("a held editable drops an attribute the render no longer has, but keeps a downgraded contenteditable", async () => {
  bindings.__setPlaintextOnlyForTest(false)
  const { $ } = await mount(SINGLE.replace("<h3 ", '<h3 class="invalid" '))
  const h3 = $("h3")
  expect(h3.getAttribute("contenteditable")).toBe("true") // the fallback engine
  h3.focus()
  morph(h3, SINGLE)
  expect(h3.hasAttribute("class")).toBe(false)
  expect(h3.getAttribute("contenteditable")).toBe("true") // still editable mid-typing
})

test("an unfocused editable takes the render's text", async () => {
  const { $ } = await mount(SINGLE)
  const h3 = $("h3")
  h3.textContent = "local"
  morph(h3, SINGLE.replace("Hello", "Server"))
  expect(h3.textContent).toBe("Server")
})

test("data-reactive-morph-value lets the morph write a focused editable", async () => {
  const { $ } = await mount(SINGLE.replace("<h3 ", "<h3 data-reactive-morph-value "))
  const h3 = $("h3")
  h3.focus()
  h3.textContent = "typed"
  morph(h3, SINGLE.replace("<h3 ", "<h3 data-reactive-morph-value ").replace("Hello", "Server"))
  expect(h3.textContent).toBe("Server")
})

test("an editable outside every reactive root is not held", async () => {
  document.body.innerHTML = SINGLE
  const h3 = document.querySelector("h3")
  h3.focus()
  h3.textContent = "typed"
  morph(h3, SINGLE.replace("Hello", "Server"))
  expect(h3.textContent).toBe("Server")
})

// --- paste / drop -------------------------------------------------------------

function paste(el, text, type = "paste") {
  const data = { getData: (t) => (t === "text/plain" ? text : "<b>rich</b>") }
  const event = new window.Event(type, { bubbles: true, cancelable: true })
  event[type === "drop" ? "dataTransfer" : "clipboardData"] = data
  el.dispatchEvent(event)
  return event
}

function stubInsertText() {
  const inserted = []
  const real = document.execCommand
  document.execCommand = (command, _ui, value) => {
    inserted.push([command, value])
    return true
  }
  return { inserted, restore: () => (document.execCommand = real) }
}

test("where plaintext-only is missing, the editable is downgraded and paste inserts plain text", async () => {
  bindings.__setPlaintextOnlyForTest(false)
  const { $ } = await mount(MULTI)
  const stub = stubInsertText()
  try {
    const event = paste($("p"), "line 1\nline 2")
    expect(event.defaultPrevented).toBe(true)
    expect(stub.inserted).toEqual([["insertText", "line 1\nline 2"]])
  } finally {
    stub.restore()
  }
})

test("a drop of text is inserted as plain text in the fallback engine", async () => {
  bindings.__setPlaintextOnlyForTest(false)
  const { $ } = await mount(MULTI)
  const stub = stubInsertText()
  try {
    expect(paste($("p"), "dropped", "drop").defaultPrevented).toBe(true)
    expect(stub.inserted).toEqual([["insertText", "dropped"]])
  } finally {
    stub.restore()
  }
})

test("with native plaintext-only a multiline paste is left to the browser", async () => {
  const { $ } = await mount(MULTI)
  const stub = stubInsertText()
  try {
    expect(paste($("p"), "a\nb").defaultPrevented).toBe(false)
    expect(stub.inserted).toEqual([])
  } finally {
    stub.restore()
  }
})

test("a single-line field folds pasted line breaks to spaces even with native plaintext-only", async () => {
  const { $ } = await mount(SINGLE)
  const stub = stubInsertText()
  try {
    expect(paste($("h3"), "a\r\nb\nc").defaultPrevented).toBe(true)
    expect(stub.inserted).toEqual([["insertText", "a b c"]])
  } finally {
    stub.restore()
  }
})

// --- Enter / Escape -----------------------------------------------------------

test("Enter is swallowed in a single-line field and left alone in a multiline one", async () => {
  const { $ } = await mount(SINGLE + MULTI)
  expect(key($("h3"), "Enter").defaultPrevented).toBe(true)
  expect(key($("p"), "Enter").defaultPrevented).toBe(false)
})

test("Enter runs on_enter ops (root-scoped), and Shift+Enter keeps a newline in a multiline field", async () => {
  const ops = JSON.stringify([["add_class", { to: "#flag", classes: ["entered"] }]]).replaceAll('"', "&quot;")
  const { $ } = await mount(
    `<span id="flag"></span>` + MULTI.replace("<p ", `<p data-reactive-editable-enter="${ops}" `),
  )
  expect(key($("p"), "Enter", { shiftKey: true }).defaultPrevented).toBe(false)
  expect($("#flag").classList.contains("entered")).toBe(false)
  expect(key($("p"), "Enter").defaultPrevented).toBe(true)
  expect($("#flag").classList.contains("entered")).toBe(true)
})

test("on_enter: :submit request-submits the field's form", async () => {
  const { $ } = await mount(`<form>${SINGLE.replace("<h3 ", '<h3 data-reactive-editable-enter="submit" ')}</form>`)
  let submitted = 0
  $("form").requestSubmit = () => submitted++
  key($("h3"), "Enter")
  expect(submitted).toBe(1)
})

test("Enter during IME composition is left alone", async () => {
  const { $ } = await mount(SINGLE)
  expect(key($("h3"), "Enter", { isComposing: true }).defaultPrevented).toBe(false)
})

test("Escape restores the last server-rendered text, announces it and blurs", async () => {
  const { root, $ } = await mount(SINGLE)
  const h3 = $("h3")
  h3.focus()
  morph(h3, SINGLE.replace("Hello", "Hello there")) // held: the server text advances
  h3.textContent = "Hello there, typo"
  const inputs = []
  root.addEventListener("input", (e) => inputs.push(e.target))
  expect(key(h3, "Escape").defaultPrevented).toBe(true)
  expect(h3.textContent).toBe("Hello there")
  expect(inputs).toEqual([h3])
  expect(document.activeElement).not.toBe(h3)
})

test("Escape does nothing without on_escape: :revert", async () => {
  const { $ } = await mount(MULTI)
  $("p").textContent = "typed"
  expect(key($("p"), "Escape").defaultPrevented).toBe(false)
  expect($("p").textContent).toBe("typed")
})

test("a field emptied by the user drops the browser's leftover <br>, so :empty can draw the placeholder", async () => {
  const { $ } = await mount(SINGLE.replace("<h3 ", '<h3 data-reactive-placeholder="Untitled" '))
  const h3 = $("h3")
  h3.innerHTML = "<br>"
  fire(h3, "input")
  expect(h3.childNodes.length).toBe(0)
})

test("a nested root's editable is its own: the parent does not handle its keys", async () => {
  const { $ } = await mount(`<div data-controller="reactive" id="inner">${SINGLE}</div>`)
  // Only the parent is connected here; the nested editable is not its to handle.
  expect(key($("h3"), "Enter").defaultPrevented).toBe(false)
})

// --- an editable a stream adds later ----------------------------------------------

test("a root without bindings loads them when a stream-appended editable is first focused", async () => {
  const { root, controller } = await mount(`<p>no bindings yet</p>`, { attrs: 'data-reactive-token-value="t"' })
  root.insertAdjacentHTML("beforeend", SINGLE)
  const h3 = root.querySelector("h3")
  h3.dispatchEvent(new window.FocusEvent("focusin", { bubbles: true }))
  await controller.featuresReady
  expect(key(h3, "Enter").defaultPrevented).toBe(true)
})

test("a root whose bindings connected for another marker handles a later editable's keys", async () => {
  const show = JSON.stringify({ field: "mode", op: "eq", value: "a" })
  const { root } = await mount(`<input name="mode" value="a"><p data-reactive-show='${show}'>x</p>`)
  root.insertAdjacentHTML("beforeend", SINGLE)
  expect(key(root.querySelector("h3"), "Enter").defaultPrevented).toBe(true)
})

// --- dirty --------------------------------------------------------------------

test("reactive_dirty marks an editable whose text differs from its server text", async () => {
  const { root, controller, $ } = await mount(SINGLE, { attrs: 'data-action="input->reactive#trackDirty"' })
  const h3 = $("h3")
  expect(root.hasAttribute("data-reactive-dirty")).toBe(false)
  h3.textContent = "Changed"
  controller.trackDirty()
  expect(h3.getAttribute("data-reactive-dirty")).toBe("true")
  expect(root.getAttribute("data-reactive-dirty")).toBe("1")

  h3.focus()
  morph(h3, SINGLE.replace("Hello", "Changed")) // the save landed: the server text caught up
  controller.trackDirty()
  expect(h3.hasAttribute("data-reactive-dirty")).toBe(false)
  expect(root.hasAttribute("data-reactive-dirty")).toBe(false)
})

// --- persist ------------------------------------------------------------------

function storage() {
  const map = new Map()
  return {
    getItem: (k) => (map.has(k) ? map.get(k) : null),
    setItem: (k, v) => map.set(k, String(v)),
    removeItem: (k) => map.delete(k),
    json: (k) => JSON.parse(map.get(k)),
    seed: (k, v) => map.set(k, JSON.stringify(v)),
  }
}

const PERSIST = `data-reactive-persist='${JSON.stringify({ key: "card", ttl: 60, debounce: 300 })}'`
const KEY = "phlex-reactive:persist:card"

test("persist drafts an editable's line breaks and restores them", async () => {
  const store = storage()
  globalThis.localStorage = store
  const { $ } = await mount(MULTI.replace(">one<", "><"), { attrs: PERSIST })
  $("p").innerHTML = "line 1<br>line 2"
  fire($("p"), "change")
  expect(store.json(KEY).fields).toEqual({ summary: "line 1\nline 2" })

  const second = await mount(MULTI.replace(">one<", "><"), { attrs: PERSIST })
  expect(second.$("p").textContent).toBe("line 1\nline 2")
})

test("a restored editable counts as changed against its server text", async () => {
  const store = storage()
  globalThis.localStorage = store
  store.seed(KEY, { v: 1, savedAt: Date.now() - 1000, fields: { summary: "draft" } })
  const { root, controller, $ } = await mount(MULTI.replace(">one<", "><"), {
    attrs: `${PERSIST} data-action="input->reactive#trackDirty"`,
  })
  expect($("p").textContent).toBe("draft")
  controller.trackDirty()
  expect(root.getAttribute("data-reactive-dirty")).toBe("1")
})
