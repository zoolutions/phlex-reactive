// Unit test for client-side list navigation (combobox keyboard nav, issue #72).
//
// A search/combobox trigger declares `on(:search, …, listnav: "[role=option]")`
// (Ruby), which appends Stimulus keyboard filters to the input's data-action and
// emits data-reactive-listnav-option-param. The controller's listnav* handlers
// move a client-side highlight among the option elements (Arrow Up/Down), pick
// the highlighted one on Enter (by clicking its OWN reactive trigger, so the
// selection stays a signed action), and clear on Escape — all with NO server
// round trip for the highlight itself.
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll } from "bun:test"
import { Window } from "happy-dom"

let ReactiveController

beforeAll(async () => {
  mock.module("@hotwired/stimulus", () => ({
    Controller: class {
      constructor() {}
    },
  }))
  ReactiveController = (await import("../../app/javascript/phlex/reactive/reactive_controller.js")).default
})

// A fake option element: tracks its highlighted attribute + click count, and
// answers closest() to the owning root so #ownsField treats it as owned.
function makeOption(label) {
  const attrs = {}
  return {
    label,
    tagName: "BUTTON",
    _root: null,
    clicks: 0,
    getAttribute: (k) => attrs[k] ?? null,
    setAttribute: (k, v) => (attrs[k] = String(v)),
    removeAttribute: (k) => delete attrs[k],
    hasAttribute: (k) => k in attrs,
    click() {
      this.clicks++
    },
    scrollIntoView() {},
    closest() {
      return this._root
    },
  }
}

// A root carrying the listnav option selector + a list of option elements. The
// controller reads the selector from getAttribute and finds options via
// querySelectorAll(selector).
function makeRoot({ selector, options }) {
  const attrs = { "data-reactive-listnav-option-param": selector }
  const root = {
    id: "combobox",
    getAttribute: (k) => attrs[k] ?? null,
    querySelectorAll: (sel) => (sel === selector ? options.slice() : []),
    closest: () => null,
  }
  for (const o of options) o._root = root
  return root
}

function buildController(root) {
  const controller = new ReactiveController()
  controller.element = root
  globalThis.window ??= {}
  return controller
}

function event() {
  let prevented = false
  return {
    get defaultPrevented() {
      return prevented
    },
    preventDefault() {
      prevented = true
    },
  }
}

const HIGHLIGHT = "data-reactive-highlighted"
const highlightedIndex = (options) => options.findIndex((o) => o.hasAttribute(HIGHLIGHT))

test("listnavNext highlights the first option, then advances and wraps", () => {
  const options = [makeOption("a"), makeOption("b"), makeOption("c")]
  const controller = buildController(makeRoot({ selector: "[role=option]", options }))

  controller.listnavNext(event())
  expect(highlightedIndex(options)).toBe(0)

  controller.listnavNext(event())
  expect(highlightedIndex(options)).toBe(1)

  controller.listnavNext(event()) // -> c
  controller.listnavNext(event()) // wraps -> a
  expect(highlightedIndex(options)).toBe(0)
})

test("listnavPrev moves backward and wraps from the top to the bottom", () => {
  const options = [makeOption("a"), makeOption("b"), makeOption("c")]
  const controller = buildController(makeRoot({ selector: "[role=option]", options }))

  controller.listnavPrev(event()) // from nothing -> last
  expect(highlightedIndex(options)).toBe(2)

  controller.listnavPrev(event()) // -> b
  expect(highlightedIndex(options)).toBe(1)
})

test("only ONE option is highlighted at a time", () => {
  const options = [makeOption("a"), makeOption("b")]
  const controller = buildController(makeRoot({ selector: "[role=option]", options }))

  controller.listnavNext(event()) // a
  controller.listnavNext(event()) // b
  expect(options.filter((o) => o.hasAttribute(HIGHLIGHT)).length).toBe(1)
  expect(highlightedIndex(options)).toBe(1)
})

test("listnavPick clicks the highlighted option and prevents default", () => {
  const options = [makeOption("a"), makeOption("b")]
  const controller = buildController(makeRoot({ selector: "[role=option]", options }))

  controller.listnavNext(event()) // highlight a
  const e = event()
  controller.listnavPick(e)

  expect(options[0].clicks).toBe(1)
  expect(options[1].clicks).toBe(0)
  expect(e.defaultPrevented).toBe(true)
})

test("listnavPick with nothing highlighted is a no-op (does not prevent default)", () => {
  const options = [makeOption("a"), makeOption("b")]
  const controller = buildController(makeRoot({ selector: "[role=option]", options }))

  const e = event()
  controller.listnavPick(e)

  expect(options[0].clicks).toBe(0)
  expect(options[1].clicks).toBe(0)
  expect(e.defaultPrevented).toBe(false) // Enter falls through (no selection to make)
})

test("listnavClose clears the highlight", () => {
  const options = [makeOption("a"), makeOption("b")]
  const controller = buildController(makeRoot({ selector: "[role=option]", options }))

  controller.listnavNext(event())
  expect(highlightedIndex(options)).toBe(0)

  controller.listnavClose(event())
  expect(highlightedIndex(options)).toBe(-1)
})

test("arrow keys prevent default so the caret doesn't jump in the input", () => {
  const options = [makeOption("a")]
  const controller = buildController(makeRoot({ selector: "[role=option]", options }))

  const down = event()
  controller.listnavNext(down)
  expect(down.defaultPrevented).toBe(true)

  const up = event()
  controller.listnavPrev(up)
  expect(up.defaultPrevented).toBe(true)
})

test("listnav handlers are a no-op when there are no options (empty dropdown)", () => {
  const controller = buildController(makeRoot({ selector: "[role=option]", options: [] }))
  // Must not throw on any handler.
  controller.listnavNext(event())
  controller.listnavPrev(event())
  controller.listnavPick(event())
  controller.listnavClose(event())
  expect(true).toBe(true)
})

// Issue #442: Enter clicks the highlighted option, and that click bubbles to a
// list bound ONCE with on_client(..., within: "[role=option]") — keyboard
// picking runs the delegated binding with the option as @trigger, no binding
// on the option itself. Real DOM (happy-dom) for the bubbling.
test("Enter on a highlighted option runs the list's delegated binding with that option as @trigger", () => {
  const win = new Window()
  const saved = { document: globalThis.document, window: globalThis.window, Event: globalThis.Event }
  globalThis.document = win.document
  globalThis.window = win
  globalThis.Event = win.Event
  try {
    win.document.body.innerHTML = `
      <div id="picker" data-controller="reactive">
        <input id="q" data-reactive-listnav-option-param="[role=option]">
        <input id="item-value" type="hidden">
        <ul id="menu">
          <li><button role="option" id="opt-1" data-value="v1">North</button></li>
          <li><button role="option" id="opt-2" data-value="v2">South</button></li>
        </ul>
      </div>`
    const root = win.document.getElementById("picker")
    const controller = new ReactiveController()
    controller.element = root
    const record = {
      on: "click",
      within: "[role=option]",
      ops: [
        ["set_value", { to: "#item-value", from: "@trigger", attr: "data-value" }],
        ["set_attr", { to: "@trigger", name: "aria-selected", value: "true" }],
      ],
    }
    root.querySelector("#menu").addEventListener("click", (e) => {
      e.params = { ops: record }
      controller.runOps(e)
    })
    const q = root.querySelector("#q")
    const key = () => ({ currentTarget: q, target: q, preventDefault() {} })

    controller.listnavNext(key())
    controller.listnavNext(key())
    controller.listnavPick(key())

    expect(root.querySelector("#item-value").value).toBe("v2")
    expect(root.querySelector("#opt-2").getAttribute("aria-selected")).toBe("true")
    expect(root.querySelector("#opt-1").hasAttribute("aria-selected")).toBe(false)
  } finally {
    for (const [name, value] of Object.entries(saved)) {
      if (value === undefined) delete globalThis[name]
      else globalThis[name] = value
    }
  }
})
