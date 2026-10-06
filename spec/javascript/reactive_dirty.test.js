// Unit tests for dirty-field tracking (issue #103).
//
// The browser already holds the last server-rendered value with ZERO shipped
// state: input.defaultValue / defaultChecked / option.defaultSelected ARE the
// attributes from the last server render. dirty = current ≠ default. trackDirty
// runs #scanDirty(), a FULL PASS over every field this reactive root owns:
//
//   checkbox/radio → checked  !== defaultChecked
//   select         → some option.selected !== option.defaultSelected
//   else           → value    !== defaultValue
//
// A full pass (not a per-target toggle) is REQUIRED for radio groups: when a new
// radio is selected the previously-checked one flips to checked=false and fires
// NO input event — only re-scanning every owned field keeps its flag honest.
//
// Each dirty field gets data-reactive-dirty="true"; the root carries
// data-reactive-dirty="<count>" (absent at zero). Baselines RESET on a server
// re-render: connect() re-scans (a plain replace re-connects Stimulus), and a
// turbo:morph-element listener re-scans after an in-place morph (which keeps the
// element CONNECTED and fires no Stimulus lifecycle). warn_unsaved arms a
// beforeunload / turbo:before-visit guard gated on a LIVE dirty-count read.
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

// A minimal field/element stub faithful enough for #scanDirty():
//   - type/value/defaultValue/checked/defaultChecked/options (per control kind)
//   - data-controller for the reactive-root ownership predicate
//   - dataset-backed setAttribute/getAttribute/removeAttribute + a listener log
class FakeNode {
  constructor(opts = {}) {
    const {
      tag = "div",
      name = null,
      type = null,
      value = "",
      defaultValue = "",
      checked = false,
      defaultChecked = false,
      options = null,
      controller = null,
    } = opts
    this.tag = tag.toLowerCase()
    this.name = name
    this.type = type
    this.value = value
    this.defaultValue = defaultValue
    this.checked = checked
    this.defaultChecked = defaultChecked
    this.options = options // [{ selected, defaultSelected }, ...] for <select>
    this.parentNode = null
    this.children = []
    this.attrs = {}
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
    // The dirty-tracking opt-in probe (#dirtyTrackingEnabled): any element whose
    // data-action carries the trackDirty descriptor.
    if (selector === '[data-action*="reactive#trackDirty"]') {
      return (this.attrs["data-action"] ?? "").includes("reactive#trackDirty")
    }
    // #scanDirty scans the same control set as #collectFields.
    const wantsField = ["input", "select", "textarea"].some((t) => selector.includes(`${t}[name]`))
    if (wantsField) return ["input", "select", "textarea"].includes(this.tag) && this.name != null
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
  return new FakeNode({ tag: "div", controller: "reactive", ...extra })
}

// A reactive root that has opted into dirty tracking (track_dirty: → the
// trackDirty descriptor rides its own data-action). connect() only wires the
// baseline scan / morph listener / warn_unsaved guard for such a root.
function dirtyRoot(extra = {}) {
  const root = reactiveRoot(extra)
  root.setAttribute("data-action", "input->reactive#trackDirty")
  return root
}

test("a changed text input is marked dirty and the root carries the count", () => {
  const root = reactiveRoot()
  const title = new FakeNode({ tag: "input", type: "text", name: "title", value: "new", defaultValue: "old" })
  root.append(title)

  const controller = buildController(root)
  controller.trackDirty({ target: title })

  expect(title.getAttribute("data-reactive-dirty")).toBe("true")
  expect(root.getAttribute("data-reactive-dirty")).toBe("1")
})

test("an unchanged text input is NOT dirty and the root has no count", () => {
  const root = reactiveRoot()
  const title = new FakeNode({ tag: "input", type: "text", name: "title", value: "same", defaultValue: "same" })
  root.append(title)

  const controller = buildController(root)
  controller.trackDirty({ target: title })

  expect(title.getAttribute("data-reactive-dirty")).toBeNull()
  expect(root.getAttribute("data-reactive-dirty")).toBeNull()
})

test("editing then reverting a field clears the dirty flag (full re-scan, not sticky)", () => {
  const root = reactiveRoot()
  const title = new FakeNode({ tag: "input", type: "text", name: "title", value: "new", defaultValue: "old" })
  root.append(title)
  const controller = buildController(root)

  controller.trackDirty({ target: title })
  expect(title.getAttribute("data-reactive-dirty")).toBe("true")
  expect(root.getAttribute("data-reactive-dirty")).toBe("1")

  // User types the original value back — now equal to the default.
  title.value = "old"
  controller.trackDirty({ target: title })
  expect(title.getAttribute("data-reactive-dirty")).toBeNull()
  expect(root.getAttribute("data-reactive-dirty")).toBeNull()
})

test("a checkbox is dirty iff checked !== defaultChecked", () => {
  const root = reactiveRoot()
  const done = new FakeNode({ tag: "input", type: "checkbox", name: "done", checked: true, defaultChecked: false })
  root.append(done)
  const controller = buildController(root)

  controller.trackDirty({ target: done })
  expect(done.getAttribute("data-reactive-dirty")).toBe("true")
  expect(root.getAttribute("data-reactive-dirty")).toBe("1")

  // Toggle back to its default → clean.
  done.checked = false
  controller.trackDirty({ target: done })
  expect(done.getAttribute("data-reactive-dirty")).toBeNull()
  expect(root.getAttribute("data-reactive-dirty")).toBeNull()
})

test("a select is dirty when any option's selected !== defaultSelected", () => {
  const root = reactiveRoot()
  // Default selection was option 0; the user picked option 1.
  const status = new FakeNode({
    tag: "select",
    name: "status",
    options: [
      { selected: false, defaultSelected: true },
      { selected: true, defaultSelected: false },
    ],
  })
  root.append(status)
  const controller = buildController(root)

  controller.trackDirty({ target: status })
  expect(status.getAttribute("data-reactive-dirty")).toBe("true")
  expect(root.getAttribute("data-reactive-dirty")).toBe("1")
})

test("a select back at its default selection is NOT dirty", () => {
  const root = reactiveRoot()
  const status = new FakeNode({
    tag: "select",
    name: "status",
    options: [
      { selected: true, defaultSelected: true },
      { selected: false, defaultSelected: false },
    ],
  })
  root.append(status)
  const controller = buildController(root)

  controller.trackDirty({ target: status })
  expect(status.getAttribute("data-reactive-dirty")).toBeNull()
  expect(root.getAttribute("data-reactive-dirty")).toBeNull()
})

// Issue #297: a single <select> with no `selected` option. The browser selects
// the first (enabled) option, but its defaultSelected stays false — the select's
// RESET state is that first option, so a pristine form must scan clean.
test("a pristine single select with no selected option is NOT dirty (issue #297)", () => {
  const root = reactiveRoot()
  const status = new FakeNode({
    tag: "select",
    name: "status",
    options: [
      { selected: true, defaultSelected: false },
      { selected: false, defaultSelected: false },
    ],
  })
  root.append(status)
  const controller = buildController(root)

  controller.trackDirty({ target: status })
  expect(status.getAttribute("data-reactive-dirty")).toBeNull()
  expect(root.getAttribute("data-reactive-dirty")).toBeNull()

  // Picking another option IS a change from that reset state.
  status.options[0].selected = false
  status.options[1].selected = true
  controller.trackDirty({ target: status })
  expect(status.getAttribute("data-reactive-dirty")).toBe("true")
})

test("the reset state of a select with no selected option skips a disabled first option (issue #297)", () => {
  const root = reactiveRoot()
  const status = new FakeNode({
    tag: "select",
    name: "status",
    options: [
      { selected: false, defaultSelected: false, disabled: true },
      { selected: true, defaultSelected: false },
    ],
  })
  root.append(status)
  const controller = buildController(root)

  controller.trackDirty({ target: status })
  expect(status.getAttribute("data-reactive-dirty")).toBeNull()
})

test("a multiple select with nothing selected by default stays clean until an option is picked", () => {
  const root = reactiveRoot()
  const tags = new FakeNode({
    tag: "select",
    name: "tags",
    options: [
      { selected: false, defaultSelected: false },
      { selected: false, defaultSelected: false },
    ],
  })
  tags.multiple = true
  root.append(tags)
  const controller = buildController(root)

  controller.trackDirty({ target: tags })
  expect(tags.getAttribute("data-reactive-dirty")).toBeNull()

  tags.options[0].selected = true
  controller.trackDirty({ target: tags })
  expect(tags.getAttribute("data-reactive-dirty")).toBe("true")
})

test("radio group: selecting a new radio marks the deselected default radio dirty too (full pass)", () => {
  // The decisive full-pass case. The default was radio A (defaultChecked). The
  // user picks radio B. B fires the input event; A gets NO event but flipped to
  // checked=false — so a per-target toggle would leave A stale. #scanDirty
  // re-scans EVERY owned field, catching both.
  const root = reactiveRoot()
  const a = new FakeNode({ tag: "input", type: "radio", name: "size", value: "s", checked: false, defaultChecked: true })
  const b = new FakeNode({ tag: "input", type: "radio", name: "size", value: "m", checked: true, defaultChecked: false })
  root.append(a, b)
  const controller = buildController(root)

  // Only B fired the event, but the full pass evaluates both.
  controller.trackDirty({ target: b })

  expect(a.getAttribute("data-reactive-dirty")).toBe("true") // deselected default
  expect(b.getAttribute("data-reactive-dirty")).toBe("true") // newly selected
  expect(root.getAttribute("data-reactive-dirty")).toBe("2")
})

test("radio group: re-selecting the default clears both flags", () => {
  const root = reactiveRoot()
  const a = new FakeNode({ tag: "input", type: "radio", name: "size", value: "s", checked: true, defaultChecked: true })
  const b = new FakeNode({ tag: "input", type: "radio", name: "size", value: "m", checked: false, defaultChecked: false })
  root.append(a, b)
  const controller = buildController(root)

  controller.trackDirty({ target: a })
  expect(a.getAttribute("data-reactive-dirty")).toBeNull()
  expect(b.getAttribute("data-reactive-dirty")).toBeNull()
  expect(root.getAttribute("data-reactive-dirty")).toBeNull()
})

test("nested reactive root: an outer scan ignores an inner root's fields (issue #15 ownership)", () => {
  const outer = reactiveRoot()
  const outerField = new FakeNode({ tag: "input", type: "text", name: "notes", value: "changed", defaultValue: "orig" })
  const inner = reactiveRoot()
  const innerField = new FakeNode({ tag: "input", type: "text", name: "q", value: "changed", defaultValue: "orig" })
  inner.append(innerField)
  outer.append(outerField, inner)

  const controller = buildController(outer)
  controller.trackDirty({ target: outerField })

  // Only the outer field counts toward the outer root.
  expect(outerField.getAttribute("data-reactive-dirty")).toBe("true")
  expect(innerField.getAttribute("data-reactive-dirty")).toBeNull()
  expect(outer.getAttribute("data-reactive-dirty")).toBe("1")
})

test("file inputs are skipped (no meaningful default baseline)", () => {
  const root = reactiveRoot()
  const upload = new FakeNode({ tag: "input", type: "file", name: "doc", value: "C:\\fakepath\\x.pdf", defaultValue: "" })
  root.append(upload)
  const controller = buildController(root)

  controller.trackDirty({ target: upload })
  expect(upload.getAttribute("data-reactive-dirty")).toBeNull()
  expect(root.getAttribute("data-reactive-dirty")).toBeNull()
})

test("connect() seeds the baseline scan (a plain replace re-connects → re-scan)", () => {
  const root = dirtyRoot()
  root.id = "form"
  const dirtyField = new FakeNode({ tag: "input", type: "text", name: "title", value: "server-new", defaultValue: "server-old" })
  root.append(dirtyField)
  const controller = buildController(root)

  controller.connect()

  // On connect the root reflects the current-vs-default diff immediately, without
  // waiting for an input event.
  expect(dirtyField.getAttribute("data-reactive-dirty")).toBe("true")
  expect(root.getAttribute("data-reactive-dirty")).toBe("1")
})

test("a turbo:morph-element on the root re-scans (morph keeps it connected, no Stimulus lifecycle)", () => {
  const root = dirtyRoot()
  root.id = "form"
  const field = new FakeNode({ tag: "input", type: "text", name: "title", value: "x", defaultValue: "old" })
  root.append(field)
  const controller = buildController(root)

  controller.connect() // registers the morph listener + seeds a scan
  expect(field.getAttribute("data-reactive-dirty")).toBe("true") // x !== old
  expect(root.getAttribute("data-reactive-dirty")).toBe("1")

  // Server morph writes a fresh default that NOW equals the field value (Turbo 8
  // preserves the focused value, writes fresh default attrs) → post-morph re-scan
  // must find it clean.
  field.defaultValue = "x"
  root.emit("turbo:morph-element", { target: root })

  expect(field.getAttribute("data-reactive-dirty")).toBeNull()
  expect(root.getAttribute("data-reactive-dirty")).toBeNull()
})

test("disconnect() removes the morph-element listener (no re-scan after teardown)", () => {
  const root = dirtyRoot()
  root.id = "form"
  const field = new FakeNode({ tag: "input", type: "text", name: "title", value: "x", defaultValue: "x" })
  root.append(field)
  const controller = buildController(root)

  controller.connect()
  controller.disconnect()

  // After disconnect, a stray morph event must not run a scan (the listener is gone).
  field.value = "changed"
  root.emit("turbo:morph-element", { target: root })
  expect(root.getAttribute("data-reactive-dirty")).toBeNull()
})

test("warn_unsaved arms a beforeunload guard gated on the LIVE dirty count", () => {
  const winListeners = {}
  const win = {
    addEventListener: (name, fn) => ((winListeners[name] ??= []).push(fn)),
    removeEventListener: (name, fn) => (winListeners[name] = (winListeners[name] ?? []).filter((f) => f !== fn)),
  }
  const root = dirtyRoot()
  root.id = "form"
  root.setAttribute("data-reactive-warn-unsaved", "true")
  const field = new FakeNode({ tag: "input", type: "text", name: "title", value: "same", defaultValue: "same" })
  root.append(field)

  const controller = buildController(root)
  globalThis.window = win
  controller.connect()

  // Clean form → the beforeunload handler does NOT block navigation.
  const cleanEvent = { preventDefault: () => {} }
  const beforeunload = winListeners.beforeunload?.[0]
  expect(typeof beforeunload).toBe("function")
  expect(beforeunload(cleanEvent)).toBeUndefined()

  // Dirty the form and re-scan; now the SAME handler blocks (returnValue set).
  field.value = "changed"
  controller.trackDirty({ target: field })
  expect(root.getAttribute("data-reactive-dirty")).toBe("1")

  const dirtyEvent = {}
  let prevented = false
  dirtyEvent.preventDefault = () => (prevented = true)
  const result = beforeunload(dirtyEvent)
  expect(prevented).toBe(true)
  expect(dirtyEvent.returnValue).toBeTruthy()
  expect(result).toBeTruthy()
})

test("warn_unsaved: turbo:before-visit is vetoed while dirty and allowed when clean", () => {
  const winListeners = {}
  const win = {
    addEventListener: (name, fn) => ((winListeners[name] ??= []).push(fn)),
    removeEventListener: () => {},
  }
  const root = dirtyRoot()
  root.id = "form"
  root.setAttribute("data-reactive-warn-unsaved", "true")
  const field = new FakeNode({ tag: "input", type: "text", name: "title", value: "orig", defaultValue: "orig" })
  root.append(field)

  const controller = buildController(root)
  globalThis.window = win
  // confirm() decides the veto; stub it to decline (stay on page).
  win.confirm = () => false
  controller.connect()

  const beforeVisit = winListeners["turbo:before-visit"]?.[0]
  expect(typeof beforeVisit).toBe("function")

  // Clean → visit proceeds (no preventDefault).
  let cleanPrevented = false
  beforeVisit({ preventDefault: () => (cleanPrevented = true) })
  expect(cleanPrevented).toBe(false)

  // Dirty + user declines the confirm → the visit is vetoed.
  field.value = "changed"
  controller.trackDirty({ target: field })
  let dirtyPrevented = false
  beforeVisit({ preventDefault: () => (dirtyPrevented = true) })
  expect(dirtyPrevented).toBe(true)
})

test("no warn_unsaved marker → no navigate-away guard registered", () => {
  const winListeners = {}
  const win = {
    addEventListener: (name, fn) => ((winListeners[name] ??= []).push(fn)),
    removeEventListener: () => {},
  }
  // Dirty tracking IS on (so connect wires the scan/morph listener), but the
  // warn-unsaved marker is absent — so no navigate-away guard is armed. This
  // proves the MARKER gates the guard, not merely the absence of tracking.
  const root = dirtyRoot() // no data-reactive-warn-unsaved
  root.id = "form"
  buildController(root)
  globalThis.window = win

  const controller = new ReactiveController()
  controller.element = root
  controller.tokenValue = "tok"
  controller.connect()

  expect(winListeners.beforeunload).toBeUndefined()
  expect(winListeners["turbo:before-visit"]).toBeUndefined()
})

test("connect() does NOT wire dirty tracking for a root that never opted in", () => {
  const winListeners = {}
  const win = {
    addEventListener: (name, fn) => ((winListeners[name] ??= []).push(fn)),
    removeEventListener: () => {},
  }
  // A plain reactive root (no track_dirty:, no dirty: field) — connect must not
  // register the morph listener, run a baseline scan, or arm any guard.
  const root = reactiveRoot()
  root.id = "form"
  root.setAttribute("data-reactive-warn-unsaved", "true") // present, but tracking is OFF
  const field = new FakeNode({ tag: "input", type: "text", name: "title", value: "changed", defaultValue: "orig" })
  root.append(field)

  const controller = buildController(root)
  globalThis.window = win
  controller.connect()

  // No baseline scan ran (the changed field is NOT marked, root has no count).
  expect(field.getAttribute("data-reactive-dirty")).toBeNull()
  expect(root.getAttribute("data-reactive-dirty")).toBeNull()
  // No morph listener, no navigate-away guard.
  expect((root.listeners["turbo:morph-element"] ?? []).length).toBe(0)
  expect(winListeners.beforeunload).toBeUndefined()
})
