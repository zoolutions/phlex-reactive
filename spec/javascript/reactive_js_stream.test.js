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
import { test, expect, mock, beforeAll } from "bun:test"

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
