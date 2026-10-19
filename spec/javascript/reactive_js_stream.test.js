// Unit tests for the `reactive:js` custom Turbo StreamAction (issue #97) — the
// server-pushed sibling of runOps. The server emits
//
//   <turbo-stream action="reactive:js" data-reactive-ops="[[...ops...]]"
//                 target="<optional root id>"></turbo-stream>
//
// and Turbo invokes the registered handler with `this` bound to that
// <turbo-stream> element. The handler:
//
//   * reads data-reactive-ops (the SAME serialized op format as #95/#96),
//   * scopes op resolution to `target` (an element id) when present, else the
//     document,
//   * runs them through the SAME whitelist interpreter as runOps (an unknown op
//     warns + is skipped — client-side default-deny), and
//   * NEVER fetches, NEVER touches a token.
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll, afterEach } from "bun:test"

let registerReactiveJs
let registerReactiveActions

beforeAll(async () => {
  mock.module("@hotwired/stimulus", () => ({
    Controller: class {
      constructor() {}
    },
  }))
  const mod = await import("../../app/javascript/phlex/reactive/reactive_controller.js")
  registerReactiveJs = mod.registerReactiveJs
  registerReactiveActions = mod.registerReactiveActions
})

// A fake element: hidden flag, classList over a Set, focus tracking, and a
// dispatchEvent recorder. `id` + membership are answered by the fake document.
function makeEl(id) {
  const el = {
    id,
    hidden: false,
    classes: new Set(),
    focused: false,
    dispatched: [],
    focus() {
      el.focused = true
    },
    dispatchEvent(event) {
      el.dispatched.push(event)
    },
  }
  el.classList = {
    add: (...cs) => cs.forEach((c) => el.classes.add(c)),
    remove: (...cs) => cs.forEach((c) => el.classes.delete(c)),
    toggle: (c) => (el.classes.has(c) ? el.classes.delete(c) : el.classes.add(c)),
  }
  el.querySelectorAll = () => []
  return el
}

// Build a fake document whose getElementById + querySelectorAll answer from
// maps. A scoped root's querySelectorAll and the document's querySelectorAll are
// kept distinct so we can prove `target` scopes op resolution to that root.
function stubDocument({ byId = {}, docMatches = {} } = {}) {
  globalThis.document = {
    getElementById: (id) => byId[id] ?? null,
    querySelectorAll: (sel) => docMatches[sel] ?? [],
  }
  return globalThis.document
}

// A real CustomEvent-ish stand-in (bun has CustomEvent, but keep the interpreter
// honest by not relying on its exact shape).
function stubTurbo() {
  globalThis.window = { Turbo: { StreamActions: {} } }
  return globalThis.window.Turbo.StreamActions
}

// A fake <turbo-stream> element carrying the ops attr + optional target.
function streamEl({ ops, target } = {}) {
  const attrs = { "data-reactive-ops": ops }
  if (target != null) attrs.target = target
  return {
    getAttribute: (name) => attrs[name] ?? null,
  }
}

function invoke(actions, el) {
  // Turbo calls the action with `this` bound to the stream element.
  actions["reactive:js"].call(el)
}

// --- registration -----------------------------------------------------------

test("registerReactiveJs installs the reactive:js StreamAction (idempotent)", () => {
  const actions = stubTurbo()
  registerReactiveJs()
  expect(typeof actions["reactive:js"]).toBe("function")

  const first = actions["reactive:js"]
  registerReactiveJs()
  expect(actions["reactive:js"]).toBe(first) // not re-registered
})

test("registerReactiveActions wires reactive:js alongside visit + token", () => {
  const actions = stubTurbo()
  registerReactiveActions()
  expect(typeof actions["reactive:visit"]).toBe("function")
  expect(typeof actions["reactive:token"]).toBe("function")
  expect(typeof actions["reactive:js"]).toBe("function")
})

// --- op execution through the shared whitelist ------------------------------

test("runs ops through the shared interpreter (class + focus + dispatch)", () => {
  const actions = stubTurbo()
  registerReactiveJs()
  const frames = stubFrames()
  const bell = makeEl("bell")
  const field = makeEl("field")
  stubDocument({ docMatches: { "#bell": [bell], "[name=next]": [field] } })

  invoke(
    actions,
    streamEl({
      ops: JSON.stringify([
        ["add_class", { to: "#bell", classes: ["has-unread"] }],
        ["focus", { to: "[name=next]" }],
      ]),
    }),
  )

  expect([...bell.classes]).toEqual(["has-unread"])
  frames.frame() // a focus op waits one frame (issue #446)
  expect(field.focused).toBe(true)
})

test("target scopes op resolution to that root (querySelectorAll on the root, not document)", () => {
  const actions = stubTurbo()
  registerReactiveJs()
  const scopedMatch = makeEl("inside")
  const root = makeEl("todo_7")
  root.querySelectorAll = (sel) => (sel === ".panel" ? [scopedMatch] : [])
  // The document must NOT be consulted when a target root is given.
  const doc = stubDocument({ byId: { todo_7: root } })
  doc.querySelectorAll = () => {
    throw new Error("must resolve within the target root, not the document")
  }

  invoke(actions, streamEl({ ops: JSON.stringify([["hide", { to: ".panel" }]]), target: "todo_7" }))

  expect(scopedMatch.hidden).toBe(true)
})

test("@root with a target resolves to the target element itself", () => {
  const actions = stubTurbo()
  registerReactiveJs()
  const root = makeEl("panel")
  stubDocument({ byId: { panel: root } })

  invoke(actions, streamEl({ ops: JSON.stringify([["toggle", { to: "@root" }]]), target: "panel" }))

  expect(root.hidden).toBe(true)
})

test("expanded: resolves through the stream's resolver (issue #271)", () => {
  const actions = stubTurbo()
  registerReactiveJs()
  const menu = makeEl("menu")
  const trigger = makeEl("trigger")
  trigger.attrs = {}
  trigger.setAttribute = (n, v) => (trigger.attrs[n] = String(v))
  menu.hidden = true
  stubDocument({ docMatches: { "#menu": [menu], "#trigger": [trigger] } })

  invoke(actions, streamEl({ ops: JSON.stringify([["toggle", { to: "#menu", expanded: "#trigger" }]]) }))

  expect(menu.hidden).toBe(false)
  expect(trigger.attrs["aria-expanded"]).toBe("true")
})

test("a missing target element is a no-op (never throws)", () => {
  const actions = stubTurbo()
  registerReactiveJs()
  stubDocument({ byId: {} })

  expect(() =>
    invoke(actions, streamEl({ ops: JSON.stringify([["hide", { to: "@root" }]]), target: "gone" })),
  ).not.toThrow()
})

// --- default-deny + resilience ----------------------------------------------

test("an unknown op warns + is skipped; the rest of the chain still applies", () => {
  const actions = stubTurbo()
  registerReactiveJs()
  const el = makeEl("x")
  stubDocument({ docMatches: { "#x": [el] } })
  const warns = []
  const original = console.warn
  console.warn = (...args) => warns.push(args.join(" "))

  try {
    invoke(
      actions,
      streamEl({ ops: JSON.stringify([["explode", { to: "#x" }], ["hide", { to: "#x" }]]) }),
    )
  } finally {
    console.warn = original
  }

  expect(warns.length).toBe(1)
  expect(warns[0]).toContain("explode")
  expect(el.hidden).toBe(true)
})

test("a refused attr op (event handler) warns + is skipped by the interpreter", () => {
  const actions = stubTurbo()
  registerReactiveJs()
  const el = makeEl("x")
  el.setAttribute = () => {
    throw new Error("must not set a refused attr")
  }
  el.hasAttribute = () => false
  stubDocument({ docMatches: { "#x": [el] } })
  const warns = []
  const original = console.warn
  console.warn = (...args) => warns.push(args.join(" "))

  try {
    invoke(actions, streamEl({ ops: JSON.stringify([["set_attr", { to: "#x", name: "onclick", value: "alert(1)" }]]) }))
  } finally {
    console.warn = original
  }

  expect(warns.length).toBe(1)
  expect(warns[0]).toContain("onclick")
})

test("a missing/garbage ops attr degrades to a no-op", () => {
  const actions = stubTurbo()
  registerReactiveJs()
  stubDocument({})

  expect(() => invoke(actions, streamEl({ ops: null }))).not.toThrow()
  expect(() => invoke(actions, streamEl({ ops: "not json" }))).not.toThrow()
  expect(() => invoke(actions, streamEl({ ops: "{}" }))).not.toThrow()
})

// --- focus ops wait for Turbo's focus restore (issue #446) --------------------
// Turbo renders a stream message inside withPreservedFocus: it reads
// document.activeElement, appends the <turbo-stream>s, waits one animation
// frame, reads it again and — when the element focused before has an id and
// focus moved — focuses that element again. Each stream's action runs behind a
// frame queued BEFORE that compare, so a focus op applied there would be
// undone (and the old field's focus binding would run again). The action
// leaves focus alone until the compare has seen nothing move, then applies
// the focus op, and the rest of its chain, on the next frame.

// bun has no requestAnimationFrame: a queue the test runs one frame at a time.
// A callback queued while a frame runs waits for the next one, like a browser.
const REAL_RAF = globalThis.requestAnimationFrame
afterEach(() => {
  if (REAL_RAF === undefined) delete globalThis.requestAnimationFrame
  else globalThis.requestAnimationFrame = REAL_RAF
})

function stubFrames() {
  const queue = []
  globalThis.requestAnimationFrame = (fn) => queue.push(fn)
  return {
    frame() {
      for (const fn of queue.splice(0)) fn()
    },
    get pending() {
      return queue.length
    },
  }
}

// A document whose activeElement moves with focus()/blur(), and focusable
// fakes that count how often they were focused (a focus binding running).
function focusDocument() {
  const body = makeEl("body-el")
  const doc = { body, activeElement: body, byId: {}, matches: {} }
  doc.getElementById = (id) => doc.byId[id] ?? null
  doc.querySelectorAll = (sel) => doc.matches[sel] ?? []
  globalThis.document = doc
  return doc
}

function focusable(doc, id, sel) {
  const el = makeEl(id)
  el.focusCount = 0
  el.ownerDocument = doc
  el.contains = (other) => other === el
  el.focus = () => {
    el.focusCount++
    doc.activeElement = el
  }
  el.blur = () => {
    if (doc.activeElement === el) doc.activeElement = doc.body
  }
  if (id) doc.byId[id] = el
  if (sel) doc.matches[sel] = [el]
  return el
}

// Turbo 8's StreamMessageRenderer for one message, replayed on the fake
// frames: StreamElement#render waits a frame before the action; around()
// queues its compare frame right after; then withPreservedFocus restores.
function renderStreamMessage(actions, doc, el) {
  const before = doc.activeElement
  requestAnimationFrame(() => invoke(actions, el))
  requestAnimationFrame(() => {
    const after = doc.activeElement
    const restore = before?.id ? doc.getElementById(before.id) : null
    if (restore && restore !== after) restore.focus()
  })
}

test("a blur op sticks: Turbo's restore finds nothing moved, and the field's focus is not re-run (issue #446)", () => {
  const actions = stubTurbo()
  registerReactiveJs()
  const frames = stubFrames()
  const doc = focusDocument()
  const query = focusable(doc, "picker-query", "[name=query]")
  const list = makeEl("picker-list")
  doc.matches["#picker-list"] = [list]
  query.focus()

  renderStreamMessage(
    actions,
    doc,
    streamEl({ ops: JSON.stringify([["hide", { to: "#picker-list" }], ["blur", { to: "[name=query]" }]]) }),
  )
  frames.frame() // the action runs, then Turbo compares and restores

  expect(list.hidden).toBe(true) // the op before the blur ran in the render pass
  expect(doc.activeElement.id).toBe("picker-query") // the blur is still to come
  expect(query.focusCount).toBe(1) // Turbo did not focus it again

  frames.frame()
  expect(doc.activeElement.id).toBe("body-el")
  expect(query.focusCount).toBe(1)
  expect(frames.pending).toBe(0)
})

test("a focus op sticks when the field focused before the reply has an id (issue #446)", () => {
  const actions = stubTurbo()
  registerReactiveJs()
  const frames = stubFrames()
  const doc = focusDocument()
  const field = focusable(doc, "field", "#field")
  focusable(doc, "other", "#other")
  field.focus()

  renderStreamMessage(actions, doc, streamEl({ ops: JSON.stringify([["focus", { to: "#other" }]]) }))
  frames.frame()
  frames.frame()

  expect(doc.activeElement.id).toBe("other")
  expect(field.focusCount).toBe(1)
})

test("a focus_first op sticks the same way (issue #446)", () => {
  const actions = stubTurbo()
  registerReactiveJs()
  const frames = stubFrames()
  const doc = focusDocument()
  const field = focusable(doc, "field", "#field")
  const item = focusable(doc, "first-item")
  const menu = makeEl("menu")
  menu.querySelectorAll = () => [item]
  doc.matches["#menu"] = [menu]
  field.focus()

  renderStreamMessage(actions, doc, streamEl({ ops: JSON.stringify([["focus_first", { to: "#menu" }]]) }))
  frames.frame()
  frames.frame()

  expect(doc.activeElement.id).toBe("first-item")
  expect(field.focusCount).toBe(1)
})

test("the ops before a focus op run at once; the focus op and the rest of its chain wait one frame, in order (issue #446)", () => {
  const actions = stubTurbo()
  registerReactiveJs()
  const frames = stubFrames()
  const doc = focusDocument()
  const log = []
  const query = focusable(doc, "query", "[name=query]")
  const blur = query.blur
  query.blur = () => (log.push("blur"), blur())
  const badge = makeEl("badge")
  doc.matches["#badge"] = [badge]
  const host = makeEl("host")
  host.dispatchEvent = (event) => log.push(`dispatch ${event.type} (${doc.activeElement === query ? "focused" : "blurred"})`)
  doc.matches["#host"] = [host]
  query.focus()

  invoke(
    actions,
    streamEl({
      ops: JSON.stringify([
        ["add_class", { to: "#badge", classes: ["first"] }],
        ["blur", { to: "[name=query]" }],
        ["dispatch", { to: "#host", name: "app:picked" }],
        ["add_class", { to: "#badge", classes: ["last"] }],
      ]),
    }),
  )

  expect([...badge.classes]).toEqual(["first"])
  expect(log).toEqual([])

  frames.frame()
  expect(log).toEqual(["blur", "dispatch app:picked (blurred)"])
  expect([...badge.classes]).toEqual(["first", "last"])
})

test("a chain without a focus op still runs entirely in the render pass (issue #446)", () => {
  const actions = stubTurbo()
  registerReactiveJs()
  const frames = stubFrames()
  const el = makeEl("x")
  stubDocument({ docMatches: { "#x": [el] } })

  invoke(actions, streamEl({ ops: JSON.stringify([["hide", { to: "#x" }], ["add_class", { to: "#x", classes: ["a"] }]]) }))

  expect(el.hidden).toBe(true)
  expect([...el.classes]).toEqual(["a"])
  expect(frames.pending).toBe(0)
})

test("a deferred focus op resolves within the stream's target root (issue #446)", () => {
  const actions = stubTurbo()
  registerReactiveJs()
  const frames = stubFrames()
  const doc = focusDocument()
  const inside = focusable(doc, "inside")
  const root = makeEl("todo_7")
  root.querySelectorAll = (sel) => (sel === "[name=next]" ? [inside] : [])
  doc.byId.todo_7 = root
  doc.querySelectorAll = () => {
    throw new Error("must resolve within the target root, not the document")
  }

  invoke(actions, streamEl({ ops: JSON.stringify([["focus", { to: "[name=next]" }]]), target: "todo_7" }))
  frames.frame()

  expect(doc.activeElement.id).toBe("inside")
})

test("without requestAnimationFrame the focus op applies at once rather than never (issue #446)", () => {
  const actions = stubTurbo()
  registerReactiveJs()
  delete globalThis.requestAnimationFrame
  const doc = focusDocument()
  focusable(doc, "other", "#other")

  invoke(actions, streamEl({ ops: JSON.stringify([["focus", { to: "#other" }]]) }))

  expect(doc.activeElement.id).toBe("other")
})
