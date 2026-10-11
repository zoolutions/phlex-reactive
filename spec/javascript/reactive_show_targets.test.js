// Unit tests for CROSS-ROOT value-conditional visibility (issue #164) —
// reactive_show_targets, the visibility parallel to the #159 text mirror.
//
// The component that OWNS the field declares which outside, id-allowlisted
// elements it governs: the root carries data-reactive-show-targets, a JSON map
// of { field: { "#id": { equals/not/in }, … } }. The SAME show-sync pass that
// evaluates owned element bindings (issue #161) walks the declared map: it
// reads the OWNED field's current value (never a nested root's — #15), guards
// each selector id-only (warn-and-skip — the client half of the two-sided
// default-deny; the Ruby helper raises at declare time), resolves it
// DOCUMENT-WIDE, and toggles `hidden`. A target id not on the page is silently
// skipped (an unrendered tab pane is normal); malformed wire never throws.
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

// The same minimal element stub as reactive_show.test.js (field reads, hidden,
// ownership selectors, attrs + listener log).
class FakeNode {
  constructor(opts = {}) {
    const {
      tag = "div",
      name = null,
      type = null,
      value = "",
      checked = false,
      controller = null,
      attrs = {},
    } = opts
    this.tag = tag.toLowerCase()
    this.name = name
    this.type = type
    this.value = value
    this.checked = checked
    this.hidden = false
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
    if (selector === "[data-reactive-show-field]") {
      return "data-reactive-show-field" in this.attrs
    }
    if (selector === "[data-reactive-show-field], [data-reactive-show]") {
      return "data-reactive-show-field" in this.attrs || "data-reactive-show" in this.attrs
    }
    if (selector === '[data-action*="reactive#trackDirty"]') {
      return (this.attrs["data-action"] ?? "").includes("reactive#trackDirty")
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

// `outside` maps id selectors ("#badge") to nodes living OUTSIDE the root —
// the targets pass resolves them through document.querySelectorAll.
function buildController(rootEl, outside = {}) {
  const controller = new ReactiveController()
  controller.element = rootEl
  controller.tokenValue = "tok"
  globalThis.document = {
    querySelector: () => null,
    querySelectorAll: (sel) => (sel in outside ? [outside[sel]] : []),
    dispatchEvent: () => {},
  }
  globalThis.window = { addEventListener: () => {}, removeEventListener: () => {} }
  return controller
}

function reactiveRoot(targets = null) {
  const root = new FakeNode({ tag: "div", controller: "reactive" })
  root.id = "targets-root"
  if (targets) root.setAttribute("data-reactive-show-targets", JSON.stringify(targets))
  return root
}

test("connect() seeds an OUTSIDE target from the owned field's value (gate: targets attr alone)", () => {
  const root = reactiveRoot({ mode: { "#badge": { not: "off" } } })
  const mode = new FakeNode({ tag: "select", name: "mode", value: "off" })
  root.append(mode) // NO owned element bindings — the targets attr alone must enable the sync
  const badge = new FakeNode({ tag: "span" })

  buildController(root, { "#badge": badge }).connect()

  expect(badge.hidden).toBe(true) // "off" fails not:"off"
  // The targets gate's sync, plus the emptied-editable handler every bindings
  // root carries (#351: a stream can append its first editable later).
  expect((root.listeners.input ?? []).length).toBe(2)
})

test("an input event re-evaluates the outside target both ways", () => {
  const root = reactiveRoot({ mode: { "#badge": { not: "off" } } })
  const mode = new FakeNode({ tag: "select", name: "mode", value: "off" })
  root.append(mode)
  const badge = new FakeNode({ tag: "span" })
  badge.hidden = true

  buildController(root, { "#badge": badge }).connect()
  expect(badge.hidden).toBe(true)

  mode.value = "express"
  root.emit("input", { target: mode })
  expect(badge.hidden).toBe(false)

  mode.value = "off"
  root.emit("input", { target: mode })
  expect(badge.hidden).toBe(true)
})

test("equals and in predicates work in the declared map", () => {
  const root = reactiveRoot({
    kind: { "#premium-tab": { equals: "premium" } },
    size: { "#surcharge": { in: ["l", "xl"] } },
  })
  const kind = new FakeNode({ tag: "select", name: "kind", value: "premium" })
  const size = new FakeNode({ tag: "select", name: "size", value: "m" })
  root.append(kind, size)
  const premiumTab = new FakeNode({ tag: "li" })
  premiumTab.hidden = true
  const surcharge = new FakeNode({ tag: "aside" })

  const controller = buildController(root, { "#premium-tab": premiumTab, "#surcharge": surcharge })
  controller.connect()

  expect(premiumTab.hidden).toBe(false) // equals matched
  expect(surcharge.hidden).toBe(true) // "m" not in [l, xl]

  size.value = "xl"
  root.emit("change", { target: size })
  expect(surcharge.hidden).toBe(false)
})

test("a checkbox-driven target compares the checked state", () => {
  const root = reactiveRoot({ gift: { "#gift-banner": { equals: "true" } } })
  const gift = new FakeNode({ tag: "input", type: "checkbox", name: "gift", value: "on", checked: false })
  root.append(gift)
  const banner = new FakeNode({ tag: "div" })

  buildController(root, { "#gift-banner": banner }).connect()
  expect(banner.hidden).toBe(true)

  gift.checked = true
  root.emit("change", { target: gift })
  expect(banner.hidden).toBe(false)
})

test("a non-id selector is refused (warn + skip) while its siblings still apply", () => {
  // A hand-built wire attr must not widen the escape to class/compound
  // selectors — the client half of the two-sided default-deny.
  const root = reactiveRoot({
    mode: {
      ".panel": { not: "off" }, // refused
      "#ok": { not: "off" }, // still applies
    },
  })
  const mode = new FakeNode({ tag: "select", name: "mode", value: "on" })
  root.append(mode)
  const sneaky = new FakeNode({ tag: "div" })
  sneaky.hidden = true
  const ok = new FakeNode({ tag: "div" })
  ok.hidden = true

  buildController(root, { ".panel": sneaky, "#ok": ok }).connect()

  expect(sneaky.hidden).toBe(true) // refused selector never toggled
  expect(ok.hidden).toBe(false) // the id sibling did
})

test("a target id not on the page is silently skipped (unrendered tab pane)", () => {
  const root = reactiveRoot({ mode: { "#gone": { not: "off" } } })
  const mode = new FakeNode({ tag: "select", name: "mode", value: "on" })
  root.append(mode)

  expect(() => buildController(root, {}).connect()).not.toThrow()
})

test("a field owned only by a NESTED root is not read (targets untouched)", () => {
  const root = reactiveRoot({ inner_mode: { "#badge": { not: "off" } } })
  const inner = new FakeNode({ tag: "div", controller: "reactive" })
  inner.append(new FakeNode({ tag: "select", name: "inner_mode", value: "on" }))
  root.append(inner)
  const badge = new FakeNode({ tag: "span" })
  badge.hidden = true

  buildController(root, { "#badge": badge }).connect()

  expect(badge.hidden).toBe(true) // the outer root owns no inner_mode → no toggle
})

test("malformed wire JSON never throws, toggles nothing, and WARNS (the two-call mix collision symptom)", () => {
  // Two reactive_show_targets calls on one root space-join their JSON via
  // Phlex mix into exactly this kind of unparseable attr — the client must
  // surface it (warn naming the one-call fix), never silently drop both maps.
  const root = reactiveRoot()
  root.setAttribute("data-reactive-show-targets", '{"mode":{"#a":{"not":"off"}}} {"kind":{"#b":{"equals":"x"}}}')
  const mode = new FakeNode({ tag: "select", name: "mode", value: "on" })
  root.append(mode)
  const badge = new FakeNode({ tag: "span" })
  badge.hidden = true

  const warns = []
  const originalWarn = console.warn
  console.warn = (msg) => warns.push(String(msg))
  try {
    expect(() => buildController(root, { "#badge": badge }).connect()).not.toThrow()
  } finally {
    console.warn = originalWarn
  }

  expect(badge.hidden).toBe(true)
  expect(warns.some((w) => w.includes("data-reactive-show-targets") && w.includes("ONE call"))).toBe(true)
})

test("a malformed predicate in the map is skipped (empty / unknown keys)", () => {
  const root = reactiveRoot({
    mode: {
      "#a": {}, // no predicate
      "#b": { bogus: "x" }, // unknown key
      "#c": { in: "not-a-list" }, // in: must be an array
    },
  })
  const mode = new FakeNode({ tag: "select", name: "mode", value: "on" })
  root.append(mode)
  const a = new FakeNode({ tag: "div" })
  const b = new FakeNode({ tag: "div" })
  const c = new FakeNode({ tag: "div" })
  a.hidden = b.hidden = c.hidden = true

  expect(() => buildController(root, { "#a": a, "#b": b, "#c": c }).connect()).not.toThrow()
  expect(a.hidden).toBe(true)
  expect(b.hidden).toBe(true)
  expect(c.hidden).toBe(true)
})

test("an owned element binding AND a declared target share one pass (both apply)", () => {
  const root = reactiveRoot({ mode: { "#badge": { not: "off" } } })
  const mode = new FakeNode({ tag: "select", name: "mode", value: "express" })
  const inside = new FakeNode({
    tag: "div",
    attrs: { "data-reactive-show-field": "mode", "data-reactive-show-not": "off" },
  })
  inside.hidden = true
  root.append(mode, inside)
  const badge = new FakeNode({ tag: "span" })
  badge.hidden = true

  buildController(root, { "#badge": badge }).connect()

  expect(inside.hidden).toBe(false) // the #161 owned binding
  expect(badge.hidden).toBe(false) // the #164 outside target, same sync pass
})

// --- Issue #176 part B: numeric threshold predicates in the cross-root map ---
// The same numeric vocabulary carries into a target's embedded predicate — the
// map already holds a parsed predicate object, so showPredicateMatches grows
// the same gte/gt/lte/lt arms as the owned-binding evaluator.

test("a numeric threshold drives an OUTSIDE target", () => {
  const root = reactiveRoot({ amount: { "#surcharge": { gte: 5000 } } })
  const amount = new FakeNode({ tag: "input", type: "number", name: "amount", value: "1000" })
  root.append(amount)
  const surcharge = new FakeNode({ tag: "aside" })
  surcharge.hidden = true

  buildController(root, { "#surcharge": surcharge }).connect()
  expect(surcharge.hidden).toBe(true) // 1000 < 5000

  amount.value = "9000"
  root.emit("input", { target: amount })
  expect(surcharge.hidden).toBe(false) // 9000 >= 5000
})

test("a non-numeric field value hides the numeric target (NaN → false), never throws", () => {
  const root = reactiveRoot({ amount: { "#surcharge": { gt: 100 } } })
  const amount = new FakeNode({ tag: "input", type: "number", name: "amount", value: "" })
  root.append(amount)
  const surcharge = new FakeNode({ tag: "aside" })

  expect(() => buildController(root, { "#surcharge": surcharge }).connect()).not.toThrow()
  expect(surcharge.hidden).toBe(true) // "" → NaN → false
})

// --- Issue #209: TARGET-KEYED multi-field conditions ---
// A "#id" key in the map carries a full DNF payload ({ any: [[term,…],…] }) —
// the SAME shape data-reactive-show holds — and folds with the same per-term
// field reads (each term resolves its OWN owned field). This is the cross-root
// multi-field case: "show the outside alert while type == trade AND price <= 0".

test("a target-keyed DNF payload ANDs TWO fields' values (both ways, both fields)", () => {
  const root = reactiveRoot({
    "#trade-warning": {
      any: [[{ field: "type", equals: "trade" }, { field: "price", lte: 0 }]],
    },
  })
  const type = new FakeNode({ tag: "select", name: "type", value: "sale" })
  const price = new FakeNode({ tag: "input", type: "number", name: "price", value: "5" })
  root.append(type, price)
  const warning = new FakeNode({ tag: "aside" })
  warning.hidden = true

  buildController(root, { "#trade-warning": warning }).connect()
  expect(warning.hidden).toBe(true) // neither matches

  type.value = "trade"
  root.emit("change", { target: type })
  expect(warning.hidden).toBe(true) // price still > 0 — AND holds it closed

  price.value = "0"
  root.emit("input", { target: price })
  expect(warning.hidden).toBe(false) // both match

  type.value = "sale"
  root.emit("change", { target: type })
  expect(warning.hidden).toBe(true) // either field leaving re-hides
})

test("target-keyed OR groups reveal when EITHER group matches", () => {
  const root = reactiveRoot({
    "#warn": {
      any: [
        [{ field: "director", equals: "true" }],
        [{ field: "role", equals: "individual" }],
      ],
    },
  })
  const director = new FakeNode({ tag: "input", type: "checkbox", name: "director", value: "on", checked: false })
  const role = new FakeNode({ tag: "select", name: "role", value: "company" })
  root.append(director, role)
  const warn = new FakeNode({ tag: "div" })

  buildController(root, { "#warn": warn }).connect()
  expect(warn.hidden).toBe(true)

  role.value = "individual"
  root.emit("change", { target: role })
  expect(warn.hidden).toBe(false) // second group

  role.value = "company"
  director.checked = true
  root.emit("change", { target: director })
  expect(warn.hidden).toBe(false) // first group
})

test("field-keyed and target-keyed entries apply in ONE pass (the mixed map)", () => {
  const root = reactiveRoot({
    mode: { "#badge": { not: "off" } }, // legacy field-keyed
    "#combo": { any: [[{ field: "mode", equals: "express" }, { field: "gift", equals: "true" }]] },
  })
  const mode = new FakeNode({ tag: "select", name: "mode", value: "express" })
  const gift = new FakeNode({ tag: "input", type: "checkbox", name: "gift", value: "on", checked: true })
  root.append(mode, gift)
  const badge = new FakeNode({ tag: "span" })
  badge.hidden = true
  const combo = new FakeNode({ tag: "div" })
  combo.hidden = true

  buildController(root, { "#badge": badge, "#combo": combo }).connect()

  expect(badge.hidden).toBe(false) // legacy arm
  expect(combo.hidden).toBe(false) // #209 arm, same sync pass
})

test("a target whose fields are ALL unowned is left alone (the single-field skip, generalized)", () => {
  const root = reactiveRoot({
    "#warn": { any: [[{ field: "inner_a", equals: "x" }, { field: "inner_b", equals: "y" }]] },
  })
  const inner = new FakeNode({ tag: "div", controller: "reactive" })
  inner.append(
    new FakeNode({ tag: "input", name: "inner_a", value: "x" }),
    new FakeNode({ tag: "input", name: "inner_b", value: "y" })
  )
  root.append(inner)
  const warn = new FakeNode({ tag: "div" })
  warn.hidden = true

  buildController(root, { "#warn": warn }).connect()
  expect(warn.hidden).toBe(true) // nested root's fields — this root never toggles
})

test("a PARTIALLY owned target folds the missing field as blank (fail-closed)", () => {
  const root = reactiveRoot({
    "#warn": { any: [[{ field: "type", equals: "trade" }, { field: "ghost", equals: "x" }]] },
  })
  const type = new FakeNode({ tag: "select", name: "type", value: "trade" })
  root.append(type)
  const warn = new FakeNode({ tag: "div" })
  warn.hidden = true

  buildController(root, { "#warn": warn }).connect()
  expect(warn.hidden).toBe(true) // ghost reads "" — the AND can never pass
})

test("a malformed target-keyed payload warn-skips while siblings still apply", () => {
  const root = reactiveRoot({
    "#bad-any": { any: "not-an-array" },
    "#bad-empty": { any: [] },
    "#ok": { any: [[{ field: "mode", equals: "on" }]] },
  })
  const mode = new FakeNode({ tag: "select", name: "mode", value: "on" })
  root.append(mode)
  const badAny = new FakeNode({ tag: "div" })
  const badEmpty = new FakeNode({ tag: "div" })
  badAny.hidden = badEmpty.hidden = true
  const ok = new FakeNode({ tag: "div" })
  ok.hidden = true

  const warns = []
  const originalWarn = console.warn
  console.warn = (msg) => warns.push(String(msg))
  try {
    expect(() =>
      buildController(root, { "#bad-any": badAny, "#bad-empty": badEmpty, "#ok": ok }).connect()
    ).not.toThrow()
  } finally {
    console.warn = originalWarn
  }

  expect(badAny.hidden).toBe(true) // malformed — untouched
  expect(badEmpty.hidden).toBe(true)
  expect(ok.hidden).toBe(false) // the sibling still applied
  expect(warns.some((w) => w.includes("reactive_show_targets"))).toBe(true)
})

test("a target-keyed NON-id key is refused (warn + skip) like the field-keyed guard", () => {
  const root = reactiveRoot({
    "#a b": { any: [[{ field: "mode", equals: "on" }]] }, // starts with # but not a single id
  })
  const mode = new FakeNode({ tag: "select", name: "mode", value: "on" })
  root.append(mode)
  const sneaky = new FakeNode({ tag: "div" })
  sneaky.hidden = true

  expect(() => buildController(root, { "#a b": sneaky }).connect()).not.toThrow()
  expect(sneaky.hidden).toBe(true)
})

test("the targets-attr gate alone enables the sync for a target-keyed-only map", () => {
  const root = reactiveRoot({
    "#warn": { any: [[{ field: "mode", equals: "on" }]] },
  })
  const mode = new FakeNode({ tag: "select", name: "mode", value: "on" })
  root.append(mode) // no owned element bindings — the attr alone must gate
  const warn = new FakeNode({ tag: "div" })
  warn.hidden = true

  buildController(root, { "#warn": warn }).connect()
  expect(warn.hidden).toBe(false)
  expect((root.listeners.input ?? []).length).toBe(2) // the sync + the editable handler
})
