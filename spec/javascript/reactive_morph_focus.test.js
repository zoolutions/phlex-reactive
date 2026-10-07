// Issue #338: a morph keeps the focused field's value. Turbo's stream morph
// (reply.morph, a broadcast morph) runs Idiomorph WITHOUT ignoreActiveValue, so
// the field being typed in was overwritten by the server's (normalised or
// stale) value. The runtime installs one document-level pair of listeners:
//
//   turbo:before-morph-element   — the focused field's DEFAULT (its `value`
//                                  attribute) is written from the new render,
//                                  so dirty tracking still sees the fresh default
//   turbo:before-morph-attribute — `value` on that field is cancelled, which
//                                  Idiomorph honours for the attribute AND the
//                                  `value` property (syncInputValue)
//
// Only inside a reactive root, only the focused field, only `value`, and never
// when the field opts out with data-reactive-morph-value.
//
// `morph()` below replays what Turbo 8 + Idiomorph do to ONE element, in their
// order (the vendored turbo.js and turbo-rails 2.0.23 agree): the cancelable
// before-morph-element, then a before-morph-attribute per attribute (asked
// BEFORE the equality check), then syncInputValue's value write, again asked.
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeEach } from "bun:test"
import { Window } from "happy-dom"

let registerReactiveMorphFocus
let __resetReactiveMorphFocusForTest
let window

beforeEach(async () => {
  mock.module("@hotwired/stimulus", () => ({ Controller: class {} }))
  ;({ registerReactiveMorphFocus, __resetReactiveMorphFocusForTest } = await import(
    "../../app/javascript/phlex/reactive/reactive_controller.js"
  ))
  window = new Window()
  globalThis.document = window.document
  __resetReactiveMorphFocusForTest()
  registerReactiveMorphFocus()
})

function dispatch(name, target, detail) {
  const event = new window.CustomEvent(name, { bubbles: true, cancelable: true, detail })
  target.dispatchEvent(event)
  return !event.defaultPrevented
}

const asked = []
function allowed(attributeName, target, mutationType) {
  const ok = dispatch("turbo:before-morph-attribute", target, { attributeName, mutationType })
  asked.push({ attributeName, ok })
  return ok
}

// Idiomorph's morphNode for an input/textarea, as Turbo drives it.
function morph(oldEl, html) {
  asked.length = 0
  const holder = document.createElement("div")
  holder.innerHTML = html
  const newEl = holder.firstElementChild
  if (!dispatch("turbo:before-morph-element", oldEl, { currentElement: oldEl, newElement: newEl })) return
  for (const attr of [...newEl.attributes]) {
    if (!allowed(attr.name, oldEl, "update")) continue
    if (oldEl.getAttribute(attr.name) !== attr.value) oldEl.setAttribute(attr.name, attr.value)
  }
  for (const attr of [...oldEl.attributes]) {
    if (newEl.hasAttribute(attr.name)) continue
    if (!allowed(attr.name, oldEl, "remove")) continue
    oldEl.removeAttribute(attr.name)
  }
  if (oldEl.localName === "input") {
    if (!newEl.hasAttribute("value")) {
      if (allowed("value", oldEl, "remove")) {
        oldEl.value = ""
        oldEl.removeAttribute("value")
      }
    } else if (oldEl.value !== newEl.value && allowed("value", oldEl, "update")) {
      oldEl.setAttribute("value", newEl.value)
      oldEl.value = newEl.value
    }
  } else if (oldEl.localName === "textarea" && allowed("value", oldEl, "update")) {
    if (oldEl.value !== newEl.value) oldEl.value = newEl.value
    if (oldEl.firstChild && oldEl.firstChild.nodeValue !== newEl.value) oldEl.firstChild.nodeValue = newEl.value
  }
  // morphChildren runs after, whatever the cancel: a textarea's text child (its
  // default) is morphed like any text node.
  if (oldEl.localName === "textarea" && oldEl.firstChild && oldEl.firstChild.nodeValue !== newEl.textContent) {
    oldEl.firstChild.nodeValue = newEl.textContent
  }
}

function mount(html) {
  document.body.innerHTML = html
}

function type(field, text) {
  field.focus()
  field.value = text // sets the dirty-value flag, as typing does
}

test("the focused input in a reactive root keeps what was typed; its default advances", () => {
  mount(`<div data-controller="reactive"><input name="name" value="old"></div>`)
  const field = document.querySelector("input")
  type(field, "Hello ")

  morph(field, `<input name="name" value="Hello">`)

  expect(field.value).toBe("Hello ")
  expect(field.defaultValue).toBe("Hello") // dirty tracking diffs against this
  expect(asked.filter((a) => a.attributeName === "value").every((a) => !a.ok)).toBe(true)
})

test("an echo of exactly what was typed leaves the focused field clean (default = value)", () => {
  mount(`<div data-controller="reactive"><input name="name" value="old"></div>`)
  const field = document.querySelector("input")
  type(field, "abc")

  morph(field, `<input name="name" value="abc">`)

  expect(field.value).toBe("abc")
  expect(field.defaultValue).toBe("abc")
})

test("a render without a value attribute drops the default but keeps what was typed", () => {
  mount(`<div data-controller="reactive"><input name="name" value="old"></div>`)
  const field = document.querySelector("input")
  type(field, "typed")

  morph(field, `<input name="name">`)

  expect(field.value).toBe("typed")
  expect(field.hasAttribute("value")).toBe(false)
})

test("an unfocused input in the same root takes the server's value", () => {
  mount(`<div data-controller="reactive"><input name="name" value="old"><input name="slug" value="old"></div>`)
  const [name, slug] = document.querySelectorAll("input")
  type(name, "Hello ")
  slug.value = "stale" // edited earlier, no longer focused

  morph(slug, `<input name="slug" value="hello">`)

  expect(slug.value).toBe("hello")
  expect(slug.defaultValue).toBe("hello")
  expect(asked.every((a) => a.ok)).toBe(true)
})

test("a focused input outside any reactive root is left to Turbo", () => {
  mount(`<div><input name="q" value="old"></div>`)
  const field = document.querySelector("input")
  type(field, "Hello ")

  morph(field, `<input name="q" value="Hello">`)

  expect(field.value).toBe("Hello")
  expect(asked.every((a) => a.ok)).toBe(true)
})

test("only `value` is held: every other attribute of the focused field still morphs", () => {
  mount(`<div data-controller="reactive"><input name="name" value="old" class="a" aria-invalid="false" data-reactive-token-value="t1"></div>`)
  const field = document.querySelector("input")
  type(field, "Hello ")

  morph(field, `<input name="name" value="Hello" class="b" data-reactive-token-value="t2">`)

  expect(field.value).toBe("Hello ")
  expect(field.className).toBe("b")
  expect(field.getAttribute("data-reactive-token-value")).toBe("t2")
  expect(field.hasAttribute("aria-invalid")).toBe(false)
  expect(asked.filter((a) => a.attributeName !== "value").every((a) => a.ok)).toBe(true)
})

test("the root's own attributes (its token) are never held, even with a field focused", () => {
  mount(`<div id="r" data-controller="reactive" data-reactive-token-value="t1"><input name="name" value="old"></div>`)
  const root = document.getElementById("r")
  type(document.querySelector("input"), "Hello ")

  expect(dispatch("turbo:before-morph-attribute", root, { attributeName: "data-reactive-token-value", mutationType: "update" })).toBe(true)
  expect(dispatch("turbo:before-morph-attribute", root, { attributeName: "value", mutationType: "update" })).toBe(true)
})

test("data-reactive-morph-value opts a field out: the morph writes it even while focused", () => {
  mount(`<div data-controller="reactive"><input name="phone" value="old" data-reactive-morph-value></div>`)
  const field = document.querySelector("input")
  type(field, "5551234")

  morph(field, `<input name="phone" value="555-1234" data-reactive-morph-value>`)

  expect(field.value).toBe("555-1234")
})

test("the focused textarea keeps what was typed; its default (text) advances", () => {
  mount(`<div data-controller="reactive"><textarea name="body">old</textarea></div>`)
  const field = document.querySelector("textarea")
  type(field, "Line one ")

  morph(field, `<textarea name="body">Line one</textarea>`)

  expect(field.value).toBe("Line one ")
  expect(field.defaultValue).toBe("Line one")
})

test("an unfocused textarea takes the server's value", () => {
  mount(`<div data-controller="reactive"><textarea name="body">old</textarea><input name="x"></div>`)
  const field = document.querySelector("textarea")
  type(field, "edited")
  document.querySelector("input").focus()

  morph(field, `<textarea name="body">server</textarea>`)

  expect(field.value).toBe("server")
})

test("a select is not held: Idiomorph syncs its options' `selected`, never `value`", () => {
  mount(`<div data-controller="reactive"><select name="s"><option value="a">A</option><option value="b">B</option></select></div>`)
  const select = document.querySelector("select")
  select.focus()
  const [a] = select.options

  expect(dispatch("turbo:before-morph-attribute", a, { attributeName: "selected", mutationType: "update" })).toBe(true)
})

test("registration is idempotent: one pair of listeners however often it runs", () => {
  registerReactiveMorphFocus()
  registerReactiveMorphFocus()
  mount(`<div data-controller="reactive"><input name="name" value="old"></div>`)
  const field = document.querySelector("input")
  type(field, "Hello ")
  let writes = 0
  const real = field.setAttribute.bind(field)
  field.setAttribute = (name, value) => {
    if (name === "value") writes++
    real(name, value)
  }

  morph(field, `<input name="name" value="Hello">`)

  expect(writes).toBe(1)
})
