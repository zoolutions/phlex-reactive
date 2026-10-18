// Issue #439: js.preview_file(…, per_file: true) on an <input multiple> checks
// EVERY file (accept, then max_bytes), rebuilds input.files from the accepted
// ones before any later binding on the same event collects them, dispatches
// one reactive:file-rejected per refused file (detail: reason, file, index,
// remaining) and paints the first accepted image. A single input, and a
// multiple input without per_file:, keep the one-file behaviour of #391.
//
// The files are set through happy-dom's own DataTransfer, so the input's
// real files getter and setter are in play (the runtime assigns input.files).
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll, beforeEach, afterEach } from "bun:test"
import { Window } from "happy-dom"

let mod
let ReactiveController
const window = new Window()
const GLOBALS = ["document", "window", "Event", "CustomEvent", "MutationObserver", "DataTransfer", "File"]
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
  for (const key of GLOBALS) SAVED[key] = globalThis[key]
  SAVED.createObjectURL = URL.createObjectURL
  SAVED.revokeObjectURL = URL.revokeObjectURL
  SAVED.warn = console.warn
  for (const key of GLOBALS) globalThis[key] = key === "document" ? window.document : key === "window" ? window : window[key]
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
  for (const key of GLOBALS) {
    if (SAVED[key] === undefined) delete globalThis[key]
    else globalThis[key] = SAVED[key]
  }
})

const sized = (name, type, bytes) => new window.File(["x".repeat(bytes)], name, { type })
const png = (name = "a.png", bytes = 3) => sized(name, "image/png", bytes)
const svg = (name = "c.svg") => sized(name, "image/svg+xml", 3)
const pdf = (name = "report.pdf", bytes = 3) => sized(name, "application/pdf", bytes)

function mount(html, rootAttrs = "") {
  document.body.insertAdjacentHTML(
    "beforeend",
    `<div id="r" data-controller="reactive" data-reactive-token-value="t"${rootAttrs}>${html}</div>`,
  )
  const root = document.getElementById("r")
  const controller = new ReactiveController()
  controller.element = root
  return { root, controller, input: root.querySelector("#pick") }
}

const picker = ({ accept = "image/png", multiple = true } = {}) =>
  `<input type="file" id="pick" name="file"${multiple ? " multiple" : ""}${accept ? ` accept="${accept}"` : ""}>` +
  `<div id="frame"><img id="shot" alt=""></div><span id="shot-name"></span>`

function choose(input, files) {
  const transfer = new window.DataTransfer()
  for (const file of files) transfer.items.add(file)
  input.files = transfer.files
  return input.files
}

const names = (input) => [...input.files].map((file) => file.name)

function run(controller, ops) {
  controller.runOps({ params: { ops }, target: controller.element, preventDefault() {} })
}

function rejections(input) {
  const seen = []
  input.addEventListener("reactive:file-rejected", (event) =>
    seen.push({ ...event.detail, file: event.detail.file.name, filesNow: input.files.length }),
  )
  return seen
}

const op = (extra = {}) => [
  "preview_file",
  { to: "#pick", into: "#shot", name: "#shot-name", wrap: "#frame", max_bytes: 10, accept: true, per_file: true, ...extra },
]

// --- per_file: true on a multiple input ---------------------------------------

test("keeps the accepted file, drops the oversize and the wrong-type one, one event each", () => {
  const { root, controller, input } = mount(picker())
  const seen = rejections(input)
  choose(input, [png("a.png"), png("b.png", 11), svg("c.svg")])

  run(controller, [op()])

  expect(names(input)).toEqual(["a.png"])
  expect(seen).toEqual([
    { reason: "size", file: "b.png", index: 1, remaining: 1, filesNow: 1 },
    { reason: "type", file: "c.svg", index: 2, remaining: 1, filesNow: 1 },
  ])
  expect(root.querySelector("#shot").getAttribute("src")).toBe("blob:test/1")
  expect(created.map((file) => file.name)).toEqual(["a.png"])
  expect(root.querySelector("#shot-name").textContent).toBe("a.png")
  expect(root.querySelector("#frame").hidden).toBe(false)
})

test("the rejection event bubbles and carries the refused File itself", () => {
  const { root, controller, input } = mount(picker())
  const big = png("big.png", 50)
  const details = []
  root.addEventListener("reactive:file-rejected", (event) => details.push(event.detail))
  choose(input, [big, png("ok.png")])

  run(controller, [op()])

  expect(details).toEqual([{ reason: "size", file: big, index: 0, remaining: 1 }])
})

test("an oversize file ahead of an accepted one is dropped and the accepted one painted", () => {
  const { root, controller, input } = mount(picker())
  choose(input, [png("b.png", 11), png("a.png")])

  run(controller, [op()])

  expect(names(input)).toEqual(["a.png"])
  expect(root.querySelector("#shot-name").textContent).toBe("a.png")
})

test("every file refused: the input is emptied and the preview cleared", () => {
  const { root, controller, input } = mount(picker())
  const seen = rejections(input)
  choose(input, [png("b.png", 11), svg("c.svg")])

  run(controller, [op()])

  expect(input.files.length).toBe(0)
  expect(seen.map(({ reason, index, remaining }) => [reason, index, remaining])).toEqual([
    ["size", 0, 0],
    ["type", 1, 0],
  ])
  expect(created).toEqual([])
  expect(root.querySelector("#shot").hasAttribute("src")).toBe(false)
  expect(root.querySelector("#shot-name").textContent).toBe("")
  expect(root.querySelector("#frame").hidden).toBe(true)
})

test("nothing refused: the input's FileList is left as it is and no event fires", () => {
  const { controller, input } = mount(picker())
  const seen = rejections(input)
  const files = choose(input, [png("a.png"), png("b.png")])

  run(controller, [op()])

  expect(input.files).toBe(files)
  expect(seen).toEqual([])
  expect(created.map((file) => file.name)).toEqual(["a.png"])
})

test("max_bytes applies to every accepted file, not only the painted image", () => {
  const { root, controller, input } = mount(picker({ accept: "image/png,application/pdf" }))
  const seen = rejections(input)
  choose(input, [pdf("small.pdf"), pdf("big.pdf", 11), png("a.png")])

  run(controller, [op()])

  expect(names(input)).toEqual(["small.pdf", "a.png"])
  expect(seen.map(({ reason, file }) => [reason, file])).toEqual([["size", "big.pdf"]])
  expect(root.querySelector("#shot-name").textContent).toBe("a.png")
})

test("an accepted non-image alone stays in the input and clears the preview, unrefused", () => {
  const { root, controller, input } = mount(picker({ accept: "application/pdf" }))
  const seen = rejections(input)
  choose(input, [pdf("report.pdf")])

  run(controller, [op()])

  expect(names(input)).toEqual(["report.pdf"])
  expect(seen).toEqual([])
  expect(root.querySelector("#shot").hasAttribute("src")).toBe(false)
  expect(root.querySelector("#frame").hidden).toBe(true)
})

test("without max_bytes: only the type is checked", () => {
  const { controller, input } = mount(picker())
  const seen = rejections(input)
  choose(input, [png("huge.png", 5000), svg("c.svg")])

  run(controller, [op({ max_bytes: undefined })])

  expect(names(input)).toEqual(["huge.png"])
  expect(seen.map(({ reason }) => reason)).toEqual(["type"])
})

test("valid: true on an invalid input previews as empty and leaves its files alone", () => {
  const { controller, input } = mount(picker())
  const seen = rejections(input)
  const files = choose(input, [png("b.png", 11), png("a.png")])
  Object.defineProperty(input, "validity", { value: { valid: false }, configurable: true })

  run(controller, [op({ valid: true })])

  expect(input.files).toBe(files)
  expect(seen).toEqual([])
  expect(created).toEqual([])
})

// --- without DataTransfer -----------------------------------------------------

test("without DataTransfer every file is still checked and announced; the input is left whole", () => {
  delete globalThis.DataTransfer
  const { controller, input } = mount(picker())
  const seen = rejections(input)
  choose(input, [png("a.png"), png("b.png", 11), svg("c.svg")])

  run(controller, [op()])

  expect(names(input)).toEqual(["a.png", "b.png", "c.svg"])
  // remaining is what the input keeps (and the action posts): all three here.
  expect(seen.map(({ reason, index, remaining, filesNow }) => [reason, index, remaining, filesNow])).toEqual([
    ["size", 1, 3, 3],
    ["type", 2, 3, 3],
  ])
  expect(warnings).toEqual([])
})

test("without DataTransfer a verbose root is told the refused files stay in the input", () => {
  delete globalThis.DataTransfer
  const { controller, input } = mount(picker(), ` data-reactive-verbose="true"`)
  choose(input, [png("a.png"), svg("c.svg")])

  run(controller, [op()])

  expect(warnings.join("\n")).toContain("preview_file")
  expect(warnings.join("\n")).toContain("DataTransfer")
})

// --- today's behaviour, unchanged ----------------------------------------------

test("per_file: true on a single input keeps the one-file check and leaves the input alone", () => {
  const { controller, input } = mount(picker({ multiple: false }))
  const big = png("big.png", 50)
  const details = []
  input.addEventListener("reactive:file-rejected", (event) => details.push(event.detail))
  const files = choose(input, [big])

  run(controller, [op()])

  expect(input.files).toBe(files)
  expect(details).toEqual([{ reason: "size", file: big }])
})

test("a multiple input without per_file: checks the first accepted file only, as before", () => {
  const { root, controller, input } = mount(picker())
  const seen = rejections(input)
  const files = choose(input, [png("a.png"), png("b.png", 11), svg("c.svg")])

  run(controller, [op({ per_file: undefined })])

  expect(input.files).toBe(files)
  expect(seen).toEqual([])
  expect(root.querySelector("#shot-name").textContent).toBe("a.png")
})

test("a multiple input without per_file: still refuses its first file by size with today's detail", () => {
  const { controller, input } = mount(picker())
  const big = png("b.png", 11)
  const details = []
  input.addEventListener("reactive:file-rejected", (event) => details.push(event.detail))
  const files = choose(input, [big, png("a.png")])

  run(controller, [op({ per_file: undefined })])

  expect(input.files).toBe(files)
  expect(details).toEqual([{ reason: "size", file: big }])
})

// --- the action bound after the op on the same change -------------------------

test("an action dispatched after the op on the same change posts only the kept files", async () => {
  const { controller, input } = mount(picker())
  document.head.innerHTML =
    `<meta name="reactive-action-path" content="/reactive/actions"><meta name="csrf-token" content="csrf">`
  let body = null
  const savedFetch = globalThis.fetch
  const savedFormData = globalThis.FormData
  // happy-dom's FormData, so it takes happy-dom's File.
  globalThis.FormData = window.FormData
  window.Turbo = { renderStreamMessage() {} }
  globalThis.fetch = (_path, opts) => {
    body = opts.body
    return Promise.resolve({
      redirected: false,
      ok: true,
      status: 200,
      headers: { get: () => "text/vnd.turbo-stream.html" },
      text: () => Promise.resolve(""),
    })
  }
  try {
    choose(input, [png("a.png"), png("b.png", 11), svg("c.svg")])
    // The order mix(on_client(:change, op), on(:upload, event: "change")) gives:
    // runOps first, then dispatch, with the same change event.
    run(controller, [op()])
    await controller.dispatch({ params: { action: "upload", params: "{}" }, target: input, preventDefault() {} })
  } finally {
    globalThis.fetch = savedFetch
    globalThis.FormData = savedFormData
    delete window.Turbo
  }

  expect(body instanceof window.FormData).toBe(true)
  expect(body.getAll("params[file][]").map((file) => file.name)).toEqual(["a.png"])
})
