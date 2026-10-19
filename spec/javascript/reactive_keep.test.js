// Issue #369: keep: on the class, visibility and attribute ops. A kept op
// records what it did to each target (a class on or off, `hidden`, an
// attribute's value or its absence) in a WeakMap; one document
// turbo:morph-element listener re-applies that record after Turbo morphs the
// element in place. An op without keep: records nothing, and an element a
// stream replaces is a new element with no record.
//
// `morph()` below replays what Turbo 8 + Idiomorph do to ONE element's
// attributes (syncNodeFrom: the server render's attributes win, missing ones
// are removed), then dispatches turbo:morph-element the way Turbo's
// afterNodeMorphed does (vendored turbo.js).
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll, beforeEach, afterEach, afterAll } from "bun:test"
import { Window } from "happy-dom"

let mod
let ReactiveController
let ops
const window = new Window()
const SAVED = {}
let originalDocument

beforeAll(async () => {
  mock.module("@hotwired/stimulus", () => ({ Controller: class {} }))
  originalDocument = globalThis.document
  globalThis.document = window.document
  mod = await import("../../app/javascript/phlex/reactive/reactive_controller.js")
  ;({ ops } = await import("../../app/javascript/phlex/reactive/compute.js"))
  ReactiveController = mod.default
  mod.__resetReactiveKeepForTest()
  mod.registerReactiveKeep()
})

afterAll(() => {
  mod.__resetReactiveKeepForTest()
  if (originalDocument === undefined) delete globalThis.document
  else globalThis.document = originalDocument
})

beforeEach(() => {
  for (const key of ["document", "window", "Event", "CustomEvent", "requestAnimationFrame"]) SAVED[key] = globalThis[key]
  globalThis.document = window.document
  globalThis.window = window
  globalThis.Event = window.Event
  globalThis.CustomEvent = window.CustomEvent
  globalThis.requestAnimationFrame = (fn) => setTimeout(fn, 0)
  document.body.innerHTML = ""
})

afterEach(() => {
  for (const [key, value] of Object.entries(SAVED)) {
    if (value === undefined) delete globalThis[key]
    else globalThis[key] = value
  }
})

function mount(html) {
  document.body.insertAdjacentHTML("beforeend", `<div id="r" data-controller="reactive" data-reactive-token-value="t">${html}</div>`)
  const root = document.getElementById("r")
  const controller = new ReactiveController()
  controller.element = root
  return { root, controller }
}

function run(controller, list) {
  controller.runOps({ params: { ops: list }, target: controller.element, preventDefault() {} })
}

function morph(el, html) {
  const holder = document.createElement("div")
  holder.innerHTML = html
  const next = holder.firstElementChild
  for (const { name } of [...el.attributes]) if (!next.hasAttribute(name)) el.removeAttribute(name)
  for (const { name, value } of next.attributes) if (el.getAttribute(name) !== value) el.setAttribute(name, value)
  el.dispatchEvent(new window.CustomEvent("turbo:morph-element", { bubbles: true, detail: { currentElement: el, newElement: next } }))
}

const ITEMS = `<div id="item-1" class="item"></div><div id="item-2" class="item"></div><div id="item-3" class="item"></div>`
const select = (n) => [
  ["remove_class", { to: ".item", classes: ["selected"], keep: true }],
  ["add_class", { to: `#item-${n}`, classes: ["selected"], keep: true }],
]
const selected = (root) => [...root.querySelectorAll(".selected")].map((el) => el.id)

// --- classes -----------------------------------------------------------------

test("a kept add_class survives a morph of its element", () => {
  const { root, controller } = mount(ITEMS)
  run(controller, select(2))

  morph(root.querySelector("#item-2"), `<div id="item-2" class="item"></div>`)

  expect(selected(root)).toEqual(["item-2"])
})

test("an add_class without keep: is undone by the morph (today's behaviour)", () => {
  const { root, controller } = mount(ITEMS)
  run(controller, [["add_class", { to: "#item-2", classes: ["selected"] }]])

  morph(root.querySelector("#item-2"), `<div id="item-2" class="item"></div>`)

  expect(selected(root)).toEqual([])
})

test("clear all, then select one: a later kept remove_class cancels an earlier kept add", () => {
  const { root, controller } = mount(ITEMS)
  run(controller, select(2))
  run(controller, select(3))

  for (const n of [1, 2, 3]) morph(root.querySelector(`#item-${n}`), `<div id="item-${n}" class="item"></div>`)

  expect(selected(root)).toEqual(["item-3"])
})

test("a class the server render changes, and no kept op touched, follows the render", () => {
  const { root, controller } = mount(ITEMS)
  run(controller, select(3))

  morph(root.querySelector("#item-3"), `<div id="item-3" class="item renamed"></div>`)
  const el = root.querySelector("#item-3")
  expect([...el.classList].sort()).toEqual(["item", "renamed", "selected"])

  morph(el, `<div id="item-3" class="item"></div>`)
  expect([...el.classList].sort()).toEqual(["item", "selected"])
})

test("a kept remove_class keeps a server-rendered class off", () => {
  const { root, controller } = mount(`<div id="a" class="item selected"></div>`)
  run(controller, [["remove_class", { to: "#a", classes: ["selected"], keep: true }]])

  morph(root.querySelector("#a"), `<div id="a" class="item selected"></div>`)

  expect(root.querySelector("#a").className).toBe("item")
})

test("a kept toggle_class re-applies its result, it does not flip again", () => {
  const { root, controller } = mount(`<div id="a" class="item"></div>`)
  run(controller, [["toggle_class", { to: "#a", classes: ["open"], keep: true }]])
  const el = root.querySelector("#a")

  morph(el, `<div id="a" class="item"></div>`)
  morph(el, `<div id="a" class="item"></div>`)

  expect(el.classList.contains("open")).toBe(true)
})

test("the latest kept op wins between a kept class op and a kept set_attr on class", () => {
  const { root, controller } = mount(`<div id="a" class="item"></div>`)
  run(controller, [
    ["add_class", { to: "#a", classes: ["selected"], keep: true }],
    ["set_attr", { to: "#a", name: "class", value: "item", keep: true }],
    ["add_class", { to: "#a", classes: ["selected"], keep: true }],
  ])
  const el = root.querySelector("#a")

  morph(el, `<div id="a" class="item"></div>`)

  expect([...el.classList].sort()).toEqual(["item", "selected"])
})

test("an op without keep: leaves an earlier kept record alone", () => {
  const { root, controller } = mount(`<div id="a" class="item"></div>`)
  run(controller, [["add_class", { to: "#a", classes: ["selected"], keep: true }]])
  run(controller, [["remove_class", { to: "#a", classes: ["selected"] }]])
  const el = root.querySelector("#a")
  expect(el.classList.contains("selected")).toBe(false)

  morph(el, `<div id="a" class="item"></div>`)

  expect(el.classList.contains("selected")).toBe(true)
})

// --- visibility --------------------------------------------------------------

test("kept show and hide survive a morph that renders the opposite", () => {
  const { root, controller } = mount(`<div id="details" hidden></div><div id="summary"></div>`)
  run(controller, [
    ["show", { to: "#details", keep: true }],
    ["hide", { to: "#summary", keep: true }],
  ])

  morph(root.querySelector("#details"), `<div id="details" hidden></div>`)
  morph(root.querySelector("#summary"), `<div id="summary"></div>`)

  expect(root.querySelector("#details").hidden).toBe(false)
  expect(root.querySelector("#summary").hidden).toBe(true)
})

test("a kept toggle re-applies the state it left, morph after morph", () => {
  const { root, controller } = mount(`<div id="d" hidden></div>`)
  run(controller, [["toggle", { to: "#d", keep: true }]])
  const el = root.querySelector("#d")

  morph(el, `<div id="d" hidden></div>`)
  morph(el, `<div id="d" hidden></div>`)

  expect(el.hidden).toBe(false)
})

test("a kept show with a transition re-applies hidden without running the transition again", async () => {
  const { root, controller } = mount(`<div id="d" hidden></div>`)
  run(controller, [["show", { to: "#d", keep: true, transition: ["fade", "o-0", "o-100"] }]])
  const el = root.querySelector("#d")
  await new Promise((resolve) => setTimeout(resolve, 400))

  morph(el, `<div id="d" hidden></div>`)

  expect(el.hidden).toBe(false)
  expect(el.className).toBe("")
})

test("a kept show with expanded: keeps the trigger's aria-expanded through its own morph", () => {
  const { root, controller } = mount(`<button id="t" aria-expanded="false"></button><div id="d" hidden></div>`)
  run(controller, [["show", { to: "#d", expanded: "#t", keep: true }]])
  const trigger = root.querySelector("#t")
  expect(trigger.getAttribute("aria-expanded")).toBe("true")

  morph(trigger, `<button id="t" aria-expanded="false"></button>`)

  expect(trigger.getAttribute("aria-expanded")).toBe("true")
})

// --- attributes --------------------------------------------------------------

test("kept set_attr, remove_attr and toggle_attr survive a morph", () => {
  const { root, controller } = mount(
    `<div id="a" aria-expanded="false"></div><div id="b" data-open=""></div><div id="c" aria-pressed="false"></div>`,
  )
  run(controller, [
    ["set_attr", { to: "#a", name: "aria-expanded", value: "true", keep: true }],
    ["remove_attr", { to: "#b", name: "data-open", keep: true }],
    ["toggle_attr", { to: "#c", name: "aria-pressed", values: ["true", "false"], keep: true }],
  ])

  morph(root.querySelector("#a"), `<div id="a" aria-expanded="false"></div>`)
  morph(root.querySelector("#b"), `<div id="b" data-open=""></div>`)
  morph(root.querySelector("#c"), `<div id="c" aria-pressed="false"></div>`)

  expect(root.querySelector("#a").getAttribute("aria-expanded")).toBe("true")
  expect(root.querySelector("#b").hasAttribute("data-open")).toBe(false)
  expect(root.querySelector("#c").getAttribute("aria-pressed")).toBe("true")
})

test("a refused attribute name is neither applied nor kept", () => {
  const warn = console.warn
  console.warn = () => {}
  try {
    const { root, controller } = mount(`<div id="a"></div>`)
    run(controller, [["set_attr", { to: "#a", name: "onclick", value: "x()", keep: true }]])

    morph(root.querySelector("#a"), `<div id="a"></div>`)

    expect(root.querySelector("#a").hasAttribute("onclick")).toBe(false)
  } finally {
    console.warn = warn
  }
})

// --- replaced elements -------------------------------------------------------

test("an element a stream replaces starts with no kept state", () => {
  const { root, controller } = mount(ITEMS)
  run(controller, select(2))

  root.querySelector("#item-2").outerHTML = `<div id="item-2" class="item"></div>`
  const fresh = root.querySelector("#item-2")
  morph(fresh, `<div id="item-2" class="item"></div>`)

  expect(fresh.classList.contains("selected")).toBe(false)
})

// --- the reactive:js stream path (reply.js) ----------------------------------

test("a kept op in a reactive:js stream is kept too", () => {
  const { root } = mount(ITEMS)
  window.Turbo = { StreamActions: {} }
  mod.registerReactiveJs()
  const attrs = { "data-reactive-ops": JSON.stringify(select(1)), target: "r" }
  window.Turbo.StreamActions["reactive:js"].call({ getAttribute: (name) => attrs[name] ?? null })
  expect(selected(root)).toEqual(["item-1"])

  morph(root.querySelector("#item-1"), `<div id="item-1" class="item"></div>`)
  expect(selected(root)).toEqual(["item-1"])
})

// --- the client builder (compute.js) -----------------------------------------

test("the compute ops builder carries keep: true only when asked", () => {
  const chain = ops
    .add_class("#a", "x", { keep: true })
    .show("#d", { keep: true })
    .set_attr("#a", "aria-selected", "true", { keep: true })
    .remove_class("#a", "x")

  expect(chain.ops.map(([, args]) => args.keep)).toEqual([true, true, true, undefined])
  expect(JSON.stringify(ops.add_class("#a", "x"))).toBe('[["add_class",{"to":"#a","classes":["x"]}]]')
  expect(JSON.stringify(ops.hide("#a", { keep: false }))).toBe('[["hide",{"to":"#a"}]]')
})

// --- a delegated pick (issue #442) ---------------------------------------------

test("a kept set_attr on @trigger survives a morph of the row the delegated binding picked", () => {
  const { root, controller } = mount(`<ul id="menu">
    <li id="row-1" role="option"><span id="l1">One</span></li>
    <li id="row-2" role="option"><span id="l2">Two</span></li></ul>`)
  const record = {
    on: "click",
    within: "[role=option]",
    ops: [
      ["remove_attr", { to: "[role=option]", name: "aria-selected", keep: true }],
      ["set_attr", { to: "@trigger", name: "aria-selected", value: "true", keep: true }],
    ],
  }
  root.querySelector("#menu").addEventListener("click", (event) => {
    event.params = { ops: record }
    controller.runOps(event)
  })

  root.querySelector("#l2").dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true }))
  morph(root.querySelector("#row-2"), `<li id="row-2" role="option"></li>`)

  expect(root.querySelector("#row-2").getAttribute("aria-selected")).toBe("true")
  expect(root.querySelector("#row-1").hasAttribute("aria-selected")).toBe(false)
})
