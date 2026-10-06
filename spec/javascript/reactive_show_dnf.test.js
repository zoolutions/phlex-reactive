// Unit tests for the ONE DNF show evaluator (issue #180 Phase A). The 0.10 wire
// is data-reactive-show='{"any":[[term,…],…]}' — an array of GROUPS; terms AND
// within a group, groups OR. Plus data-reactive-scope="form" (bare field →
// [name="form[field]"]) and data-reactive-show-disable="true" (hidden sections
// disable their owned controls so they stop submitting). Every fixture vector in
// spec/fixtures/show_predicate_vectors.json is also run through the controller
// here — the Ruby<->JS parity contract.
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll } from "bun:test"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"

let ReactiveController

beforeAll(async () => {
  mock.module("@hotwired/stimulus", () => ({
    Controller: class {
      constructor() {}
    },
  }))
  ReactiveController = (await import("../../app/javascript/phlex/reactive/reactive_controller.js")).default
})

// A minimal element stub — extends the reactive_show harness with `disabled`
// and the compound `input[name], select[name], textarea[name]` selector the
// disable path queries.
class FakeNode {
  constructor(opts = {}) {
    const { tag = "div", name = null, type = null, value = "", checked = false, controller = null, attrs = {} } = opts
    this.tag = tag.toLowerCase()
    this.name = name
    this.type = type
    this.value = value
    this.checked = checked
    this.hidden = false
    this.disabled = false
    this.parentNode = null
    this.children = []
    this.attrs = { ...attrs }
    this.isConnected = true
    this.listeners = {}
    if (controller) this.attrs["data-controller"] = controller
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
    for (const child of this.children) out.push(child, ...child.#descendants())
    return out
  }

  matches(selector) {
    if (selector === '[data-controller~="reactive"]') {
      const c = this.attrs["data-controller"]
      return !!c && c.split(/\s+/).includes("reactive")
    }
    if (selector === "[data-reactive-show-field]") return "data-reactive-show-field" in this.attrs
    if (selector === "[data-reactive-show-field], [data-reactive-show]") {
      return "data-reactive-show-field" in this.attrs || "data-reactive-show" in this.attrs
    }
    if (selector === '[data-action*="reactive#trackDirty"]') {
      return (this.attrs["data-action"] ?? "").includes("reactive#trackDirty")
    }
    // The disable path's owned-control query.
    if (selector === "input[name], select[name], textarea[name]") {
      return ["input", "select", "textarea"].includes(this.tag) && this.name !== null
    }
    const named = selector.match(/^\[name="(.*)"\]$/)
    if (named) return this.name === named[1]
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

  getAttribute(name) {
    if (name === "name") return this.name
    return this.attrs[name] ?? null
  }
  setAttribute(name, value) {
    this.attrs[name] = String(value)
  }
  removeAttribute(name) {
    delete this.attrs[name]
  }
  hasAttribute(name) {
    return name in this.attrs
  }
  addEventListener(name, fn) {
    ;(this.listeners[name] ??= []).push(fn)
  }
  removeEventListener(name, fn) {
    this.listeners[name] = (this.listeners[name] ?? []).filter((f) => f !== fn)
  }
  emit(name, event = {}) {
    for (const fn of this.listeners[name] ?? []) fn(event)
  }
}

function buildController(rootEl) {
  const controller = new ReactiveController()
  controller.element = rootEl
  controller.tokenValue = "tok"
  globalThis.document = { querySelector: () => null, dispatchEvent: () => {} }
  globalThis.window = { addEventListener: () => {}, removeEventListener: () => {} }
  return controller
}

function reactiveRoot(extra = {}) {
  const root = new FakeNode({ tag: "div", controller: "reactive", ...extra })
  root.id = "dnf-root"
  return root
}

// A DNF binding: data-reactive-show='{"any":[groups]}'.
function dnf(groups, extraAttrs = {}) {
  return new FakeNode({
    tag: "div",
    attrs: { "data-reactive-show": JSON.stringify({ any: groups }), ...extraAttrs },
  })
}

test("a single-group DNF (AND across fields) toggles hidden from the fold", () => {
  const root = reactiveRoot()
  const type = new FakeNode({ tag: "select", name: "type", value: "individual" })
  const country = new FakeNode({ tag: "select", name: "country", value: "domestic" })
  const block = dnf([[
    { field: "type", equals: "individual" },
    { field: "country", not: "domestic" },
  ]])
  block.hidden = true
  root.append(type, country, block)

  buildController(root).connect()
  expect(block.hidden).toBe(true) // country domestic fails the not term

  country.value = "foreign"
  root.emit("change", { target: country })
  expect(block.hidden).toBe(false) // both terms match
})

test("an OR-of-AND DNF is visible while ANY group matches (the distributive killer)", () => {
  const root = reactiveRoot()
  const director = new FakeNode({ tag: "input", type: "checkbox", name: "director", checked: false })
  const shareholder = new FakeNode({ tag: "input", type: "checkbox", name: "shareholder", checked: false })
  const role = new FakeNode({ tag: "select", name: "role", value: "company" })
  const names = dnf([
    [{ field: "director", equals: "true" }],
    [{ field: "shareholder", equals: "true" }, { field: "role", equals: "individual" }],
  ])
  names.hidden = true
  root.append(director, shareholder, role, names)

  buildController(root).connect()
  expect(names.hidden).toBe(true) // neither group matches

  director.checked = true
  root.emit("change", { target: director })
  expect(names.hidden).toBe(false) // first group (director) matches

  director.checked = false
  shareholder.checked = true
  role.value = "individual"
  root.emit("change", { target: role })
  expect(names.hidden).toBe(false) // second group matches

  role.value = "company"
  root.emit("change", { target: role })
  expect(names.hidden).toBe(true) // company shareholder: neither group
})

test("data-reactive-scope resolves a bare field name to scope[field]", () => {
  const root = reactiveRoot({ attrs: { "data-reactive-scope": "form" } })
  // The DOM field is scoped: name="form[director]".
  const director = new FakeNode({ tag: "input", type: "checkbox", name: "form[director]", checked: true })
  // The binding references the BARE name.
  const block = dnf([[{ field: "director", equals: "true" }]])
  block.hidden = true
  root.append(director, block)

  buildController(root).connect()
  expect(block.hidden).toBe(false) // scope resolved form[director] → checked → visible
})

test("disable: toggles disabled on owned controls when the section hides", () => {
  const root = reactiveRoot()
  const role = new FakeNode({ tag: "select", name: "role", value: "company" })
  const section = dnf([[{ field: "role", equals: "individual" }]], { "data-reactive-show-disable": "true" })
  const idField = new FakeNode({ tag: "input", type: "text", name: "id_number", value: "x" })
  section.append(idField)
  root.append(role, section)

  buildController(root).connect()
  // role != individual → hidden → the owned control is disabled (won't submit).
  expect(section.hidden).toBe(true)
  expect(idField.disabled).toBe(true)

  role.value = "individual"
  root.emit("change", { target: role })
  expect(section.hidden).toBe(false)
  expect(idField.disabled).toBe(false) // re-enabled when shown
})

test("without disable:, hidden controls stay enabled (byte-stable default)", () => {
  const root = reactiveRoot()
  const role = new FakeNode({ tag: "select", name: "role", value: "company" })
  const section = dnf([[{ field: "role", equals: "individual" }]])
  const idField = new FakeNode({ tag: "input", type: "text", name: "id_number", value: "x" })
  section.append(idField)
  root.append(role, section)

  buildController(root).connect()
  expect(section.hidden).toBe(true)
  expect(idField.disabled).toBe(false) // not disabled — no disable flag
})

test("a numeric DNF term fails closed on a blank field", () => {
  const root = reactiveRoot()
  const qty = new FakeNode({ tag: "input", type: "number", name: "qty", value: "" })
  const surcharge = dnf([[{ field: "qty", gte: 10 }]])
  root.append(qty, surcharge)

  buildController(root).connect()
  expect(surcharge.hidden).toBe(true) // "" → NaN → false → hidden

  qty.value = "12"
  root.emit("input", { target: qty })
  expect(surcharge.hidden).toBe(false)
})

test("a malformed DNF payload is skipped (warn, never a throw, visibility untouched)", () => {
  const root = reactiveRoot()
  const bad = new FakeNode({ tag: "div", attrs: { "data-reactive-show": "not-json" } })
  bad.hidden = true
  root.append(bad)

  expect(() => buildController(root).connect()).not.toThrow()
  expect(bad.hidden).toBe(true)
})

// --- The Ruby<->JS parity contract ------------------------------------------
// Every vector in the shared fixture is folded through the controller's DNF
// evaluator exactly as ShowConditions.match? folds it in Ruby.
const VECTORS = JSON.parse(
  readFileSync(fileURLToPath(new URL("../fixtures/show_predicate_vectors.json", import.meta.url)), "utf8"),
).vectors

test("the parity fixture has a non-trivial vector count", () => {
  expect(VECTORS.length).toBeGreaterThanOrEqual(30)
})

for (const vector of VECTORS) {
  test(`parity: ${vector.name}`, () => {
    // Build a root whose fields carry the vector's values, plus a DNF binding
    // with the vector's groups, and assert hidden === !expect.
    const root = reactiveRoot()
    const binding = dnf(vector.groups)
    root.append(binding)
    for (const [name, value] of Object.entries(vector.values)) {
      // An Array value is a checkbox GROUP's checked values (issue #319): one
      // ticked box per entry, plus an unticked one that must not count — Ruby
      // counts the Array's entries.
      if (Array.isArray(value)) {
        for (const v of value) root.append(new FakeNode({ tag: "input", type: "checkbox", name, value: v, checked: true }))
        root.append(new FakeNode({ tag: "input", type: "checkbox", name, value: "x" }))
        continue
      }
      // Every other value is a plain string; a text input reports it verbatim,
      // which matches how Ruby's match? reads the { field => string } map.
      root.append(new FakeNode({ tag: "input", type: "text", name, value }))
    }
    buildController(root).connect()
    expect(binding.hidden).toBe(!vector.expect)
  })
}
