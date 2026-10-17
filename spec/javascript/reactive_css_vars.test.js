// Issue #417: reactive_css_vars — fields feed CSS custom properties on an
// element, with no request.
//
//   data-reactive-css-vars='{"to":[selector|"@root",…],"global"?:true,
//                            "vars":{"--name":{"field","unit"?}}}'
//
// On the root, or on an element it owns. Each field is read the way
// reactive_show reads one (a checkbox gives 1 or 0, a radio group its checked
// value), parsed as a finite number and written with its unit; anything else
// removes the property. It seeds on connect, follows input/change, and
// re-seeds on turbo:morph-element. `to:` resolves like a client op's.
//
// happy-dom, so selectors, events and CSSStyleDeclaration are real.
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

function attr(wire) {
  return JSON.stringify(wire).replaceAll('"', "&quot;")
}

const LIGHT = { to: ["#sample"], vars: { "--light": { field: "light" }, "--turn": { field: "turn", unit: "deg" } } }

async function connect(id) {
  const controller = new ReactiveController()
  controller.element = document.getElementById(id)
  controller.connect()
  await flush()
  return controller
}

// The issue's LightPreview: a slider, a select and the image they style.
async function mount(wire = LIGHT, { light = "1", rootAttrs = "", extra = "" } = {}) {
  document.body.innerHTML = `<div id="r" data-controller="reactive" data-reactive-css-vars="${attr(wire)}" ${rootAttrs}>
    <input type="range" name="light" min="0.5" max="1.5" step="0.01" value="${light}">
    <select name="turn"><option value="0">0</option><option value="90">90</option></select>
    <img id="sample" alt="" style="--light: 1; --turn: 0deg; filter: brightness(var(--light, 1))">${extra}</div>`
  await connect("r")
  return (sel) => document.querySelector(sel)
}

function set(field, value, type = "input") {
  field.value = value
  field.dispatchEvent(new window.Event(type, { bubbles: true }))
}

const prop = (el, name) => el.style.getPropertyValue(name)

test("connect seeds every property from its field, with its unit", async () => {
  const $ = await mount(LIGHT, { light: "1.2" })
  expect(prop($("#sample"), "--light")).toBe("1.2")
  expect(prop($("#sample"), "--turn")).toBe("0deg")
  // The author's other declarations are untouched.
  expect($("#sample").style.getPropertyValue("filter")).toBe("brightness(var(--light, 1))")
})

test("input and change both update the property", async () => {
  const $ = await mount()
  set($("[name=light]"), "0.75")
  expect(prop($("#sample"), "--light")).toBe("0.75")
  set($("[name=turn]"), "90", "change")
  expect(prop($("#sample"), "--turn")).toBe("90deg")
})

test("a value that is not a finite number removes the property; a number puts it back", async () => {
  const $ = await mount({ to: ["#sample"], vars: { "--light": { field: "light" } } }, { extra: `<input name="t">` })
  const wire = { to: ["#sample"], vars: { "--x": { field: "t", unit: "px" } } }
  $("#r").setAttribute("data-reactive-css-vars", JSON.stringify(wire))
  for (const value of ["", "   ", "abc", "1abc", "Infinity", "-Infinity", "NaN", "1px", "url(x)"]) {
    set($("[name=t]"), "12")
    expect(prop($("#sample"), "--x")).toBe("12px")
    set($("[name=t]"), value)
    expect([value, prop($("#sample"), "--x")]).toEqual([value, ""])
  }
})

test("numbers are written as numbers: trimmed, normalized, negative, exponent", async () => {
  const $ = await mount({ to: ["#sample"], vars: { "--x": { field: "t" } } }, { extra: `<input name="t">` })
  for (const [value, written] of [
    [" 2 ", "2"],
    ["1.50", "1.5"],
    ["-3", "-3"],
    ["-0", "0"],
    [".5", "0.5"],
    ["1e3", "1000"],
  ]) {
    set($("[name=t]"), value)
    expect([value, prop($("#sample"), "--x")]).toEqual([value, written])
  }
})

test("a checkbox gives 1 or 0 (it wins over Rails' paired hidden input)", async () => {
  const $ = await mount(
    { to: ["#sample"], vars: { "--on": { field: "on" } } },
    { extra: `<input type="hidden" name="on" value="0"><input type="checkbox" name="on" value="1">` },
  )
  expect(prop($("#sample"), "--on")).toBe("0")
  $("[type=checkbox]").checked = true
  $("[type=checkbox]").dispatchEvent(new window.Event("change", { bubbles: true }))
  expect(prop($("#sample"), "--on")).toBe("1")
})

test("a text field holding the word true is not a number", async () => {
  const $ = await mount({ to: ["#sample"], vars: { "--x": { field: "t" } } }, { extra: `<input name="t" value="3">` })
  expect(prop($("#sample"), "--x")).toBe("3")
  set($("[name=t]"), "true")
  expect(prop($("#sample"), "--x")).toBe("")
})

test("a radio group gives its checked value; none checked removes the property", async () => {
  const $ = await mount(
    { to: ["#sample"], vars: { "--size": { field: "size", unit: "rem" } } },
    { extra: `<input type="radio" name="size" value="1"><input type="radio" name="size" value="2" checked>` },
  )
  expect(prop($("#sample"), "--size")).toBe("2rem")
  $("[name=size][value='1']").checked = true
  $("[name=size][value='1']").dispatchEvent(new window.Event("change", { bubbles: true }))
  expect(prop($("#sample"), "--size")).toBe("1rem")
  $("[name=size][value='1']").checked = false
  $("[name=size][value='1']").dispatchEvent(new window.Event("change", { bubbles: true }))
  expect(prop($("#sample"), "--size")).toBe("")
})

test("a field no owned control carries leaves the property alone", async () => {
  const $ = await mount({ to: ["#sample"], vars: { "--light": { field: "missing" } } })
  expect(prop($("#sample"), "--light")).toBe("1")
})

test("reactive_scope applies: a bare field reads scope[field]", async () => {
  document.body.innerHTML = `<div id="r" data-controller="reactive" data-reactive-scope="look"
    data-reactive-css-vars="${attr({ to: ["#sample"], vars: { "--light": { field: "light" } } })}">
    <input name="look[light]" value="0.6"><img id="sample" alt=""></div>`
  await connect("r")
  expect(prop(document.querySelector("#sample"), "--light")).toBe("0.6")
})

test("to: @root styles the root itself; an Array styles every target", async () => {
  const $ = await mount(
    { to: ["@root", "#sample", ".chip"], vars: { "--light": { field: "light" } } },
    { light: "1.1", extra: `<i class="chip"></i><i class="chip"></i>` },
  )
  expect(prop($("#r"), "--light")).toBe("1.1")
  expect(prop($("#sample"), "--light")).toBe("1.1")
  for (const chip of document.querySelectorAll(".chip")) expect(prop(chip, "--light")).toBe("1.1")
})

test("targets resolve inside the root, never a nested root's or the page's; global: true reaches the page", async () => {
  const nested = `<div id="n" data-controller="reactive"><i class="t" id="inner"></i></div>`
  const scoped = { to: [".t"], vars: { "--light": { field: "light" } } }
  const $ = await mount(scoped, { light: "1.3", extra: `<i class="t" id="own"></i>${nested}` })
  document.body.insertAdjacentHTML("beforeend", `<i class="t" id="outside"></i>`)
  set($("[name=light]"), "1.4")
  expect(prop($("#own"), "--light")).toBe("1.4")
  expect(prop($("#inner"), "--light")).toBe("")
  expect(prop($("#outside"), "--light")).toBe("")

  $("#r").setAttribute("data-reactive-css-vars", JSON.stringify({ ...scoped, global: true }))
  set($("[name=light]"), "0.9")
  expect(prop($("#outside"), "--light")).toBe("0.9")
})

test("the binding may sit on an element inside the root; to: still resolves from the root", async () => {
  document.body.innerHTML = `<div id="r" data-controller="reactive">
    <input name="light" value="0.8"><input name="gap" value="4">
    <div data-reactive-css-vars="${attr({ to: ["#sample"], vars: { "--light": { field: "light" } } })}"></div>
    <div data-reactive-css-vars="${attr({ to: ["@root"], vars: { "--gap": { field: "gap", unit: "px" } } })}"></div>
    <img id="sample" alt=""></div>`
  await connect("r")
  expect(prop(document.querySelector("#sample"), "--light")).toBe("0.8")
  expect(prop(document.querySelector("#r"), "--gap")).toBe("4px")
})

test("a binding inside a nested root is that root's, not its parent's", async () => {
  document.body.innerHTML = `<div id="r" data-controller="reactive"><input name="light" value="0.7">
    <div id="n" data-controller="reactive">
      <img id="sample" alt="" data-reactive-css-vars="${attr({ to: ["@root"], vars: { "--light": { field: "light" } } })}">
    </div></div>`
  await connect("r")
  // The parent never wrote it: its own field would have given 0.7.
  expect(prop(document.querySelector("#n"), "--light")).toBe("")
  expect(prop(document.querySelector("#r"), "--light")).toBe("")
})

test("a morph that reset the inline style is corrected on turbo:morph-element", async () => {
  const $ = await mount()
  set($("[name=light]"), "1.4")
  // Idiomorph writes the server's style back while the user's slider keeps its value.
  $("#sample").setAttribute("style", "--light: 1; --turn: 0deg; filter: brightness(var(--light, 1))")
  $("#sample").dispatchEvent(new window.CustomEvent("turbo:morph-element", { bubbles: true }))
  expect(prop($("#sample"), "--light")).toBe("1.4")
})

test("an edit elsewhere on the form writes nothing when the value is the same", async () => {
  const $ = await mount(LIGHT, { extra: `<input name="note">` })
  let writes = 0
  new MutationObserver((records) => (writes += records.length)).observe($("#sample"), { attributeFilter: ["style"] })
  set($("[name=note]"), "hello")
  set($("[name=light]"), "1")
  await flush()
  expect(writes).toBe(0)
})

test("a hand-built entry with a bad name or unit is refused; its siblings still apply", async () => {
  const wire = {
    to: ["#sample"],
    vars: {
      "--null": null,
      "--light": { field: "light" },
      "--turn": { field: "turn", unit: "vh" },
      "x;color": { field: "light" },
      "--bad": { field: "light", unit: "px;color:red" },
    },
  }
  const $ = await mount(wire, { light: "1.2" })
  expect(prop($("#sample"), "--light")).toBe("1.2")
  expect(prop($("#sample"), "--turn")).toBe("0deg")
  expect(prop($("#sample"), "--bad")).toBe("")
  expect($("#sample").getAttribute("style")).not.toContain("red")
  expect(warnings.some((w) => w.includes("refused reactive_css_vars"))).toBe(true)
})

test("a to: that is not a valid selector matches nothing, and the root's other bindings still run", async () => {
  document.body.innerHTML = `<div id="r" data-controller="reactive"
    data-reactive-css-vars="${attr({ to: ["[name=", "#sample"], vars: { "--light": { field: "light" } } })}">
    <input name="light" value="1.2"><img id="sample" alt="">
    <p id="note" data-reactive-show="${attr({ any: [[{ field: "light", equals: "0.5" }]] })}">dim</p></div>`
  await connect("r")
  expect(prop(document.querySelector("#sample"), "--light")).toBe("1.2")
  expect(document.querySelector("#note").hidden).toBe(true)

  set(document.querySelector("[name=light]"), "0.5")
  expect(prop(document.querySelector("#sample"), "--light")).toBe("0.5")
  expect(document.querySelector("#note").hidden).toBe(false)
})

test("malformed JSON (two calls collided on one element) warns and is skipped", async () => {
  document.body.innerHTML = `<div id="r" data-controller="reactive"
    data-reactive-css-vars="${attr(LIGHT)} ${attr(LIGHT)}"><input name="light" value="1.2"><img id="sample" alt=""></div>`
  await connect("r")
  expect(prop(document.querySelector("#sample"), "--light")).toBe("")
  expect(warnings.some((w) => w.includes("malformed data-reactive-css-vars"))).toBe(true)
})

test("under verbose_errors, a to: that resolves nothing warns once", async () => {
  const $ = await mount(
    { to: ["#nowhere"], vars: { "--light": { field: "light" } } },
    { rootAttrs: `data-reactive-verbose="true"` },
  )
  set($("[name=light]"), "1.1")
  set($("[name=light]"), "1.2")
  await flush()
  expect(warnings.filter((w) => w.includes("reactive_css_vars") && w.includes("#nowhere"))).toHaveLength(1)
})

test("without verbose_errors, a to: that resolves nothing is silent", async () => {
  const $ = await mount({ to: ["#nowhere"], vars: { "--light": { field: "light" } } })
  set($("[name=light]"), "1.1")
  await flush()
  expect(warnings.filter((w) => w.includes("#nowhere"))).toHaveLength(0)
})
