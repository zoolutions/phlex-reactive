// Unit tests for the issue #228 `paste_into` client op — the clipboard-source
// trigger — and its connect()-time availability gate. Layered on the #95
// runOps interpreter like reactive_submit_op.test.js: fake nodes, no fetch
// ever, owned scoping.
//
// The op replicates what a native Cmd/Ctrl+V does to a focused field: read
// navigator.clipboard.readText() (the browser's own permission UX), write the
// text into the target field's .value, dispatch a bubbling `input` event (so
// compute reducers / show / on_complete run exactly as if the user had
// typed), then focus the field. ASYNC fire-and-forget — applyOps stays sync,
// chain siblings never wait. A rejected read, empty text, or a missing API is
// a SILENT no-op: page state must not change.
//
// The gate: on_client marks a paste trigger with data-reactive-clipboard;
// connect() (and every turbo:morph-element) sets hidden = !available on the
// OWNED marked triggers, so an authored-hidden button reveals where the API
// exists and a dead button never shows where it doesn't.
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll, afterEach } from "bun:test"

let ReactiveController

beforeAll(async () => {
  mock.module("@hotwired/stimulus", () => ({
    Controller: class {
      constructor() {}
    },
  }))
  ReactiveController = (await import("../../app/javascript/phlex/reactive/reactive_controller.js")).default
})

// bun runs the whole suite in ONE process — snapshot EVERY global these tests
// touch (navigator for the clipboard stub, plus the fetch/document/window
// stubs buildController installs) and restore them after every test so
// nothing leaks into later files (the reactive_run_ops_extended precedent).
const REAL_NAVIGATOR = globalThis.navigator
const REAL_FETCH = globalThis.fetch
const REAL_DOCUMENT = globalThis.document
const REAL_WINDOW = globalThis.window
afterEach(() => {
  globalThis.navigator = REAL_NAVIGATOR
  globalThis.fetch = REAL_FETCH
  globalThis.document = REAL_DOCUMENT
  globalThis.window = REAL_WINDOW
})

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

// A field stand-in that records the full ORDER contract in one log: the value
// each input event saw when it fired, and where the focus() call landed in
// the sequence (the contract is value → input dispatch → focus).
function makeField() {
  const field = {
    value: "",
    focused: 0,
    dispatched: [],
    closest: () => null,
    focus() {
      field.focused += 1
      field.dispatched.push({ type: "focus" })
    },
    dispatchEvent(event) {
      field.dispatched.push({ type: event.type, bubbles: event.bubbles, valueAtDispatch: field.value })
      return true
    },
  }
  return field
}

function makeRoot() {
  return {
    isConnected: true,
    id: "otp",
    contains: () => true,
    closest: () => null,
    querySelectorAll: () => [],
    getAttribute: () => null,
  }
}

function buildController(root) {
  const controller = new ReactiveController()
  controller.element = root
  globalThis.fetch = () => {
    throw new Error("runOps must NEVER fetch")
  }
  globalThis.document = {
    activeElement: null,
    querySelector: () => null,
    querySelectorAll: () => [],
    dispatchEvent: () => {},
  }
  return controller
}

function fire(controller, ops) {
  const event = {
    params: { ops },
    target: {},
    preventDefault() {},
  }
  controller.runOps(event)
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

function pasteFixture() {
  const root = makeRoot()
  const field = makeField()
  field.closest = () => root
  root.querySelectorAll = (sel) => (sel === "[name=code]" ? [field] : [])
  return { root, field, controller: buildController(root) }
}

// --- The op ---

test("paste_into writes the clipboard text, dispatches a bubbling input AFTER the write, then focuses", async () => {
  globalThis.navigator = { clipboard: { readText: async () => "123456" } }
  const { field, controller } = pasteFixture()

  fire(controller, [["paste_into", { to: "[name=code]" }]])
  await wait(0)

  expect(field.value).toBe("123456")
  // The full ordered contract: the input event fired AFTER the value write
  // (a reducer reading the field during dispatch sees the pasted value — the
  // native-paste contract), and focus came AFTER the dispatch.
  expect(field.dispatched).toEqual([
    { type: "input", bubbles: true, valueAtDispatch: "123456" },
    { type: "focus" },
  ])
  expect(field.focused).toBe(1)
})

test("an empty clipboard read is a no-op — paste NOTHING must not clear a half-typed field", async () => {
  globalThis.navigator = { clipboard: { readText: async () => "" } }
  const { field, controller } = pasteFixture()
  field.value = "12"

  fire(controller, [["paste_into", { to: "[name=code]" }]])
  await wait(0)

  expect(field.value).toBe("12")
  expect(field.dispatched).toEqual([])
  expect(field.focused).toBe(0)
})

test("a rejected read (permission denied / dismissed) is a SILENT no-op — page state unchanged", async () => {
  globalThis.navigator = {
    clipboard: {
      readText: async () => {
        throw new Error("NotAllowedError")
      },
    },
  }
  const { field, controller } = pasteFixture()
  field.value = "12"

  expect(() => fire(controller, [["paste_into", { to: "[name=code]" }]])).not.toThrow()
  await wait(0)

  expect(field.value).toBe("12")
  expect(field.dispatched).toEqual([])
  expect(field.focused).toBe(0)
})

test("a missing clipboard API is a silent sync no-op (insecure context / webview)", () => {
  globalThis.navigator = {} // no clipboard at all
  const { field, controller } = pasteFixture()

  expect(() => fire(controller, [["paste_into", { to: "[name=code]" }]])).not.toThrow()
  expect(field.value).toBe("")
  expect(field.dispatched).toEqual([])
})

test("paste_into is a KNOWN op — it never trips the unknown-op default-deny warn", async () => {
  globalThis.navigator = { clipboard: { readText: async () => "42" } }
  const { field, controller } = pasteFixture()

  const warns = captureWarnings(() => fire(controller, [["paste_into", { to: "[name=code]" }]]))
  await wait(0)

  expect(warns.filter((w) => w.includes("unknown client op"))).toEqual([])
  expect(field.value).toBe("42")
})

test("paste_into composes in a chain — sync siblings apply WITHOUT waiting for the read", async () => {
  let release
  globalThis.navigator = {
    clipboard: { readText: () => new Promise((resolve) => (release = resolve)) },
  }
  const { root, field, controller } = pasteFixture()
  const el = {
    classes: new Set(),
    closest: () => root,
    classList: {
      add(...cs) {
        cs.forEach((c) => el.classes.add(c))
      },
    },
  }
  root.querySelectorAll = (sel) => (sel === "[name=code]" ? [field] : sel === ".status" ? [el] : [])

  fire(controller, [
    ["paste_into", { to: "[name=code]" }],
    ["add_class", { to: ".status", classes: ["pasting"] }],
  ])

  // The sync sibling applied before the clipboard promise resolved.
  expect(el.classes.has("pasting")).toBe(true)
  expect(field.value).toBe("")

  release("42")
  await wait(0)
  expect(field.value).toBe("42")
})

// --- The availability gate (connect + morph) ---

// A minimal node tree for connect(): attribute-presence selectors and the
// ownership closest() walk are all the gate needs (the on_complete FakeNode
// pattern, reduced).
class FakeNode {
  constructor(attrs = {}) {
    this.attrs = { ...attrs }
    this.hidden = "hidden" in this.attrs
    this.parentNode = null
    this.children = []
    this.isConnected = true
    this.listeners = {}
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
    const presence = selector.match(/^\[([-\w]+)\]$/)
    if (presence) return presence[1] in this.attrs
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
    // The compound show-binding selector (and anything else connect probes
    // that a plain presence match can't express) resolves to no matches.
    if (selector.includes(",")) return []
    return this.#descendants().filter((n) => n.matches(selector))
  }

  // The form feature's marker check: one compound query for either marker.
  querySelector(selector) {
    if (!selector.includes("data-reactive-clipboard")) return null
    return this.#descendants().find((n) => n.matches("[data-reactive-clipboard]")) ?? null
  }

  contains() {
    return true
  }

  getAttribute(name) {
    return this.attrs[name] ?? null
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

function gateFixture({ hidden, available }) {
  globalThis.navigator = available ? { clipboard: { readText: async () => "" } } : {}
  const root = new FakeNode({ "data-controller": "reactive" })
  root.id = "otp"
  const trigger = new FakeNode({ "data-reactive-clipboard": "true", ...(hidden ? { hidden: "" } : {}) })
  root.append(trigger)
  const controller = buildController(root)
  controller.tokenValue = "tok"
  globalThis.window = { addEventListener: () => {}, removeEventListener: () => {} }
  return { root, trigger, controller }
}

test("connect() REVEALS an authored-hidden paste trigger when the clipboard API exists", () => {
  const { trigger, controller } = gateFixture({ hidden: true, available: true })

  controller.connect()

  expect(trigger.hidden).toBe(false)
})

test("connect() HIDES a paste trigger when the clipboard API is missing — a dead button never shows", () => {
  const { trigger, controller } = gateFixture({ hidden: false, available: false })

  controller.connect()

  expect(trigger.hidden).toBe(true)
})

test("a turbo:morph-element re-runs the gate (the morph re-rendered the authored hidden state)", () => {
  const { root, trigger, controller } = gateFixture({ hidden: true, available: true })
  controller.connect()

  trigger.hidden = true // the morph rewrote the trigger back to its authored state
  root.emit("turbo:morph-element")

  expect(trigger.hidden).toBe(false)
})

test("a marker on the ROOT itself is gated too (a button-only component mixes on_client onto reactive_root)", () => {
  globalThis.navigator = { clipboard: { readText: async () => "" } }
  const root = new FakeNode({ "data-controller": "reactive", "data-reactive-clipboard": "true", hidden: "" })
  root.id = "paste-button"
  const controller = buildController(root)
  controller.tokenValue = "tok"
  globalThis.window = { addEventListener: () => {}, removeEventListener: () => {} }

  controller.connect()

  expect(root.hidden).toBe(false) // revealed: the root IS the trigger
})

test("a ROOT trigger is hidden when the API is missing (the whole component IS the dead button)", () => {
  globalThis.navigator = {}
  const root = new FakeNode({ "data-controller": "reactive", "data-reactive-clipboard": "true" })
  root.id = "paste-button"
  const controller = buildController(root)
  controller.tokenValue = "tok"
  globalThis.window = { addEventListener: () => {}, removeEventListener: () => {} }

  controller.connect()

  expect(root.hidden).toBe(true)
})

test("a NESTED reactive root's trigger is left to its own controller (issue #15 ownership)", () => {
  const { root, controller } = gateFixture({ hidden: false, available: false })
  const nested = new FakeNode({ "data-controller": "reactive" })
  const nestedTrigger = new FakeNode({ "data-reactive-clipboard": "true" })
  nested.append(nestedTrigger)
  root.append(nested)

  controller.connect()

  expect(nestedTrigger.hidden).toBe(false) // untouched — not ours
})

test("a root with NO marked trigger never wires the morph listener (the gated-pass contract)", () => {
  globalThis.navigator = {}
  const root = new FakeNode({ "data-controller": "reactive" })
  root.id = "plain"
  const controller = buildController(root)
  controller.tokenValue = "tok"
  globalThis.window = { addEventListener: () => {}, removeEventListener: () => {} }

  controller.connect()

  expect((root.listeners["turbo:morph-element"] ?? []).length).toBe(0)
})

test("disconnect() removes the gate's morph listener", () => {
  const { root, controller } = gateFixture({ hidden: true, available: true })
  controller.connect()
  const before = (root.listeners["turbo:morph-element"] ?? []).length

  controller.disconnect()

  expect(before).toBeGreaterThan(0)
  expect((root.listeners["turbo:morph-element"] ?? []).length).toBe(0)
})
