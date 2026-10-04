// Unit tests for reactive_on_complete (issue #226) — the DECLARATIVE
// completion binding. The root carries data-reactive-on-complete: a JSON array
// of { any: DNF groups, ops: [[op, args], …] } bindings. connect() gates on
// the attr, installs ONE delegated input/change listener, evaluates each
// binding's conditions over the owned fields (the same scope-aware resolver
// and DNF fold the show sync uses), and runs its ops on the RISING EDGE —
// event-driven flip to true. The connect/morph pass ARMS without firing (a
// fresh render with already-satisfied conditions must never self-fire — the
// $ops seed precedent); going false re-arms. Ops run through the frozen
// CLIENT_OPS whitelist with runOps's root-scoped target resolution.
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

// The FakeNode stub the show-sync tests use (self-contained per suite
// convention), plus dispatchEvent recording for the dispatch op.
class FakeNode {
  constructor(opts = {}) {
    const { tag = "div", name = null, type = null, value = "", checked = false, controller = null, attrs = {} } = opts
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
    this.dispatched = []
    this.classes = new Set()
    this.classList = {
      add: (...cs) => cs.forEach((c) => this.classes.add(c)),
      remove: (...cs) => cs.forEach((c) => this.classes.delete(c)),
      toggle: (c) => (this.classes.has(c) ? this.classes.delete(c) : this.classes.add(c)),
    }
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
    if (selector === "[data-reactive-show-field], [data-reactive-show]") {
      return "data-reactive-show-field" in this.attrs || "data-reactive-show" in this.attrs
    }
    if (selector === '[data-action*="reactive#trackDirty"]') {
      return (this.attrs["data-action"] ?? "").includes("reactive#trackDirty")
    }
    if (selector === ".status") return (this.attrs.class ?? "").includes("status")
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
  // Records the ops' events only: every connect() also announces itself with
  // reactive:connect (issue #273), which is not what these tests count.
  dispatchEvent(event) {
    if (event.type !== "reactive:connect") this.dispatched.push(event)
    return true
  }
}

// No CustomEvent stub: bun's native CustomEvent carries type/detail, which is
// all these tests read — and a bare recorder class left on globalThis would
// break every later file whose events need cancelable/preventDefault (bun runs
// the whole suite in ONE process; the CI-order lifecycle failure proved it).
function buildController(rootEl) {
  const controller = new ReactiveController()
  controller.element = rootEl
  controller.tokenValue = "tok"
  globalThis.document = { querySelector: () => null, dispatchEvent: () => {} }
  globalThis.window = { addEventListener: () => {}, removeEventListener: () => {} }
  return controller
}

const COMPLETE_AT_SIX = JSON.stringify([
  { any: [[{ field: "code", len_eq: 6 }]], ops: [["dispatch", { name: "code:complete" }]] },
])

function otpRoot({ payload = COMPLETE_AT_SIX, value = "", scope = null } = {}) {
  const attrs = { "data-reactive-on-complete": payload }
  if (scope) attrs["data-reactive-scope"] = scope
  const root = new FakeNode({ tag: "form", controller: "reactive", attrs })
  root.id = "otp"
  const code = new FakeNode({ tag: "input", name: scope ? `${scope}[code]` : "code", value })
  root.append(code)
  return { root, code }
}

function captureWarnings(fn) {
  const warns = []
  const original = console.warn
  console.warn = (...args) => warns.push(args.join(" "))
  try {
    fn()
  } finally {
    console.warn = original
  }
  return warns
}

test("connect() with already-satisfied conditions ARMS without firing", () => {
  const { root, code } = otpRoot({ value: "123456" })
  buildController(root).connect()

  expect(root.dispatched.length).toBe(0)

  // A later event with the conditions STILL true is no rising edge either.
  root.emit("input", { target: code })
  expect(root.dispatched.length).toBe(0)
})

test("an event-driven flip to true fires the ops exactly once", () => {
  const { root, code } = otpRoot({ value: "12345" })
  buildController(root).connect()

  code.value = "123456"
  root.emit("input", { target: code })
  expect(root.dispatched.map((e) => e.type)).toEqual(["code:complete"])

  // Still true → settled, no re-fire.
  root.emit("input", { target: code })
  expect(root.dispatched.length).toBe(1)
})

test("going false re-arms; the next flip fires again", () => {
  const { root, code } = otpRoot({ value: "" })
  buildController(root).connect()

  code.value = "123456"
  root.emit("input", { target: code })
  code.value = "12345"
  root.emit("input", { target: code })
  code.value = "123456"
  root.emit("change", { target: code }) // change counts as a gesture too
  expect(root.dispatched.length).toBe(2)
})

test("a turbo:morph-element pass arms without firing (no gesture)", () => {
  const { root, code } = otpRoot({ value: "" })
  buildController(root).connect()

  code.value = "123456" // the morph rewrote the field to a complete value
  root.emit("turbo:morph-element")
  expect(root.dispatched.length).toBe(0)

  // Still-true events after the morph stay settled.
  root.emit("input", { target: code })
  expect(root.dispatched.length).toBe(0)
})

test("multiple bindings latch independently", () => {
  const payload = JSON.stringify([
    { any: [[{ field: "code", len_eq: 6 }]], ops: [["dispatch", { name: "code:complete" }]] },
    { any: [[{ field: "kind", equals: "sms" }]], ops: [["dispatch", { name: "kind:sms" }]] },
  ])
  const root = new FakeNode({ tag: "form", controller: "reactive", attrs: { "data-reactive-on-complete": payload } })
  root.id = "otp"
  const code = new FakeNode({ tag: "input", name: "code", value: "" })
  const kind = new FakeNode({ tag: "select", name: "kind", value: "email" })
  root.append(code, kind)
  buildController(root).connect()

  kind.value = "sms"
  root.emit("change", { target: kind })
  expect(root.dispatched.map((e) => e.type)).toEqual(["kind:sms"])

  code.value = "123456"
  root.emit("input", { target: code })
  expect(root.dispatched.map((e) => e.type)).toEqual(["kind:sms", "code:complete"])
})

test("scope-aware: a bare condition field resolves through data-reactive-scope", () => {
  const { root, code } = otpRoot({ value: "", scope: "order" })
  buildController(root).connect()

  code.value = "123456"
  root.emit("input", { target: code })
  expect(root.dispatched.map((e) => e.type)).toEqual(["code:complete"])
})

test("ops resolve selector targets within the root (class op on an owned node)", () => {
  const payload = JSON.stringify([
    { any: [[{ field: "code", len_eq: 6 }]], ops: [["add_class", { to: ".status", classes: ["done"] }]] },
  ])
  const { root, code } = otpRoot({ payload })
  const status = new FakeNode({ tag: "p", attrs: { class: "status" } })
  root.append(status)
  buildController(root).connect()

  code.value = "123456"
  root.emit("input", { target: code })
  expect(status.classes.has("done")).toBe(true)
})

test("a malformed payload warns and never fires or throws", () => {
  const { root, code } = otpRoot({ payload: "{not json" })
  const warns = captureWarnings(() => {
    buildController(root).connect()
    code.value = "123456"
    root.emit("input", { target: code })
  })

  expect(warns.some((w) => w.includes("reactive_on_complete"))).toBe(true)
  expect(root.dispatched.length).toBe(0)
})

test("disconnect() removes the listeners (no fire after teardown)", () => {
  const { root, code } = otpRoot({ value: "" })
  const controller = buildController(root)
  controller.connect()
  controller.disconnect()

  code.value = "123456"
  root.emit("input", { target: code })
  expect(root.dispatched.length).toBe(0)
})
