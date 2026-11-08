// Unit tests for the draft nested-attribute rows primitive (issue #208) —
// reactive_nested_*, the "new parent + child rows" window.
//
// Add (nestedAdd) clones the association's server-owned
// <template data-reactive-nested-template="assoc"> row, swaps every NEW_ROW in
// the clone's name/id/for attributes for a fresh unique index, and appends it
// to the owned [data-reactive-nested-list="assoc"] container — no token, no
// POST, ever: the surrounding REAL form submit carries Rails'
// accepts_nested_attributes_for names. Remove (nestedRemove) deletes a draft
// row from the DOM; a row carrying a hidden [_destroy] input (a persisted row
// in an edit form) is marked "1" + hidden instead, so Rails destroys it on
// save.
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll, beforeEach, afterAll } from "bun:test"

let ReactiveController
let confirmModule

beforeAll(async () => {
  mock.module("@hotwired/stimulus", () => ({
    Controller: class {
      constructor() {}
    },
  }))
  ReactiveController = (await import("../../app/javascript/phlex/reactive/reactive_controller.js")).default
  confirmModule = await import("../../app/javascript/phlex/reactive/confirm.js")
})

// confirmResolver is module-global mutable state (setConfirmResolver). Another
// confirm test file can run first in the shared bun worker and leave a custom
// resolver installed (e.g. `() => true`, which never touches window.confirm) —
// so the nestedRemove(confirm:) tests below must reinstall the DEFAULT resolver
// (Promise-wrapped window.confirm) before each, or they'd inherit a leaked one
// and never see the stubbed prompt. This mirrors the reset in the other confirm
// specs; it's inert for the add/remove tests that don't touch confirm.
beforeEach(() => {
  confirmModule.setConfirmResolver((message) =>
    Promise.resolve(typeof globalThis.window !== "undefined" ? globalThis.window.confirm(message) : true),
  )
})

// The issue-222 ctx test installs a custom (message, ctx) resolver and does not
// reset it. Like reactive_confirm_resolver.test.js, restore the shipped default
// on the way out so a later file in the shared bun worker inherits the real
// window.confirm-backed gate (else its window.confirm stub never fires).
afterAll(() => {
  confirmModule.setConfirmResolver((message) =>
    Promise.resolve(typeof globalThis.window !== "undefined" ? globalThis.window.confirm(message) : true),
  )
})

// The reactive_tags FakeNode, extended for the nested-rows clone/renumber:
//   - setAttribute("name") stays coherent with the name property
//   - a "*" matcher (the renumber walks every descendant)
//   - a tag[attr$="value"] ends-with matcher (finding the [_destroy] input)
//   - focus() recording (add focuses the new row's first field)
class FakeNode {
  constructor(opts = {}) {
    const {
      tag = "div",
      id = "",
      name = null,
      type = null,
      value = "",
      controller = null,
      attrs = {},
    } = opts
    this.tag = tag.toLowerCase()
    this.id = id
    this.name = name
    this.type = type
    this.value = value
    this.hidden = false
    this.parentNode = null
    this.children = []
    this.attrs = { ...attrs }
    this.isConnected = true
    this.dispatched = []
    this.focused = 0
    if (controller) this.attrs["data-controller"] = controller
  }

  append(...nodes) {
    for (const n of nodes) {
      n.parentNode = this
      this.children.push(n)
    }
    return this
  }

  appendChild(node) {
    this.append(node)
    return node
  }

  removeChild(node) {
    this.children = this.children.filter((c) => c !== node)
    node.parentNode = null
    return node
  }

  cloneNode(deep) {
    const copy = new FakeNode({
      tag: this.tag,
      id: this.id,
      name: this.name,
      type: this.type,
      value: this.value,
      attrs: { ...this.attrs },
    })
    copy.hidden = this.hidden
    if (deep) for (const child of this.children) copy.append(child.cloneNode(true))
    return copy
  }

  #descendants() {
    const out = []
    for (const child of this.children) out.push(child, ...child.#descendants())
    return out
  }

  matches(selector) {
    if (selector === "*") return true
    if (selector === '[data-controller~="reactive"]') {
      const c = this.attrs["data-controller"]
      return !!c && c.split(/\s+/).includes("reactive")
    }
    const endsWith = selector.match(/^(\w*)\[([\w-]+)\$="(.*)"\]$/)
    if (endsWith) {
      if (endsWith[1] && this.tag !== endsWith[1]) return false
      return (this.getAttribute(endsWith[2]) ?? "").endsWith(endsWith[3])
    }
    const attrEq = selector.match(/^\[([\w-]+)=(?:"([^"]*)"|([^\]"]+))\]$/)
    if (attrEq) return this.getAttribute(attrEq[1]) === (attrEq[2] ?? attrEq[3])
    const attrPresent = selector.match(/^\[([\w-]+)\]$/)
    if (attrPresent) return this.getAttribute(attrPresent[1]) !== null
    // A comma-list of bare tags OR `tag[attr]` segments (e.g. #collectFields'
    // "input[name], select[name], textarea[name]"): match if ANY segment fits.
    const segList = selector.split(",").map((s) => s.trim())
    if (segList.every((s) => /^[a-z]+(\[[\w-]+\])?$/.test(s))) {
      return segList.some((s) => {
        const [, tag, attr] = s.match(/^([a-z]+)(?:\[([\w-]+)\])?$/)
        if (this.tag !== tag) return false
        return attr ? this.getAttribute(attr) !== null : true
      })
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

  getAttribute(attrName) {
    if (attrName === "name") return this.name
    if (attrName === "id") return this.id || null
    return this.attrs[attrName] ?? null
  }
  setAttribute(attrName, attrValue) {
    if (attrName === "name") {
      this.name = String(attrValue)
      return
    }
    if (attrName === "id") {
      this.id = String(attrValue)
      return
    }
    this.attrs[attrName] = String(attrValue)
  }
  hasAttribute(attrName) {
    return attrName in this.attrs
  }
  dispatchEvent(event) {
    this.dispatched.push(event)
  }
  focus() {
    this.focused += 1
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

// The template row prototype:
//   <div data-reactive-nested-row>
//     <label for="li_NEW_ROW_qty></label>
//     <input id="li_NEW_ROW_qty" name="order[line_items_attributes][NEW_ROW][quantity]">
//     <button data-action=…nestedRemove></button>
//   </div>
// Lives in template.content (inert — NOT in the root's query tree), like a
// real <template>.
function rowTemplate(assoc = "line_items") {
  const proto = new FakeNode({ tag: "div", attrs: { "data-reactive-nested-row": "" } })
  proto.append(
    new FakeNode({ tag: "label", attrs: { for: "li_NEW_ROW_qty" } }),
    new FakeNode({
      tag: "input",
      id: "li_NEW_ROW_qty",
      name: `order[${assoc}_attributes][NEW_ROW][quantity]`,
    }),
    new FakeNode({ tag: "button", attrs: { "data-action": "click->reactive#nestedRemove" } }),
  )
  const template = new FakeNode({ tag: "template", attrs: { "data-reactive-nested-template": assoc } })
  template.content = { firstElementChild: proto }
  return template
}

// A full nested-rows widget: the list container, the row template, and the
// add trigger, all inside one reactive root.
function nestedWidget({ assoc = "line_items", template = rowTemplate() } = {}) {
  const root = new FakeNode({ tag: "div", id: "form-root", controller: "reactive" })
  const list = new FakeNode({ tag: "div", attrs: { "data-reactive-nested-list": assoc } })
  const add = new FakeNode({
    tag: "button",
    attrs: { "data-action": "click->reactive#nestedAdd", "data-reactive-association-param": assoc },
  })
  root.append(list, add)
  if (template) root.append(template)
  return { root, list, add }
}

function clickAdd(controller, add) {
  let prevented = 0
  controller.nestedAdd({ currentTarget: add, preventDefault: () => (prevented += 1) })
  return prevented
}

test("nestedAdd clones the template into the list and renumbers NEW_ROW in name/id/for", () => {
  const { root, list, add } = nestedWidget()
  const controller = buildController(root)

  const prevented = clickAdd(controller, add)

  expect(prevented).toBe(1)
  expect(list.children.length).toBe(1)
  const row = list.children[0]
  expect(row.getAttribute("data-reactive-nested-row")).toBe("")

  const input = row.querySelectorAll("input")[0]
  const label = row.querySelectorAll("label")[0]
  expect(input.name).toMatch(/^order\[line_items_attributes\]\[\d+\]\[quantity\]$/)
  expect(input.name).not.toContain("NEW_ROW")
  expect(input.id).not.toContain("NEW_ROW")
  expect(label.getAttribute("for")).toBe(input.id)
})

test("two adds mint DISTINCT indexes (a same-millisecond double add can't collide)", () => {
  const { root, list, add } = nestedWidget()
  const controller = buildController(root)

  clickAdd(controller, add)
  clickAdd(controller, add)

  expect(list.children.length).toBe(2)
  const names = list.children.map((row) => row.querySelectorAll("input")[0].name)
  expect(names[0]).not.toBe(names[1])
})

test("nestedAdd focuses the new row's first field (continue typing immediately)", () => {
  const { root, list, add } = nestedWidget()
  const controller = buildController(root)

  clickAdd(controller, add)

  expect(list.children[0].querySelectorAll("input")[0].focused).toBe(1)
})

test("nestedAdd appends to the RIGHT association when several collections share a root", () => {
  const root = new FakeNode({ tag: "div", id: "form-root", controller: "reactive" })
  const itemsList = new FakeNode({ tag: "div", attrs: { "data-reactive-nested-list": "line_items" } })
  const feesList = new FakeNode({ tag: "div", attrs: { "data-reactive-nested-list": "fees" } })
  const feesTemplate = (() => {
    const proto = new FakeNode({ tag: "div", attrs: { "data-reactive-nested-row": "" } })
    proto.append(new FakeNode({ tag: "input", name: "order[fees_attributes][NEW_ROW][amount]" }))
    const template = new FakeNode({ tag: "template", attrs: { "data-reactive-nested-template": "fees" } })
    template.content = { firstElementChild: proto }
    return template
  })()
  const addFees = new FakeNode({
    tag: "button",
    attrs: { "data-action": "click->reactive#nestedAdd", "data-reactive-association-param": "fees" },
  })
  root.append(itemsList, feesList, rowTemplate(), feesTemplate, addFees)
  const controller = buildController(root)

  controller.nestedAdd({ currentTarget: addFees, preventDefault: () => {} })

  expect(itemsList.children.length).toBe(0)
  expect(feesList.children.length).toBe(1)
  expect(feesList.children[0].querySelectorAll("input")[0].name).toMatch(/^order\[fees_attributes\]\[\d+\]\[amount\]$/)
})

test("a missing template warns once and does nothing (a half-built binding is loud, never throwing)", () => {
  const { root, list, add } = nestedWidget({ template: null })
  const controller = buildController(root)
  const warnings = []
  const originalWarn = console.warn
  console.warn = (msg) => warnings.push(msg)

  try {
    clickAdd(controller, add)
    clickAdd(controller, add)
  } finally {
    console.warn = originalWarn
  }

  expect(list.children.length).toBe(0)
  expect(warnings.length).toBe(1)
  expect(warnings[0]).toContain("nested")
})

test("a list/template inside a NESTED reactive root is not this root's (issue #15 ownership)", () => {
  const { root, add } = nestedWidget({ template: null })
  const inner = new FakeNode({ tag: "div", id: "inner-root", controller: "reactive" })
  const innerList = new FakeNode({ tag: "div", attrs: { "data-reactive-nested-list": "line_items" } })
  inner.append(innerList, rowTemplate())
  root.append(inner)
  const controller = buildController(root)
  const originalWarn = console.warn
  console.warn = () => {}

  try {
    clickAdd(controller, add)
  } finally {
    console.warn = originalWarn
  }

  expect(innerList.children.length).toBe(0)
})

test("nestedRemove deletes a DRAFT row (no [_destroy] input) from the DOM", () => {
  const { root, list, add } = nestedWidget()
  const controller = buildController(root)
  clickAdd(controller, add)
  const row = list.children[0]
  const remove = row.querySelectorAll("button")[0]

  controller.nestedRemove({ currentTarget: remove, preventDefault: () => {} })

  expect(list.children.length).toBe(0)
})

test("nestedRemove on a PERSISTED row ([_destroy] present) marks it and hides the row", () => {
  const { root, list } = nestedWidget()
  const row = new FakeNode({ tag: "div", attrs: { "data-reactive-nested-row": "" } })
  const destroy = new FakeNode({
    tag: "input",
    type: "hidden",
    name: "order[line_items_attributes][0][_destroy]",
    value: "0",
  })
  const remove = new FakeNode({ tag: "button", attrs: { "data-action": "click->reactive#nestedRemove" } })
  row.append(destroy, remove)
  list.append(row)
  const controller = buildController(root)

  controller.nestedRemove({ currentTarget: remove, preventDefault: () => {} })

  expect(list.children.length).toBe(1)
  expect(destroy.value).toBe("1")
  expect(row.hidden).toBe(true)
  // The set-value + dispatch contract (issue #183): dirty tracking/compute see it.
  expect(destroy.dispatched.some((e) => e.type === "input")).toBe(true)
})

test("nestedRemove outside any row wrapper is a no-op", () => {
  const { root, list, add } = nestedWidget()
  const stray = new FakeNode({ tag: "button", attrs: { "data-action": "click->reactive#nestedRemove" } })
  root.append(stray)
  const controller = buildController(root)
  clickAdd(controller, add)

  controller.nestedRemove({ currentTarget: stray, preventDefault: () => {} })

  expect(list.children.length).toBe(1)
})

test("nestedRemove never escapes this root walking up (a root inside ANOTHER collection's row)", () => {
  // <div data-reactive-nested-row> (the OUTER page's row)
  //   <div data-controller=reactive id=form-root>…<button nestedRemove></button></div>
  // </div>
  const outerRow = new FakeNode({ tag: "div", attrs: { "data-reactive-nested-row": "" } })
  const outerList = new FakeNode({ tag: "div" })
  outerList.append(outerRow)
  const root = new FakeNode({ tag: "div", id: "form-root", controller: "reactive" })
  const stray = new FakeNode({ tag: "button", attrs: { "data-action": "click->reactive#nestedRemove" } })
  root.append(stray)
  outerRow.append(root)
  const controller = buildController(root)

  controller.nestedRemove({ currentTarget: stray, preventDefault: () => {} })

  expect(outerList.children.length).toBe(1)
})

// Fill-then-add (issue #208 Scenario A): the add controls live OUTSIDE the row.
// nestedAdd clones the template, then SEEDS each cloned-row field from a named
// source control (from: { rowField => "#selector" }), keeps focus on the
// sources (not the new row), and optionally CLEARS the sources for the next
// entry. The row field is matched by the trailing bracket segment of its name
// — the SAME key inference JSON mode uses. Sources resolve root-scoped (#15).
//
// FakeNode's matches() supports [attr="val"], so sources carry data-src="…".
// A two-field template row (quantity + price) — the fill-then-add tests seed
// both, unlike the single-field default rowTemplate().
function twoFieldTemplate(assoc = "line_items") {
  const proto = new FakeNode({ tag: "div", attrs: { "data-reactive-nested-row": "" } })
  proto.append(
    new FakeNode({ tag: "input", name: `order[${assoc}_attributes][NEW_ROW][quantity]` }),
    new FakeNode({ tag: "input", name: `order[${assoc}_attributes][NEW_ROW][price]` }),
    new FakeNode({ tag: "button", attrs: { "data-action": "click->reactive#nestedRemove" } }),
  )
  const template = new FakeNode({ tag: "template", attrs: { "data-reactive-nested-template": assoc } })
  template.content = { firstElementChild: proto }
  return template
}

function fillWidget({ from, clear = false } = {}) {
  const { root, list, add } = nestedWidget({ template: twoFieldTemplate() })
  const qtySrc = new FakeNode({ tag: "input", value: "7", attrs: { "data-src": "qty" } })
  const priceSrc = new FakeNode({ tag: "input", value: "3", attrs: { "data-src": "price" } })
  root.append(qtySrc, priceSrc)
  add.attrs["data-reactive-nested-from-param"] =
    JSON.stringify(from ?? { quantity: '[data-src="qty"]', price: '[data-src="price"]' })
  if (clear) add.attrs["data-reactive-nested-clear-param"] = "true"
  return { root, list, add, qtySrc, priceSrc }
}

function fieldByKey(row, key) {
  return row.querySelectorAll("input").find((i) => (i.name ?? "").endsWith(`[${key}]`))
}

test("fill-then-add seeds the cloned row's fields from the named source controls", () => {
  const { root, list, add } = fillWidget()
  const controller = buildController(root)

  clickAdd(controller, add)

  const row = list.children[0]
  expect(fieldByKey(row, "quantity").value).toBe("7")
  expect(fieldByKey(row, "price").value).toBe("3")
  // Renumber still ran — the seeded field carries a real index, no placeholder.
  expect(fieldByKey(row, "quantity").name).toMatch(/\[\d+\]\[quantity\]$/)
  expect(fieldByKey(row, "quantity").name).not.toContain("NEW_ROW")
})

test("a seeded field dispatches a bubbling input (compute/show/dirty see it)", () => {
  const { root, list, add } = fillWidget()
  const controller = buildController(root)

  clickAdd(controller, add)

  expect(fieldByKey(list.children[0], "quantity").dispatched.some((e) => e.type === "input")).toBe(true)
})

test("clear: resets the sources with a dispatched input; without it they keep their value", () => {
  const cleared = fillWidget({ clear: true })
  const controllerA = buildController(cleared.root)
  clickAdd(controllerA, cleared.add)
  expect(cleared.qtySrc.value).toBe("")
  expect(cleared.qtySrc.dispatched.some((e) => e.type === "input")).toBe(true)

  const kept = fillWidget({ clear: false })
  const controllerB = buildController(kept.root)
  clickAdd(controllerB, kept.add)
  expect(kept.qtySrc.value).toBe("7")
})

test("fill-then-add keeps focus on the sources — it does NOT steal focus into the new row", () => {
  const { root, list, add, qtySrc } = fillWidget()
  const controller = buildController(root)

  clickAdd(controller, add)

  expect(fieldByKey(list.children[0], "quantity").focused).toBe(0)
  expect(qtySrc.focused).toBe(1)
})

test("a source selector that resolves nothing is skipped (row still adds, no throw)", () => {
  const { root, list, add } = fillWidget({ from: { quantity: '[data-src="qty"]', price: '[data-src="ghost"]' } })
  const controller = buildController(root)

  clickAdd(controller, add)

  const row = list.children[0]
  expect(fieldByKey(row, "quantity").value).toBe("7")
  expect(fieldByKey(row, "price").value).toBe("") // unresolved source → left blank
})

test("a row-field key with no matching cloned field is skipped (no throw)", () => {
  const { root, list, add } = fillWidget({ from: { quantity: '[data-src="qty"]', nosuch: '[data-src="price"]' } })
  const controller = buildController(root)

  clickAdd(controller, add)

  expect(fieldByKey(list.children[0], "quantity").value).toBe("7")
})

test("a source inside a NESTED reactive root is not this root's (issue #15 ownership)", () => {
  const { root, list, add } = nestedWidget()
  const inner = new FakeNode({ tag: "div", id: "inner-root", controller: "reactive" })
  const foreign = new FakeNode({ tag: "input", value: "99", attrs: { "data-src": "qty" } })
  inner.append(foreign)
  root.append(inner)
  add.attrs["data-reactive-nested-from-param"] = JSON.stringify({ quantity: '[data-src="qty"]' })
  const controller = buildController(root)

  clickAdd(controller, add)

  expect(fieldByKey(list.children[0], "quantity").value).toBe("") // foreign source not owned → skipped
})

test("no from: attr — the inline-edit default is unchanged (blank clone, focus the row)", () => {
  const { root, list, add } = nestedWidget()
  const controller = buildController(root)

  clickAdd(controller, add)

  const row = list.children[0]
  expect(fieldByKey(row, "quantity").value).toBe("")
  expect(row.querySelectorAll("input")[0].focused).toBe(1)
})

test("a checkbox source copies its checked state to a checkbox row field", () => {
  const { root, list, add } = nestedWidget()
  const src = new FakeNode({ tag: "input", type: "checkbox", attrs: { "data-src": "gift" } })
  src.checked = true
  root.append(src)
  // Give the template a checkbox field named …[gift].
  const proto = new FakeNode({ tag: "div", attrs: { "data-reactive-nested-row": "" } })
  proto.append(
    new FakeNode({ tag: "input", name: "order[line_items_attributes][NEW_ROW][quantity]" }),
    new FakeNode({ tag: "input", type: "checkbox", name: "order[line_items_attributes][NEW_ROW][gift]" }),
    new FakeNode({ tag: "button", attrs: { "data-action": "click->reactive#nestedRemove" } }),
  )
  const template = root.children.find((c) => c.tag === "template")
  template.content = { firstElementChild: proto }
  add.attrs["data-reactive-nested-from-param"] = JSON.stringify({ gift: '[data-src="gift"]' })
  const controller = buildController(root)

  clickAdd(controller, add)

  expect(fieldByKey(list.children[0], "gift").checked).toBe(true)
})

// clear: :reset (issue #466) — each source goes back to its RENDERED default
// (the way a form reset would) instead of being emptied. A widget with one
// source of every kind, each with a matching row field.
function option({ selected = false, defaultSelected = false, disabled = false } = {}) {
  return { selected, defaultSelected, disabled, closest: () => null }
}

function resetWidget({ clear = "reset" } = {}) {
  const { root, list, add } = nestedWidget()
  const src = (key, props) => Object.assign(new FakeNode({ tag: props.tag ?? "input", attrs: { "data-src": key } }), props)
  const flagOn = src("flag_on", { type: "checkbox", checked: false, defaultChecked: true })
  const flagOff = src("flag_off", { type: "checkbox", checked: true, defaultChecked: false })
  const name = src("name", { type: "text", value: "typed", defaultValue: "Default" })
  const kindOptions = [option(), option({ defaultSelected: true }), option({ selected: true })]
  const kind = src("kind", { tag: "select", type: "select-one", value: "c", options: kindOptions })
  const sizeOptions = [option({ disabled: true }), option(), option({ selected: true })]
  const size = src("size", { tag: "select", type: "select-one", value: "c", options: sizeOptions })
  const tagOptions = [option({ selected: true }), option({ defaultSelected: true }), option({ defaultSelected: true })]
  const tags = src("tags", { tag: "select", type: "select-multiple", multiple: true, value: "a", options: tagOptions })
  root.append(flagOn, flagOff, name, kind, size, tags)

  const keys = ["flag_on", "flag_off", "name", "kind", "size", "tags"]
  const proto = new FakeNode({ tag: "div", attrs: { "data-reactive-nested-row": "" } })
  for (const key of keys) {
    const type = key.startsWith("flag") ? "checkbox" : null
    proto.append(new FakeNode({ tag: "input", type, name: `order[line_items_attributes][NEW_ROW][${key}]` }))
  }
  root.children.find((c) => c.tag === "template").content = { firstElementChild: proto }
  add.attrs["data-reactive-nested-from-param"] = JSON.stringify(Object.fromEntries(keys.map((k) => [k, `[data-src="${k}"]`])))
  if (clear !== null) add.attrs["data-reactive-nested-clear-param"] = clear
  return { root, list, add, flagOn, flagOff, name, kind, size, tags }
}

test("clear: :reset puts a checkbox source back to its defaultChecked (on stays on, off stays off)", () => {
  const w = resetWidget()
  clickAdd(buildController(w.root), w.add)

  expect(w.flagOn.checked).toBe(true)
  expect(w.flagOff.checked).toBe(false)
  // The row was seeded from the state BEFORE the reset.
  expect(fieldByKey(w.list.children[0], "flag_on").checked).toBe(false)
  expect(fieldByKey(w.list.children[0], "flag_off").checked).toBe(true)
})

test("clear: :reset puts a text source back to its defaultValue, not \"\"", () => {
  const w = resetWidget()
  clickAdd(buildController(w.root), w.add)

  expect(w.name.value).toBe("Default")
  expect(fieldByKey(w.list.children[0], "name").value).toBe("typed")
})

test("clear: :reset selects a single select's defaultSelected option, else its first enabled one", () => {
  const w = resetWidget()
  clickAdd(buildController(w.root), w.add)

  expect(w.kind.options.map((o) => o.selected)).toEqual([false, true, false])
  // No defaultSelected option: the first enabled one (the #297 reset rule).
  expect(w.size.options.map((o) => o.selected)).toEqual([false, true, false])
})

test("clear: :reset gives a multiple select exactly its defaultSelected options", () => {
  const w = resetWidget()
  clickAdd(buildController(w.root), w.add)

  expect(w.tags.options.map((o) => o.selected)).toEqual([false, true, true])
})

test("clear: :reset dispatches exactly one bubbling input per source", () => {
  const w = resetWidget()
  clickAdd(buildController(w.root), w.add)

  for (const source of [w.flagOn, w.flagOff, w.name, w.kind, w.size, w.tags]) {
    const inputs = source.dispatched.filter((e) => e.type === "input")
    expect(inputs.length).toBe(1)
    expect(inputs[0].bubbles).toBe(true)
  }
})

test("a source two from: keys point at is reset (and dispatches) once", () => {
  const w = resetWidget()
  w.add.attrs["data-reactive-nested-from-param"] = JSON.stringify({ name: '[data-src="name"]', kind: '[data-src="name"]' })
  clickAdd(buildController(w.root), w.add)

  expect(w.name.value).toBe("Default")
  expect(w.name.dispatched.filter((e) => e.type === "input").length).toBe(1)
})

test("clear: :reset puts a radio source back to its own defaultChecked", () => {
  const w = resetWidget()
  const off = Object.assign(new FakeNode({ tag: "input", attrs: { "data-src": "pick" } }), { type: "radio", checked: true, defaultChecked: false })
  const on = Object.assign(new FakeNode({ tag: "input", attrs: { "data-src": "pick_on" } }), { type: "radio", checked: false, defaultChecked: true })
  w.root.append(off, on)
  w.add.attrs["data-reactive-nested-from-param"] = JSON.stringify({ name: '[data-src="pick"]', kind: '[data-src="pick_on"]' })
  clickAdd(buildController(w.root), w.add)

  expect(off.checked).toBe(false)
  expect(on.checked).toBe(true)
  expect(off.dispatched.filter((e) => e.type === "input").length).toBe(1)
})

test("clear: true still empties every source (unchanged by :reset)", () => {
  const w = resetWidget({ clear: "true" })
  clickAdd(buildController(w.root), w.add)

  expect(w.flagOn.checked).toBe(false)
  expect(w.flagOff.checked).toBe(false)
  expect(w.name.value).toBe("")
  expect(w.kind.value).toBe("")
})

test("an unknown clear param leaves the sources alone", () => {
  const w = resetWidget({ clear: "bogus" })
  clickAdd(buildController(w.root), w.add)

  expect(w.flagOff.checked).toBe(true)
  expect(w.name.value).toBe("typed")
  expect(w.name.dispatched.length).toBe(0)
})

// Confirm on remove (issue #218): reactive_nested_remove(confirm:) gates the
// remove behind the SAME overridable confirmResolver on(:action, confirm:) uses
// — declining leaves the row; accepting removes it (draft leaves the DOM /
// persisted _destroy-marks + hides) and re-syncs JSON mode. No confirm attr →
// the immediate-remove fast path, unchanged. The gate makes nestedRemove async
// only when a message is present.
//
// confirmResolver defaults to window.confirm; buildController sets globalThis.window,
// so stub .confirm on it. Returns the messages the prompt saw.
function stubConfirm(answer) {
  const seen = []
  globalThis.window.confirm = (message) => {
    seen.push(message)
    return answer
  }
  return seen
}

// A draft row already in the list, with a remove button carrying the given
// confirm attributes. Returns { row, remove }.
function draftRowWithRemove(list, confirmAttrs = {}) {
  const row = new FakeNode({ tag: "div", attrs: { "data-reactive-nested-row": "" } })
  const remove = new FakeNode({
    tag: "button",
    attrs: { "data-action": "click->reactive#nestedRemove", ...confirmAttrs },
  })
  row.append(new FakeNode({ tag: "input", name: "order[line_items_attributes][0][quantity]", value: "3" }), remove)
  list.append(row)
  return { row, remove }
}

test("nestedRemove(confirm) — declining leaves the row (no removal)", async () => {
  const { root, list } = nestedWidget()
  const controller = buildController(root)
  const { remove } = draftRowWithRemove(list, { "data-reactive-confirm-param": "Really delete this row?" })
  const seen = stubConfirm(false)

  await controller.nestedRemove({ currentTarget: remove, preventDefault: () => {} })

  expect(seen).toEqual(["Really delete this row?"]) // prompted with our message
  expect(list.children.length).toBe(1) // declined → still there
})

test("nestedRemove(confirm) — accepting removes the row", async () => {
  const { root, list } = nestedWidget()
  const controller = buildController(root)
  const { remove } = draftRowWithRemove(list, { "data-reactive-confirm-param": "Sure?" })
  stubConfirm(true)

  await controller.nestedRemove({ currentTarget: remove, preventDefault: () => {} })

  expect(list.children.length).toBe(0) // confirmed → gone
})

test("nestedRemove without a confirm attr removes immediately (unchanged fast path)", () => {
  const { root, list } = nestedWidget()
  const controller = buildController(root)
  const { remove } = draftRowWithRemove(list) // no confirm attrs
  stubConfirm(false) // even if a prompt exists, no attr means no prompt

  controller.nestedRemove({ currentTarget: remove, preventDefault: () => {} })

  expect(list.children.length).toBe(0) // removed with no gate
})

test("nestedRemove(confirm) — declining still preventDefaults (no native submit on cancel)", async () => {
  const { root, list } = nestedWidget()
  const controller = buildController(root)
  const { remove } = draftRowWithRemove(list, { "data-reactive-confirm-param": "Sure?" })
  stubConfirm(false)
  let prevented = 0

  await controller.nestedRemove({ currentTarget: remove, preventDefault: () => (prevented += 1) })

  expect(prevented).toBe(1)
  expect(list.children.length).toBe(1)
})

test("nestedRemove(confirm) — accepting a PERSISTED row marks _destroy and hides it", async () => {
  const { root, list } = nestedWidget()
  const controller = buildController(root)
  const row = new FakeNode({ tag: "div", attrs: { "data-reactive-nested-row": "" } })
  const destroy = new FakeNode({
    tag: "input",
    type: "hidden",
    name: "order[line_items_attributes][0][_destroy]",
    value: "0",
  })
  const remove = new FakeNode({
    tag: "button",
    attrs: { "data-action": "click->reactive#nestedRemove", "data-reactive-confirm-param": "Delete saved item?" },
  })
  row.append(destroy, remove)
  list.append(row)
  stubConfirm(true)

  await controller.nestedRemove({ currentTarget: remove, preventDefault: () => {} })

  expect(destroy.value).toBe("1")
  expect(row.hidden).toBe(true)
})

test("nestedRemove(confirm-when) — the conditional Hash only prompts when it fires", async () => {
  // { groups, message } — the reactive_show DNF fold over collected fields. The
  // row's quantity field is 0, so an "equals 0" condition MATCHES → prompt.
  const { root, list } = nestedWidget()
  const confirmWhen = JSON.stringify({
    groups: { any: [[{ field: "order[line_items_attributes][0][quantity]", equals: "0" }]] },
    message: "Empty row — remove?",
  })
  const row = new FakeNode({ tag: "div", attrs: { "data-reactive-nested-row": "" } })
  const field = new FakeNode({ tag: "input", name: "order[line_items_attributes][0][quantity]", value: "0" })
  const remove = new FakeNode({
    tag: "button",
    attrs: { "data-action": "click->reactive#nestedRemove", "data-reactive-confirm-when-param": confirmWhen },
  })
  row.append(field, remove)
  list.append(row)
  const controller = buildController(root)
  const seen = stubConfirm(false)

  await controller.nestedRemove({ currentTarget: remove, preventDefault: () => {} })

  expect(seen).toEqual(["Empty row — remove?"]) // condition fired → prompted
  expect(list.children.length).toBe(1) // declined → kept
})

// Per-row confirm interpolation (issue #222). A row added client-side via
// nestedAdd is a cloneNode of the <template>, and the clone carries the
// TEMPLATE's confirm string verbatim — the renumber/seed steps never touch
// data-reactive-confirm[-when]-param. So a per-row confirm like
// "Delete '%{name}'?" is frozen to the template's (value-less) string on every
// added row. Fix: nestedRemove interpolates %{field} placeholders from the
// row's LIVE field values at click time (reflects later edits too), and passes
// the row context to confirmResolver as an optional 2nd arg.
//
// A row already in the list carrying a confirm with %{key} placeholders and the
// given field values. Returns { row, remove }.
function rowWithConfirmPlaceholders(list, confirmMessage, fieldValues) {
  const row = new FakeNode({ tag: "div", attrs: { "data-reactive-nested-row": "" } })
  const controls = Object.entries(fieldValues).map(
    ([key, value]) =>
      new FakeNode({ tag: "input", name: `order[line_items_attributes][0][${key}]`, value: String(value) }),
  )
  const remove = new FakeNode({
    tag: "button",
    attrs: { "data-action": "click->reactive#nestedRemove", "data-reactive-confirm-param": confirmMessage },
  })
  row.append(...controls, remove)
  list.append(row)
  return { row, remove }
}

test("nestedRemove(confirm) — interpolates %{field} from the row's live values", async () => {
  const { root, list } = nestedWidget()
  const controller = buildController(root)
  const { remove } = rowWithConfirmPlaceholders(list, "Delete '%{name}' (%{amount})?", {
    name: "Widget",
    amount: "42",
  })
  const seen = stubConfirm(false)

  await controller.nestedRemove({ currentTarget: remove, preventDefault: () => {} })

  expect(seen).toEqual(["Delete 'Widget' (42)?"]) // read the row NOW, not the template
})

test("nestedRemove(confirm) — a %{field} the row lacks stays as the literal placeholder", async () => {
  const { root, list } = nestedWidget()
  const controller = buildController(root)
  const { remove } = rowWithConfirmPlaceholders(list, "Delete '%{name}' (%{gone})?", { name: "Widget" })
  const seen = stubConfirm(false)

  await controller.nestedRemove({ currentTarget: remove, preventDefault: () => {} })

  expect(seen).toEqual(["Delete 'Widget' (%{gone})?"]) // unresolved key left visible/debuggable
})

test("nestedRemove(confirm) — a client-ADDED row's confirm reflects its own typed value", async () => {
  // The exact issue-222 scenario: the template row is value-less, so its confirm
  // string is a %{quantity} placeholder. Add clones it; typing into the row's
  // quantity field then makes the per-row confirm reflect THAT row's value.
  const proto = new FakeNode({ tag: "div", attrs: { "data-reactive-nested-row": "" } })
  proto.append(
    new FakeNode({ tag: "input", name: "order[line_items_attributes][NEW_ROW][quantity]" }),
    new FakeNode({
      tag: "button",
      attrs: {
        "data-action": "click->reactive#nestedRemove",
        "data-reactive-confirm-param": "Remove row with quantity %{quantity}?",
      },
    }),
  )
  const template = new FakeNode({ tag: "template", attrs: { "data-reactive-nested-template": "line_items" } })
  template.content = { firstElementChild: proto }
  const { root, list, add } = nestedWidget({ template })
  const controller = buildController(root)

  clickAdd(controller, add)
  const row = list.children[0]
  fieldByKey(row, "quantity").value = "7" // user types into the added row
  const remove = row.querySelectorAll("button")[0]
  const seen = stubConfirm(false)

  await controller.nestedRemove({ currentTarget: remove, preventDefault: () => {} })

  expect(seen).toEqual(["Remove row with quantity 7?"]) // the ADDED row's own value
})

test("nestedRemove(confirm) — reflects a LATER edit (click-time, not clone-time)", async () => {
  const { root, list } = nestedWidget()
  const controller = buildController(root)
  const { row, remove } = rowWithConfirmPlaceholders(list, "Delete '%{name}'?", { name: "Widget" })
  const seen = stubConfirm(false)

  fieldByKey(row, "name").value = "Gadget" // edited AFTER the row exists
  await controller.nestedRemove({ currentTarget: remove, preventDefault: () => {} })

  expect(seen).toEqual(["Delete 'Gadget'?"]) // live read, not a frozen snapshot
})

test("nestedRemove(confirm-when) — the conditional Hash message is interpolated too", async () => {
  const { root, list } = nestedWidget()
  const confirmWhen = JSON.stringify({
    groups: { any: [[{ field: "order[line_items_attributes][0][quantity]", equals: "0" }]] },
    message: "Remove '%{name}' (empty)?",
  })
  const row = new FakeNode({ tag: "div", attrs: { "data-reactive-nested-row": "" } })
  row.append(
    new FakeNode({ tag: "input", name: "order[line_items_attributes][0][quantity]", value: "0" }),
    new FakeNode({ tag: "input", name: "order[line_items_attributes][0][name]", value: "Bolt" }),
    new FakeNode({
      tag: "button",
      attrs: { "data-action": "click->reactive#nestedRemove", "data-reactive-confirm-when-param": confirmWhen },
    }),
  )
  list.append(row)
  const controller = buildController(root)
  const seen = stubConfirm(false)

  await controller.nestedRemove({ currentTarget: row.querySelectorAll("button")[0], preventDefault: () => {} })

  expect(seen).toEqual(["Remove 'Bolt' (empty)?"]) // condition fired AND message interpolated
})

// confirmResolver ctx (issue #222, superset of proposal 3). The resolver gets an
// optional 2nd arg so a power-user override can build the string itself. On
// nestedRemove it carries the row element, the row's field map, and the trigger.
test("nestedRemove(confirm) — passes the row context to confirmResolver as a 2nd arg", async () => {
  const { root, list } = nestedWidget()
  const controller = buildController(root)
  const { row, remove } = rowWithConfirmPlaceholders(list, "Delete '%{name}'?", { name: "Widget", amount: "42" })

  let receivedMessage
  let receivedCtx
  confirmModule.setConfirmResolver((message, ctx) => {
    receivedMessage = message
    receivedCtx = ctx
    return false
  })

  await controller.nestedRemove({ currentTarget: remove, preventDefault: () => {} })

  expect(receivedMessage).toBe("Delete 'Widget'?") // already interpolated
  expect(receivedCtx.row).toBe(row)
  expect(receivedCtx.el).toBe(remove)
  expect(receivedCtx.fields).toEqual({ name: "Widget", amount: "42" })
})
