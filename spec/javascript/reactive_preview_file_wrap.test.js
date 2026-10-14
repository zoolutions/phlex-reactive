// Issue #391: js.preview_file gains wrap:, max_bytes: and accept:. The box
// around the preview follows the local file: wrap: is shown when an image is
// painted and hidden when the preview clears. A file over max_bytes: or
// outside the accept list is a rejection: the img is cleared, wrap: hidden,
// and reactive:file-rejected (detail.reason "type" | "size") dispatched on the
// input. The op never clears input.files and never sets a custom validity.
//
// The wrapper hide is marked as the runtime's own (data-reactive-wrap-hidden),
// so a later success shows only a wrapper this code hid.
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll, beforeEach, afterEach } from "bun:test"
import { Window } from "happy-dom"

let mod
let ReactiveController
const window = new Window()
const SAVED = {}
let created
let warnings

beforeAll(async () => {
  mock.module("@hotwired/stimulus", () => ({ Controller: class {} }))
  globalThis.document = window.document
  mod = await import("../../app/javascript/phlex/reactive/reactive_controller.js")
  ReactiveController = mod.default
})

beforeEach(() => {
  for (const key of ["document", "window", "Event", "CustomEvent", "MutationObserver"]) SAVED[key] = globalThis[key]
  SAVED.createObjectURL = URL.createObjectURL
  SAVED.revokeObjectURL = URL.revokeObjectURL
  SAVED.warn = console.warn
  globalThis.document = window.document
  globalThis.window = window
  globalThis.Event = window.Event
  globalThis.CustomEvent = window.CustomEvent
  globalThis.MutationObserver = window.MutationObserver
  created = []
  warnings = []
  URL.createObjectURL = (file) => {
    created.push(file)
    return `blob:test/${created.length}`
  }
  URL.revokeObjectURL = () => {}
  console.warn = (...args) => warnings.push(args.join(" "))
  document.body.innerHTML = ""
})

afterEach(() => {
  mod.__resetReactivePreviewsForTest()
  URL.createObjectURL = SAVED.createObjectURL
  URL.revokeObjectURL = SAVED.revokeObjectURL
  console.warn = SAVED.warn
  for (const key of ["document", "window", "Event", "CustomEvent", "MutationObserver"]) {
    if (SAVED[key] === undefined) delete globalThis[key]
    else globalThis[key] = SAVED[key]
  }
})

const sized = (name, type, bytes) => new File(["x".repeat(bytes)], name, { type })
const png = (name = "a.png", bytes = 3) => sized(name, "image/png", bytes)
const jpg = (name = "a.jpg") => sized(name, "image/jpeg", 3)
const txt = (name = "notes.txt") => sized(name, "text/plain", 3)

function mount(html) {
  document.body.insertAdjacentHTML(
    "beforeend",
    `<div id="r" data-controller="reactive" data-reactive-token-value="t">${html}</div>`,
  )
  const root = document.getElementById("r")
  const controller = new ReactiveController()
  controller.element = root
  return { root, controller }
}

const field = (accept = "") =>
  `<input type="file" id="photo-file"${accept ? ` accept="${accept}"` : ""}>` +
  `<div id="photo-frame"><img id="photo" alt=""></div><span id="photo-name"></span>`

function choose(input, files) {
  Object.defineProperty(input, "files", { value: files, configurable: true })
}

function run(controller, ops) {
  controller.runOps({ params: { ops }, target: controller.element, preventDefault() {} })
}

function rejections(input) {
  const seen = []
  input.addEventListener("reactive:file-rejected", (event) => seen.push(event.detail.reason))
  return seen
}

const op = (extra = {}) => ["preview_file", { to: "#photo-file", into: "#photo", wrap: "#photo-frame", ...extra }]

// --- wrap: follows the preview ----------------------------------------------

test("an accepted image under max_bytes paints the img and shows wrap:", () => {
  const { root, controller } = mount(field("image/png"))
  root.querySelector("#photo-frame").hidden = true
  root.querySelector("#photo-frame").setAttribute("data-reactive-wrap-hidden", "")
  choose(root.querySelector("#photo-file"), [png()])

  run(controller, [op({ max_bytes: 10, accept: true })])

  expect(root.querySelector("#photo").getAttribute("src")).toBe("blob:test/1")
  expect(root.querySelector("#photo-frame").hidden).toBe(false)
  expect(root.querySelector("#photo-frame").hasAttribute("data-reactive-wrap-hidden")).toBe(false)
})

test("an empty selection clears the img and hides wrap: without a rejection", () => {
  const { root, controller } = mount(field())
  const input = root.querySelector("#photo-file")
  const seen = rejections(input)
  choose(input, [])

  run(controller, [op()])

  expect(root.querySelector("#photo-frame").hidden).toBe(true)
  expect(root.querySelector("#photo-frame").hasAttribute("data-reactive-wrap-hidden")).toBe(true)
  expect(seen).toEqual([])
})

test("hide then show round-trips wrap: on a re-pick", () => {
  const { root, controller } = mount(field())
  const input = root.querySelector("#photo-file")
  choose(input, [txt()])
  run(controller, [op()])
  expect(root.querySelector("#photo-frame").hidden).toBe(true)
  choose(input, [png()])

  run(controller, [op()])

  expect(root.querySelector("#photo-frame").hidden).toBe(false)
  expect(root.querySelector("#photo").getAttribute("src")).toBe("blob:test/1")
})

test("a wrapper the author hid stays hidden on a later success", () => {
  const { root, controller } = mount(field())
  const frame = root.querySelector("#photo-frame")
  frame.hidden = true
  const input = root.querySelector("#photo-file")
  choose(input, [txt()])
  run(controller, [op()])
  expect(frame.hasAttribute("data-reactive-wrap-hidden")).toBe(false)
  choose(input, [png()])

  run(controller, [op()])

  expect(frame.hidden).toBe(true)
  expect(root.querySelector("#photo").getAttribute("src")).toBe("blob:test/1")
})

test("wrap: that contains the img never loses its children or gets text", () => {
  const { root, controller } = mount(field())
  const input = root.querySelector("#photo-file")
  choose(input, [txt()])
  run(controller, [op({ name: "#photo-name" })])
  choose(input, [png()])

  run(controller, [op({ name: "#photo-name" })])

  const frame = root.querySelector("#photo-frame")
  expect(frame.querySelector("#photo")).not.toBeNull()
  expect(frame.textContent).toBe("")
  expect(root.querySelector("#photo-name").textContent).toBe("a.png")
})

test("a wrap: not on the page warns and skips the visibility change; the img rules stay", () => {
  const { root, controller } = mount(field())
  choose(root.querySelector("#photo-file"), [png()])

  run(controller, [op({ wrap: "#nope" })])

  expect(root.querySelector("#photo").getAttribute("src")).toBe("blob:test/1")
  expect(warnings.join("\n")).toContain("preview_file")
  expect(warnings.join("\n")).toContain("#nope")
})

test("global: true resolves wrap: document-wide", () => {
  document.body.innerHTML = `<div id="outer-frame" hidden data-reactive-wrap-hidden><img id="outside"></div>`
  const { root, controller } = mount(`<input type="file" id="photo-file">`)
  choose(root.querySelector("#photo-file"), [png()])

  run(controller, [["preview_file", { to: "#photo-file", into: "#outside", wrap: "#outer-frame", global: true }]])

  expect(document.getElementById("outer-frame").hidden).toBe(false)
})

// --- rejections --------------------------------------------------------------

test("a later text file with accept: true and accept=image/png is rejected for its type", () => {
  const { root, controller } = mount(field("image/png"))
  const input = root.querySelector("#photo-file")
  const seen = rejections(input)
  choose(input, [png()])
  run(controller, [op({ accept: true })])
  const files = [txt()]
  choose(input, files)

  run(controller, [op({ accept: true })])

  expect(root.querySelector("#photo").hasAttribute("src")).toBe(false)
  expect(root.querySelector("#photo-frame").hidden).toBe(true)
  expect(seen).toEqual(["type"])
  expect(input.files).toBe(files)
})

test("a file over max_bytes is rejected for its size and never gets an object URL", () => {
  const { root, controller } = mount(field())
  const input = root.querySelector("#photo-file")
  const seen = rejections(input)
  choose(input, [png("big.png", 11)])

  run(controller, [op({ max_bytes: 10 })])

  expect(created).toEqual([])
  expect(root.querySelector("#photo").hasAttribute("src")).toBe(false)
  expect(root.querySelector("#photo-frame").hidden).toBe(true)
  expect(seen).toEqual(["size"])
})

test("a file exactly max_bytes long is accepted", () => {
  const { root, controller } = mount(field())
  choose(root.querySelector("#photo-file"), [png("edge.png", 10)])

  run(controller, [op({ max_bytes: 10 })])

  expect(root.querySelector("#photo").getAttribute("src")).toBe("blob:test/1")
})

test("an over-size file clears a preview that was showing", () => {
  const { root, controller } = mount(field())
  const input = root.querySelector("#photo-file")
  choose(input, [png()])
  run(controller, [op({ max_bytes: 10, name: "#photo-name" })])
  choose(input, [png("big.png", 50)])

  run(controller, [op({ max_bytes: 10, name: "#photo-name" })])

  expect(created.length).toBe(1)
  expect(root.querySelector("#photo").hasAttribute("src")).toBe(false)
  expect(root.querySelector("#photo-name").textContent).toBe("")
})

test("the rejection event bubbles and carries the file", () => {
  const { root, controller } = mount(field())
  const file = png("big.png", 50)
  let detail
  root.addEventListener("reactive:file-rejected", (event) => {
    detail = event.detail
  })
  choose(root.querySelector("#photo-file"), [file])

  run(controller, [op({ max_bytes: 10 })])

  expect(detail).toEqual({ reason: "size", file })
})

test("the op never sets a custom validity message", () => {
  const { root, controller } = mount(field())
  const input = root.querySelector("#photo-file")
  let called = false
  input.setCustomValidity = () => {
    called = true
  }
  choose(input, [png("big.png", 50)])
  run(controller, [op({ max_bytes: 10 })])
  choose(input, [txt()])
  run(controller, [op({ max_bytes: 10 })])

  expect(called).toBe(false)
})

test("with no accept: a text file is a type rejection under the image/* rule", () => {
  const { root, controller } = mount(field())
  const input = root.querySelector("#photo-file")
  const seen = rejections(input)
  choose(input, [txt()])

  run(controller, [op()])

  expect(seen).toEqual(["type"])
})

test("valid: true on an invalid input previews as empty: wrap hidden, no rejection", () => {
  const { root, controller } = mount(field())
  const input = root.querySelector("#photo-file")
  const seen = rejections(input)
  Object.defineProperty(input, "validity", { value: { valid: false }, configurable: true })
  choose(input, [png()])

  run(controller, [op({ valid: true })])

  expect(created).toEqual([])
  expect(root.querySelector("#photo-frame").hidden).toBe(true)
  expect(seen).toEqual([])
})

// --- accept: -----------------------------------------------------------------

test("accept: true keeps a file whose extension is listed", () => {
  const { root, controller } = mount(field(".PNG, .webp"))
  // Its type is an image, but not a listed one: only the extension matches.
  choose(root.querySelector("#photo-file"), [sized("shot.png", "image/png", 3)])

  run(controller, [op({ accept: true })])

  expect(root.querySelector("#photo").getAttribute("src")).toBe("blob:test/1")
})

test("an accepted file that is not an image clears the preview without a rejection", () => {
  const { root, controller } = mount(field("image/png,application/pdf"))
  const input = root.querySelector("#photo-file")
  const seen = rejections(input)
  choose(input, [png()])
  run(controller, [op({ accept: true })])
  choose(input, [sized("report.pdf", "application/pdf", 3)])

  run(controller, [op({ accept: true })])

  expect(created.map((f) => f.name)).toEqual(["a.png"])
  expect(root.querySelector("#photo").hasAttribute("src")).toBe(false)
  expect(root.querySelector("#photo-frame").hidden).toBe(true)
  expect(seen).toEqual([])
})

test("an accepted non-image ahead of an accepted image previews the image", () => {
  const { root, controller } = mount(field("image/png,application/pdf"))
  choose(root.querySelector("#photo-file"), [sized("report.pdf", "application/pdf", 3), png("photo.png")])

  run(controller, [op({ accept: true })])

  expect(created.map((f) => f.name)).toEqual(["photo.png"])
})

test("accept: true honours a type/* wildcard", () => {
  const { root, controller } = mount(field("image/*"))
  choose(root.querySelector("#photo-file"), [jpg()])

  run(controller, [op({ accept: true })])

  expect(root.querySelector("#photo").getAttribute("src")).toBe("blob:test/1")
})

test("accept: true with accept=image/png refuses a jpeg", () => {
  const { root, controller } = mount(field("image/png"))
  const input = root.querySelector("#photo-file")
  const seen = rejections(input)
  choose(input, [jpg()])

  run(controller, [op({ accept: true })])

  expect(created).toEqual([])
  expect(seen).toEqual(["type"])
})

test("accept: true on an input with no accept attribute keeps the image/* rule", () => {
  const { root, controller } = mount(field())
  const input = root.querySelector("#photo-file")
  const seen = rejections(input)
  choose(input, [txt()])
  run(controller, [op({ accept: true })])
  choose(input, [jpg()])

  run(controller, [op({ accept: true })])

  expect(seen).toEqual(["type"])
  expect(root.querySelector("#photo").getAttribute("src")).toBe("blob:test/1")
})

test("an explicit accept: string overrides the input's attribute", () => {
  const { root, controller } = mount(field("image/*"))
  const input = root.querySelector("#photo-file")
  const seen = rejections(input)
  choose(input, [jpg()])

  run(controller, [op({ accept: "image/png" })])

  expect(created).toEqual([])
  expect(seen).toEqual(["type"])
})

test("several files preview the first accepted one", () => {
  const { root, controller } = mount(field("image/png"))
  const second = png("second.png")
  choose(root.querySelector("#photo-file"), [jpg(), second])

  run(controller, [op({ accept: true })])

  expect(created).toEqual([second])
})

// --- defaults ------------------------------------------------------------------

test("omitting wrap:, max_bytes: and accept: keeps today's preview and touches no wrapper", () => {
  const { root, controller } = mount(field())
  const input = root.querySelector("#photo-file")
  choose(input, [txt()])
  run(controller, [["preview_file", { to: "#photo-file", into: "#photo" }]])
  expect(root.querySelector("#photo-frame").hidden).toBe(false)
  choose(input, [png("big.png", 5000)])

  run(controller, [["preview_file", { to: "#photo-file", into: "#photo" }]])

  expect(root.querySelector("#photo").getAttribute("src")).toBe("blob:test/1")
  expect(warnings).toEqual([])
})
