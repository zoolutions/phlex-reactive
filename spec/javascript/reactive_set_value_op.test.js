// Unit tests for the issue #374 `set_value` client op — a field's live value
// from a client op. Layered on the #95 runOps interpreter like
// reactive_paste_op.test.js: fake nodes, no fetch ever, owned scoping.
//
// The contract (the set-value contract of issue #183, the one paste_into
// uses): assign the IDL `.value` — never setAttribute, never HTML — then
// dispatch ONE bubbling `input` when the value changed. Never `change`, never
// focus. Only an input / textarea / select is a target: a contenteditable
// (reactive_editable owns it) or any other node warns and skips, and a file
// input takes "" only (the one value a browser allows).
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll, afterEach } from "bun:test"

let ReactiveController
let computeModule

beforeAll(async () => {
  mock.module("@hotwired/stimulus", () => ({
    Controller: class {
      constructor() {}
    },
  }))
  ReactiveController = (await import("../../app/javascript/phlex/reactive/reactive_controller.js")).default
  computeModule = await import("../../app/javascript/phlex/reactive/compute.js")
})

const REAL_FETCH = globalThis.fetch
const REAL_DOCUMENT = globalThis.document
afterEach(() => {
  globalThis.fetch = REAL_FETCH
  globalThis.document = REAL_DOCUMENT
})

// A field stand-in: records every IDL write and every dispatched event, and
// models the browser's own value coercions — a textarea normalizes CRLF, a
// select takes only an option's value (anything else selects nothing: ""),
// and a file input throws on a non-empty assignment.
function makeField(localName, { type = "", value = "", options = null, attrs = {} } = {}) {
  let current = value
  const field = {
    localName,
    type,
    writes: [],
    events: [],
    focused: 0,
    files: type === "file" ? ["report.pdf"] : undefined,
    attributes: { ...attrs },
    closest: () => null,
    hasAttribute: (name) => name in field.attributes,
    getAttribute: (name) => field.attributes[name] ?? null,
    setAttribute(name, v) {
      field.attributes[name] = String(v)
    },
    focus() {
      field.focused += 1
    },
    dispatchEvent(event) {
      field.events.push({ type: event.type, bubbles: event.bubbles, valueAtDispatch: field.value })
      return true
    },
  }
  Object.defineProperty(field, "value", {
    get: () => current,
    set(v) {
      field.writes.push(v)
      if (type === "file") {
        if (v !== "") throw new Error("InvalidStateError: a file input's value can only be set to the empty string")
        field.files = []
        current = ""
      } else if (localName === "select") current = options.includes(v) ? v : ""
      else if (localName === "textarea") current = String(v).replace(/\r\n?/g, "\n")
      else current = String(v)
    },
  })
  return field
}

function makeRoot() {
  return {
    isConnected: true,
    id: "notes-fill",
    contains: () => true,
    closest: () => null,
    querySelectorAll: () => [],
    getAttribute: () => null,
  }
}

function setup(fieldsBySelector) {
  const root = makeRoot()
  for (const field of Object.values(fieldsBySelector)) field.closest = () => root
  root.querySelectorAll = (sel) => (fieldsBySelector[sel] ? [fieldsBySelector[sel]] : [])
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
  return { root, controller }
}

function fire(controller, ops) {
  controller.runOps({ params: { ops }, target: {}, preventDefault() {} })
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

const setValue = (to, value) => ["set_value", { to, value }]

// --- The write + the input dispatch -----------------------------------------

test("set_value assigns the textarea's live .value and dispatches ONE bubbling input after the write", () => {
  const notes = makeField("textarea")
  const { controller } = setup({ "#notes": notes })

  const warns = captureWarnings(() => fire(controller, [setValue("#notes", "Thanks")]))

  expect(notes.value).toBe("Thanks")
  expect(notes.events).toEqual([{ type: "input", bubbles: true, valueAtDispatch: "Thanks" }])
  expect(warns).toEqual([])
})

test("a second set_value of the same string does not dispatch input again", () => {
  const notes = makeField("textarea")
  const { controller } = setup({ "#notes": notes })

  fire(controller, [setValue("#notes", "Thanks")])
  fire(controller, [setValue("#notes", "Thanks")])

  expect(notes.events.filter((e) => e.type === "input")).toHaveLength(1)
})

test("'changed' is the field's value before vs after — a CRLF the textarea normalizes does not re-fire", () => {
  const notes = makeField("textarea")
  const { controller } = setup({ "#notes": notes })

  fire(controller, [setValue("#notes", "a\r\nb")])
  fire(controller, [setValue("#notes", "a\r\nb")])

  expect(notes.value).toBe("a\nb")
  expect(notes.events).toHaveLength(1)
})

test("never dispatches change and never moves focus", () => {
  const notes = makeField("textarea")
  const { controller } = setup({ "#notes": notes })

  fire(controller, [setValue("#notes", "Thanks")])

  expect(notes.events.map((e) => e.type)).not.toContain("change")
  expect(notes.focused).toBe(0)
})

test("never touches the value ATTRIBUTE (that is set_attr's job)", () => {
  const notes = makeField("input", { type: "text", attrs: { value: "server" } })
  const { controller } = setup({ "#notes": notes })

  fire(controller, [setValue("#notes", "Thanks")])

  expect(notes.getAttribute("value")).toBe("server")
  expect(notes.value).toBe("Thanks")
})

test("set_attr of value still writes only the attribute — no IDL write, no input", () => {
  const notes = makeField("textarea", { value: "typed" })
  const { controller } = setup({ "#notes": notes })

  fire(controller, [["set_attr", { to: "#notes", name: "value", value: "Thanks" }]])

  expect(notes.getAttribute("value")).toBe("Thanks")
  expect(notes.writes).toEqual([])
  expect(notes.events).toEqual([])
})

test("an empty value clears a non-empty field and dispatches input", () => {
  const notes = makeField("textarea", { value: "draft" })
  const { controller } = setup({ "#notes": notes })

  fire(controller, [setValue("#notes", "")])

  expect(notes.value).toBe("")
  expect(notes.events).toHaveLength(1)
})

test("a missing value (a hand-built pair) clears like \"\"", () => {
  const notes = makeField("textarea", { value: "draft" })
  const { controller } = setup({ "#notes": notes })

  fire(controller, [["set_value", { to: "#notes" }]])

  expect(notes.value).toBe("")
})

test("clearing an already-empty field writes nothing observable — no input", () => {
  const notes = makeField("textarea")
  const { controller } = setup({ "#notes": notes })

  fire(controller, [setValue("#notes", "")])

  expect(notes.events).toEqual([])
})

test("an HTML-looking value is stored as those characters (assigned, never parsed)", () => {
  const notes = makeField("textarea")
  const { controller } = setup({ "#notes": notes })

  fire(controller, [setValue("#notes", "<b>hi</b>")])

  expect(notes.value).toBe("<b>hi</b>")
  expect(notes.writes).toEqual(["<b>hi</b>"])
})

test("a hidden input takes the value (the issue's template_key) and dispatches input", () => {
  const key = makeField("input", { type: "hidden" })
  const { controller } = setup({ "#template_key": key })

  fire(controller, [setValue("#template_key", "thanks")])

  expect(key.value).toBe("thanks")
  expect(key.events).toHaveLength(1)
})

test("a select takes the string as .value — the matching option becomes selected", () => {
  const tone = makeField("select", { value: "formal", options: ["formal", "warm"] })
  const { controller } = setup({ "#tone": tone })

  fire(controller, [setValue("#tone", "warm")])

  expect(tone.value).toBe("warm")
  expect(tone.events).toHaveLength(1)
})

// A <select multiple> stand-in: assigning .value selects the first matching
// option and deselects every other one (the HTML spec), so .value alone can
// stay the same while the selection shrinks.
function makeMultiSelect(values, selected) {
  const options = values.map((v) => ({ value: v, selected: selected.includes(v) }))
  const field = {
    localName: "select",
    type: "select-multiple",
    options,
    events: [],
    closest: () => null,
    hasAttribute: () => false,
    get selectedOptions() {
      return options.filter((o) => o.selected)
    },
    get value() {
      return options.find((o) => o.selected)?.value ?? ""
    },
    set value(v) {
      let found = false
      for (const o of options) {
        o.selected = !found && o.value === v
        if (o.selected) found = true
      }
    },
    dispatchEvent(event) {
      field.events.push(event.type)
      return true
    },
  }
  return field
}

test("a <select multiple> whose selection shrank dispatches input even when .value reads the same", () => {
  const tags = makeMultiSelect(["a", "b", "c"], ["a", "b"])
  const { controller } = setup({ "#tags": tags })

  fire(controller, [setValue("#tags", "a")])

  expect(tags.selectedOptions.map((o) => o.value)).toEqual(["a"])
  expect(tags.events).toEqual(["input"])
})

test("a <select multiple> already holding exactly that one option dispatches nothing", () => {
  const tags = makeMultiSelect(["a", "b"], ["a"])
  const { controller } = setup({ "#tags": tags })

  fire(controller, [setValue("#tags", "a")])

  expect(tags.events).toEqual([])
})

// --- Warn and skip ------------------------------------------------------------

test("a contenteditable target warns and skips (reactive_editable writes those)", () => {
  const editable = makeField("div", { attrs: { contenteditable: "true" } })
  const { controller } = setup({ "#body": editable })

  const warns = captureWarnings(() => fire(controller, [setValue("#body", "x")]))

  expect(editable.writes).toEqual([])
  expect(editable.events).toEqual([])
  expect(warns).toHaveLength(1)
  expect(warns[0]).toContain("set_value")
})

test("a data-reactive-editable target warns and skips", () => {
  const editable = makeField("h1", { attrs: { "data-reactive-editable": "", contenteditable: "plaintext-only" } })
  const { controller } = setup({ "#title": editable })

  const warns = captureWarnings(() => fire(controller, [setValue("#title", "x")]))

  expect(editable.writes).toEqual([])
  expect(warns).toHaveLength(1)
})

test("a non-field target warns and skips", () => {
  const div = makeField("div")
  const { controller } = setup({ "#box": div })

  const warns = captureWarnings(() => fire(controller, [setValue("#box", "x")]))

  expect(div.writes).toEqual([])
  expect(div.events).toEqual([])
  expect(warns).toHaveLength(1)
  expect(warns[0]).toContain("set_value")
})

test("a file input accepts \"\" — it clears the chosen files and dispatches input", () => {
  const file = makeField("input", { type: "file", value: "C:\\fakepath\\report.pdf" })
  const { controller } = setup({ "#file": file })

  fire(controller, [setValue("#file", "")])

  expect(file.files).toEqual([])
  expect(file.value).toBe("")
  expect(file.events).toHaveLength(1)
})

test("a file input refuses any other string: warns, never assigns, keeps its files", () => {
  const file = makeField("input", { type: "file", value: "C:\\fakepath\\report.pdf" })
  const { controller } = setup({ "#file": file })

  const warns = captureWarnings(() => expect(() => fire(controller, [setValue("#file", "x")])).not.toThrow())

  expect(file.writes).toEqual([])
  expect(file.files).toEqual(["report.pdf"])
  expect(file.events).toEqual([])
  expect(warns).toHaveLength(1)
})

test("one skipped target never takes down its chain siblings", () => {
  const div = makeField("div")
  const notes = makeField("textarea")
  const key = makeField("input", { type: "hidden" })
  const { controller } = setup({ "#box": div, "#notes": notes, "#template_key": key })

  captureWarnings(() =>
    fire(controller, [setValue("#box", "x"), setValue("#notes", "Thanks"), setValue("#template_key", "thanks")]),
  )

  expect(notes.value).toBe("Thanks")
  expect(key.value).toBe("thanks")
})

test("set_value is a KNOWN op — it never trips the unknown-op default-deny warn", () => {
  const notes = makeField("textarea")
  const { controller } = setup({ "#notes": notes })

  const warns = captureWarnings(() => fire(controller, [setValue("#notes", "x")]))

  expect(warns.some((w) => w.includes("unknown client op"))).toBe(false)
})

// --- The reducer-side builder (compute.js) ----------------------------------

test("ops.set_value mirrors the Ruby wire: selector + stringified value, nil clears", () => {
  const { ops } = computeModule

  expect(ops.set_value("#notes", "Thanks").set_value("#qty", 3).set_value("#x", null, { global: true }).ops).toEqual([
    ["set_value", { to: "#notes", value: "Thanks" }],
    ["set_value", { to: "#qty", value: "3" }],
    ["set_value", { to: "#x", value: "", global: true }],
  ])
})

test("ops.set_value needs a field selector — no root default (the root is not a field)", () => {
  const { ops } = computeModule

  expect(() => ops.set_value(undefined, "x")).toThrow(/set_value/)
  expect(() => ops.set_value("@root", "x")).toThrow(/set_value/)
})
