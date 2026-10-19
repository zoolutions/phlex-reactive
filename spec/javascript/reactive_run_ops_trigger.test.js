// Issue #442: client ops that read the element whose binding fired.
//
//   * "@trigger" — a target meaning the element whose on_client binding
//     fired: the bound element, or with `within:` the matching element under
//     it (the row of a list bound once).
//   * from + attr — set_value / text / set_attr read their value off an
//     element (a data-* attribute, or "@text" for textContent) instead of a
//     literal; dispatch's detail_from builds event.detail off the trigger.
//   * within — a delegated record runs only for an event from inside an
//     element matching the selector under the bound element and owned by
//     this root. Anywhere else is a complete no-op: no preventDefault, no
//     confirm, no once record spent.
//
// Real DOM (happy-dom): closest/contains/getAttribute and real bubbling. The
// listener below plays Stimulus: it hands runOps the live event with the
// element's typecast record as event.params.ops.
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll, beforeEach, afterEach } from "bun:test"
import { Window } from "happy-dom"

let ReactiveController
let setConfirmResolver
let registerReactiveJs
const window = new Window()
const SAVED = {}

beforeAll(async () => {
  mock.module("@hotwired/stimulus", () => ({ Controller: class {} }))
  const mod = await import("../../app/javascript/phlex/reactive/reactive_controller.js")
  ReactiveController = mod.default
  registerReactiveJs = mod.registerReactiveJs
  setConfirmResolver = (await import("../../app/javascript/phlex/reactive/confirm.js")).setConfirmResolver
})

beforeEach(() => {
  for (const key of ["document", "window", "Event", "CustomEvent", "fetch"]) SAVED[key] = globalThis[key]
  globalThis.document = window.document
  globalThis.window = window
  globalThis.Event = window.Event
  globalThis.CustomEvent = window.CustomEvent
  globalThis.fetch = () => {
    throw new Error("runOps must NEVER fetch")
  }
  document.body.innerHTML = ""
})

afterEach(() => {
  setConfirmResolver((message) => Promise.resolve(true))
  for (const [key, value] of Object.entries(SAVED)) {
    if (value === undefined) delete globalThis[key]
    else globalThis[key] = value
  }
})

const ROWS = `
  <li><button role="option" id="row-1" data-id="1" data-value="v1" data-label="North"><span id="label-1">North</span></button></li>
  <li><button role="option" id="row-2" data-id="2" data-value="v2" data-label="South"><span id="label-2">South</span></button></li>
`

function mount(inner, rootAttrs = "") {
  document.body.insertAdjacentHTML(
    "beforeend",
    `<div id="picker" data-controller="reactive" ${rootAttrs}>
       <input id="item-value" type="hidden" name="item">
       <span id="item-label"></span>
       ${inner}
     </div>`,
  )
  const root = document.getElementById("picker")
  const controller = new ReactiveController()
  controller.element = root
  return { root, controller }
}

// Stimulus's part: one listener per bound element calling runOps with the
// element's typecast record.
function bind(el, controller, record) {
  el.addEventListener(record.on, (event) => {
    event.params = { ops: record }
    controller.runOps(event)
  })
}

function click(el) {
  const event = new window.MouseEvent("click", { bubbles: true, cancelable: true })
  el.dispatchEvent(event)
  return event
}

function captureWarns(fn) {
  const warns = []
  const original = console.warn
  console.warn = (...args) => warns.push(args.map(String).join(" "))
  try {
    fn()
  } finally {
    console.warn = original
  }
  return warns
}

const pick = [
  ["set_value", { to: "#item-value", from: "@trigger", attr: "data-value" }],
  ["text", { to: "#item-label", from: "@trigger", attr: "data-label" }],
  ["remove_attr", { to: "[role=option]", name: "aria-selected" }],
  ["set_attr", { to: "@trigger", name: "aria-selected", value: "true" }],
]

// --- @trigger without within: -----------------------------------------------

test("@trigger without within: is the bound element itself", () => {
  const { root, controller } = mount(`<button id="solo" data-state="idle"><span id="inner">Go</span></button>`)
  const solo = root.querySelector("#solo")
  bind(solo, controller, { on: "click", ops: [["add_class", { to: "@trigger", classes: ["pressed"] }]] })

  const event = click(root.querySelector("#inner"))

  expect(solo.classList.contains("pressed")).toBe(true)
  expect(event.defaultPrevented).toBe(true)
})

// --- within: ------------------------------------------------------------------

test("within: a click on a span inside a row picks that row", () => {
  const { root, controller } = mount(`<ul id="menu">${ROWS}</ul>`)
  const field = root.querySelector("#item-value")
  let inputs = 0
  field.addEventListener("input", () => inputs++)
  root.querySelector("#row-1").setAttribute("aria-selected", "true")
  bind(root.querySelector("#menu"), controller, { on: "click", within: "[role=option]", ops: pick })

  click(root.querySelector("#label-2"))

  expect(field.value).toBe("v2")
  expect(inputs).toBe(1)
  expect(root.querySelector("#item-label").textContent).toBe("South")
  expect(root.querySelector("#row-2").getAttribute("aria-selected")).toBe("true")
  expect(root.querySelector("#row-1").hasAttribute("aria-selected")).toBe(false)
})

test("within: a click on the list's padding runs nothing and keeps its default", () => {
  const { root, controller } = mount(`<ul id="menu"><li id="gap">gap</li>${ROWS}</ul>`)
  bind(root.querySelector("#menu"), controller, { on: "click", within: "[role=option]", ops: pick })

  const event = click(root.querySelector("#gap"))

  expect(event.defaultPrevented).toBe(false)
  expect(root.querySelector("#item-value").value).toBe("")
})

test("within: a miss does not spend a once record; the next row click runs it, the one after does not", () => {
  const { root, controller } = mount(`<ul id="menu"><li id="gap">gap</li>${ROWS}</ul>`)
  bind(root.querySelector("#menu"), controller, {
    on: "click",
    within: "[role=option]",
    once: true,
    ops: [["set_value", { to: "#item-value", from: "@trigger", attr: "data-value" }]],
  })

  click(root.querySelector("#gap"))
  click(root.querySelector("#row-1"))
  click(root.querySelector("#row-2"))

  expect(root.querySelector("#item-value").value).toBe("v1")
})

test("within: a miss never reaches the confirm gate; a hit confirms with the row as ctx.el", async () => {
  const { root, controller } = mount(`<ul id="menu"><li id="gap">gap</li>${ROWS}</ul>`)
  const asked = []
  setConfirmResolver((message, ctx) => {
    asked.push([message, ctx.el.id])
    return true
  })
  bind(root.querySelector("#menu"), controller, { on: "click", within: "[role=option]", confirm: "Pick?", ops: pick })

  click(root.querySelector("#gap"))
  click(root.querySelector("#label-1"))
  await new Promise((resolve) => setTimeout(resolve, 0))

  expect(asked).toEqual([["Pick?", "row-1"]])
  expect(root.querySelector("#item-value").value).toBe("v1")
})

test("within: a row inside a nested reactive root is that root's — a miss", () => {
  const { root, controller } = mount(`
    <ul id="menu">
      <li><div data-controller="reactive" id="inner-root">
        <button role="option" id="nested-row" data-value="nested">Nested</button>
      </div></li>
      ${ROWS}
    </ul>`)
  bind(root.querySelector("#menu"), controller, { on: "click", within: "[role=option]", ops: pick })

  const event = click(root.querySelector("#nested-row"))

  expect(root.querySelector("#item-value").value).toBe("")
  expect(event.defaultPrevented).toBe(false)
})

test("within: the bound element itself matching the selector is not a row", () => {
  const { root, controller } = mount(`<ul id="menu" role="option" data-value="self">${ROWS}</ul>`)
  bind(root.querySelector("#menu"), controller, { on: "click", within: "[role=option]", ops: pick })

  click(root.querySelector("#menu"))

  expect(root.querySelector("#item-value").value).toBe("")
})

test("within: a selector that does not parse is a miss, never a throw (silent without verbose)", () => {
  const { root, controller } = mount(`<ul id="menu">${ROWS}</ul>`)
  bind(root.querySelector("#menu"), controller, { on: "click", within: "[[nope", ops: pick })

  const warns = captureWarns(() => expect(() => click(root.querySelector("#row-1"))).not.toThrow())
  expect(root.querySelector("#item-value").value).toBe("")
  expect(warns).toEqual([])
})

test("within: a selector that does not parse warns under verbose_errors (a dead binding is never silent)", () => {
  const { root, controller } = mount(`<ul id="menu">${ROWS}</ul>`, 'data-reactive-verbose="true"')
  bind(root.querySelector("#menu"), controller, { on: "click", within: "[[nope", ops: pick })

  const warns = captureWarns(() => click(root.querySelector("#row-1")))

  expect(warns.some((w) => w.includes('within: "[[nope"') && w.includes("not a selector"))).toBe(true)
})

test("within: a debounced record keys its timer on the bound element; the last row wins", async () => {
  const { root, controller } = mount(`<ul id="menu">${ROWS}</ul>`)
  bind(root.querySelector("#menu"), controller, {
    on: "click",
    within: "[role=option]",
    debounce: 10,
    ops: [["set_value", { to: "#item-value", from: "@trigger", attr: "data-value" }]],
  })

  click(root.querySelector("#row-1"))
  click(root.querySelector("#row-2"))
  expect(root.querySelector("#item-value").value).toBe("")
  await new Promise((resolve) => setTimeout(resolve, 30))

  expect(root.querySelector("#item-value").value).toBe("v2")
})

// --- reads ----------------------------------------------------------------------

test("a missing attribute reads as an empty string (it clears)", () => {
  const { root, controller } = mount(`<ul id="menu">${ROWS}</ul>`)
  root.querySelector("#item-label").textContent = "Old"
  bind(root.querySelector("#menu"), controller, {
    on: "click",
    within: "[role=option]",
    ops: [["text", { to: "#item-label", from: "@trigger", attr: "data-adornment" }]],
  })

  click(root.querySelector("#row-1"))

  expect(root.querySelector("#item-label").textContent).toBe("")
})

test("@text reads the trigger's textContent", () => {
  const { root, controller } = mount(`<ul id="menu">${ROWS}</ul>`)
  bind(root.querySelector("#menu"), controller, {
    on: "click",
    within: "[role=option]",
    ops: [["set_attr", { to: "#item-label", name: "data-picked", from: "@trigger", attr: "@text" }]],
  })

  click(root.querySelector("#row-2"))

  expect(root.querySelector("#item-label").getAttribute("data-picked")).toBe("South")
})

test("a read off a selector takes its first match, scoped like the op", () => {
  const { root, controller } = mount(`<div class="src" data-label="First"></div><div class="src" data-label="Second"></div>
    <button id="go">Go</button>`)
  bind(root.querySelector("#go"), controller, {
    on: "click",
    ops: [["text", { to: "#item-label", from: ".src", attr: "data-label" }]],
  })

  click(root.querySelector("#go"))

  expect(root.querySelector("#item-label").textContent).toBe("First")
})

test("a read attr outside data-*/@text in a hand-built record warns and skips that op; its siblings run", () => {
  const { root, controller } = mount(`<ul id="menu">${ROWS}</ul>`)
  bind(root.querySelector("#menu"), controller, {
    on: "click",
    within: "[role=option]",
    ops: [
      ["text", { to: "#item-label", from: "@trigger", attr: "id" }],
      ["set_value", { to: "#item-value", from: "@trigger", attr: "data-value" }],
    ],
  })

  const warns = captureWarns(() => click(root.querySelector("#row-1")))

  expect(warns.some((w) => w.includes('refused client read of "id"'))).toBe(true)
  expect(root.querySelector("#item-label").textContent).toBe("")
  expect(root.querySelector("#item-value").value).toBe("v1")
})

test("a from that matches nothing skips the op (verbose: one zero-target warning); its siblings run", () => {
  const { root, controller } = mount(`<button id="go">Go</button>`, 'data-reactive-verbose="true"')
  bind(root.querySelector("#go"), controller, {
    on: "click",
    ops: [
      ["text", { to: "#item-label", from: "#nowhere-442", attr: "data-label" }],
      ["set_attr", { to: "#item-label", name: "data-ran", value: "yes" }],
    ],
  })

  const warns = captureWarns(() => click(root.querySelector("#go")))

  expect(warns.some((w) => w.includes("#nowhere-442"))).toBe(true)
  expect(root.querySelector("#item-label").getAttribute("data-ran")).toBe("yes")
})

test("a from: selector that does not parse skips that read; its siblings run", () => {
  const { root, controller } = mount(`<button id="go">Go</button>`)
  bind(root.querySelector("#go"), controller, {
    on: "click",
    ops: [
      ["text", { to: "#item-label", from: "[[nope", attr: "data-label" }],
      ["set_attr", { to: "#item-label", name: "data-ran", value: "yes" }],
    ],
  })

  expect(() => click(root.querySelector("#go"))).not.toThrow()
  expect(root.querySelector("#item-label").textContent).toBe("")
  expect(root.querySelector("#item-label").getAttribute("data-ran")).toBe("yes")
})

test("a from: selector that does not parse warns under verbose_errors; its siblings still run", () => {
  const { root, controller } = mount(`<button id="go">Go</button>`, 'data-reactive-verbose="true"')
  bind(root.querySelector("#go"), controller, {
    on: "click",
    ops: [
      ["text", { to: "#item-label", from: "[[nope-442", attr: "data-label" }],
      ["set_attr", { to: "#item-label", name: "data-ran", value: "yes" }],
    ],
  })

  let warns
  expect(() => (warns = captureWarns(() => click(root.querySelector("#go"))))).not.toThrow()
  expect(warns.some((w) => w.includes("[[nope-442"))).toBe(true)
  expect(root.querySelector("#item-label").getAttribute("data-ran")).toBe("yes")
})

test("detail_from fills event.detail with Strings off the trigger, over the literal detail", () => {
  const { root, controller } = mount(`<ul id="menu">${ROWS}</ul>`)
  let detail = null
  root.addEventListener("app:item-picked", (event) => (detail = event.detail))
  bind(root.querySelector("#menu"), controller, {
    on: "click",
    within: "[role=option]",
    ops: [
      [
        "dispatch",
        {
          name: "app:item-picked",
          to: "@root",
          detail: { source: "menu" },
          detail_from: { id: "data-id", value: "data-value", text: "@text" },
        },
      ],
    ],
  })

  click(root.querySelector("#label-1"))

  expect(detail).toEqual({ source: "menu", id: "1", value: "v1", text: "North" })
})

test("detail_from with a refused attr warns and skips the dispatch", () => {
  const { root, controller } = mount(`<ul id="menu">${ROWS}</ul>`)
  let fired = 0
  root.addEventListener("app:refused", () => fired++)
  bind(root.querySelector("#menu"), controller, {
    on: "click",
    within: "[role=option]",
    ops: [["dispatch", { name: "app:refused", to: "@root", detail: {}, detail_from: { id: "id" } }]],
  })

  const warns = captureWarns(() => click(root.querySelector("#row-1")))

  expect(fired).toBe(0)
  expect(warns.some((w) => w.includes("refused client read"))).toBe(true)
})

test("detail_from over a hand-built detail that is no object warns and skips the dispatch; its siblings run", () => {
  const { root, controller } = mount(`<ul id="menu">${ROWS}</ul>`)
  const details = []
  root.addEventListener("app:spread", (event) => details.push(event.detail))
  bind(root.querySelector("#menu"), controller, {
    on: "click",
    within: "[role=option]",
    ops: [
      ["dispatch", { name: "app:spread", to: "@root", detail: "picked", detail_from: { id: "data-id" } }],
      ["dispatch", { name: "app:spread", to: "@root", detail: [1, 2], detail_from: { id: "data-id" } }],
      ["set_attr", { to: "#item-label", name: "data-ran", value: "yes" }],
    ],
  })

  const warns = captureWarns(() => click(root.querySelector("#row-1")))

  expect(details).toEqual([])
  expect(warns.filter((w) => w.includes("refused client read over detail")).length).toBe(2)
  expect(root.querySelector("#item-label").getAttribute("data-ran")).toBe("yes")
})

test("an empty detail_from reads nothing: the dispatch fires with its literal detail, trigger or not", () => {
  mount(`<button id="go">Go</button>`)
  const details = []
  document.addEventListener("app:empty", (event) => details.push(event.detail))
  window.Turbo = { StreamActions: {} }
  registerReactiveJs()
  const stream = document.createElement("turbo-stream")
  stream.setAttribute("target", "picker")
  stream.setAttribute(
    "data-reactive-ops",
    JSON.stringify([["dispatch", { name: "app:empty", to: "@root", detail: { a: "1" }, detail_from: {} }]]),
  )

  window.Turbo.StreamActions["reactive:js"].call(stream)

  expect(details).toEqual([{ a: "1" }])
  delete window.Turbo
})

// --- no trigger -----------------------------------------------------------------

test("a window-bound record has no trigger element: @trigger resolves to nothing (verbose: warned) and its siblings run", () => {
  const { root, controller } = mount(`<button id="go">Go</button>`, 'data-reactive-verbose="true"')
  const go = root.querySelector("#go")
  const record = {
    on: "keydown",
    window: true,
    ops: [
      ["add_class", { to: "@trigger", classes: ["nope"] }],
      ["set_attr", { to: "#item-label", name: "data-ran", value: "yes" }],
    ],
  }
  window.addEventListener("keydown", (event) => {
    event.params = { ops: record }
    controller.runOps(event)
  })

  const warns = captureWarns(() =>
    expect(() => window.dispatchEvent(new window.KeyboardEvent("keydown", { key: "x" }))).not.toThrow(),
  )

  expect(warns.some((w) => w.includes("@trigger") && w.includes("no trigger element"))).toBe(true)
  expect(go.classList.contains("nope")).toBe(false)
  expect(root.querySelector("#item-label").getAttribute("data-ran")).toBe("yes")
})

test("a reactive:js stream op naming @trigger resolves to nothing and warns (verbose)", () => {
  mount(`<button id="go">Go</button>`)
  window.Turbo = { StreamActions: {} }
  registerReactiveJs()
  const stream = document.createElement("turbo-stream")
  stream.setAttribute("target", "picker")
  stream.setAttribute("data-reactive-verbose", "true")
  stream.setAttribute(
    "data-reactive-ops",
    JSON.stringify([
      ["add_class", { to: "@trigger", classes: ["nope"] }],
      ["text", { to: "#item-label", from: "@trigger", attr: "data-label" }],
      ["set_attr", { to: "#item-label", name: "data-ran", value: "yes" }],
    ]),
  )

  const warns = captureWarns(() => window.Turbo.StreamActions["reactive:js"].call(stream))

  expect(document.querySelector(".nope")).toBe(null)
  expect(document.querySelector("#item-label").textContent).toBe("")
  expect(document.querySelector("#item-label").getAttribute("data-ran")).toBe("yes")
  expect(warns.some((w) => w.includes("@trigger") && w.includes("server-pushed op has no trigger element"))).toBe(true)
  delete window.Turbo
})
