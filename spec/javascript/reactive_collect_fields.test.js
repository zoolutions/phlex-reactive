// Unit test for #collectFields() field scoping across NESTED reactive roots.
//
// Issue #15: when one reactive component is rendered inside another (both are
// data-controller="reactive" roots), an action dispatched on the OUTER root must
// collect only the OUTER root's own named inputs — NOT the inner roots' inputs.
// Before the fix, this.element.querySelectorAll(...) descended into nested
// reactive roots and swept their inputs into the outer action's params (last
// row wins, collides with the editor's own fields).
//
// #collectFields() is private, so we observe it through the POST body: stub
// fetch to capture the request, dispatch on the outer root, and assert the
// collected params contain only the outer root's fields.
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll } from "bun:test"

let ReactiveController

beforeAll(async () => {
  mock.module("@hotwired/stimulus", () => ({
    Controller: class {
      constructor() {}
    },
  }))
  ReactiveController = (await import("../../app/javascript/phlex/reactive/reactive_controller.js")).default
})

// A minimal DOM node faithful enough for #collectFields():
//   - matches(selector) for the reactive-root predicate
//   - closest(selector) walks parents (used to find the owning reactive root)
//   - querySelectorAll(selector) returns descendant named fields
// We only support the specific selectors #collectFields() actually issues.
class FakeNode {
  constructor({ tag = "div", name = null, type = null, value = "", checked = false, controller = null, token = null } = {}) {
    this.tag = tag.toLowerCase()
    this.token = token
    this.name = name
    this.type = type
    this.value = value
    this.checked = checked
    this.parentNode = null
    this.children = []
    this.dataset = {}
    if (controller) this.dataset.controller = controller
  }

  append(...nodes) {
    for (const n of nodes) {
      n.parentNode = this
      this.children.push(n)
    }
    return this
  }

  #descendants() {
    const out = []
    for (const child of this.children) {
      out.push(child, ...child.#descendants())
    }
    return out
  }

  getAttribute(attr) {
    if (attr === "name") return this.name
    if (attr === "data-reactive-token-value") return this.token
    return null
  }

  setAttribute() {}
  removeAttribute() {}

  // Only the two predicates #collectFields() uses.
  matches(selector) {
    if (selector === '[data-controller~="reactive"]') {
      const c = this.dataset.controller
      return !!c && c.split(/\s+/).includes("reactive")
    }
    if (selector.includes("input[name]")) {
      return ["input", "select", "textarea"].includes(this.tag) && this.name != null
    }
    if (selector.includes("lexxy-editor")) {
      return false // no rich editors in this fixture
    }
    return false
  }

  closest(selector) {
    let node = this
    while (node) {
      if (node.matches(selector)) return node
      node = node.parentNode
    }
    return null
  }

  querySelectorAll(selector) {
    return this.#descendants().filter((n) => n.matches(selector))
  }
}

function buildController(rootEl) {
  const controller = new ReactiveController()
  controller.element = rootEl
  controller.tokenValue = "tok"
  return controller
}

test("outer root action collects only its own fields, not nested reactive roots' (issue #15)", async () => {
  // Outer reactive editor: a flat field `notes`, containing a nested reactive
  // row with bare `quantity`/`price` inputs (the cosmos line-item shape).
  const outer = new FakeNode({ tag: "div", controller: "reactive" })
  const outerNotes = new FakeNode({ tag: "input", name: "notes", value: "editor notes" })

  const innerRow = new FakeNode({ tag: "div", controller: "reactive", token: "row-tok" })
  const rowQty = new FakeNode({ tag: "input", name: "quantity", value: "3" })
  const rowPrice = new FakeNode({ tag: "input", name: "price", value: "9.99" })
  innerRow.append(rowQty, rowPrice)

  outer.append(outerNotes, innerRow)

  let captured = null
  globalThis.fetch = (path, opts) => {
    captured = JSON.parse(opts.body)
    return Promise.resolve({
      redirected: false,
      ok: true,
      headers: { get: () => "text/vnd.turbo-stream.html" },
      text: () => Promise.resolve(""),
    })
  }
  globalThis.document = { querySelector: () => null, dispatchEvent: () => {} }
  globalThis.window = { Turbo: { renderStreamMessage: () => {} } }

  const controller = buildController(outer)
  await controller.dispatch({
    params: { action: "save", params: "{}" },
    preventDefault: () => {},
  })

  // The outer save sees ONLY its own field. The nested row's quantity/price are
  // owned by the inner reactive root, so they must not bleed into the editor's
  // params.
  expect(captured.params).toEqual({ notes: "editor notes" })
  expect(captured.params).not.toHaveProperty("quantity")
  expect(captured.params).not.toHaveProperty("price")
})

test("an action on the nested row still collects that row's own fields", async () => {
  const outer = new FakeNode({ tag: "div", controller: "reactive" })
  const outerNotes = new FakeNode({ tag: "input", name: "notes", value: "editor notes" })

  const innerRow = new FakeNode({ tag: "div", controller: "reactive", token: "row-tok" })
  const rowQty = new FakeNode({ tag: "input", name: "quantity", value: "3" })
  innerRow.append(rowQty)
  outer.append(outerNotes, innerRow)

  let captured = null
  globalThis.fetch = (path, opts) => {
    captured = JSON.parse(opts.body)
    return Promise.resolve({
      redirected: false,
      ok: true,
      headers: { get: () => "text/vnd.turbo-stream.html" },
      text: () => Promise.resolve(""),
    })
  }
  globalThis.document = { querySelector: () => null, dispatchEvent: () => {} }
  globalThis.window = { Turbo: { renderStreamMessage: () => {} } }

  // Dispatch on the INNER row's controller — it owns rowQty, not outerNotes.
  const controller = buildController(innerRow)
  await controller.dispatch({
    params: { action: "update", params: "{}" },
    preventDefault: () => {},
  })

  expect(captured.params).toEqual({ quantity: "3" })
  expect(captured.params).not.toHaveProperty("notes")
})
