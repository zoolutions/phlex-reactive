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
  // The morph listener of rejected: (issue #445), once, on this file's document.
  mod.__resetReactiveRejectedFilesForTest()
  mod.registerReactiveRejectedFiles()
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

// --- rejected: names each refused file in the page (issue #445) ---------------
// rejected: is a container holding an app-authored <template>. Each refused
// file, in pick order, gets a deep clone of it: its name in every
// [data-reactive-file="name"] (textContent), only the [data-reactive-file-reason]
// part for its reason, each top-level element marked data-reactive-file-rejected.
// Every run first removes the marked entries, so the next pick replaces them.

const LIST =
  `<div id="refused"><h3 id="refused-heading">Not added</h3><template>` +
  `<p class="entry">` +
  `<span data-reactive-file-reason="size"><b data-reactive-file="name"></b> is too large.</span>` +
  `<span data-reactive-file-reason="type"><b data-reactive-file="name"></b> is not a PNG.</span>` +
  `</p></template></div>`

const listed = (root) =>
  [...root.querySelectorAll("#refused > [data-reactive-file-rejected]")].map((entry) => entry.textContent)

const listOp = (extra = {}) => op({ rejected: "#refused", ...extra })

test("rejected: lists each refused file by name, in pick order, with only its reason's part", () => {
  const { root, controller, input } = mount(picker() + LIST)
  choose(input, [png("a.png"), png("b.png", 11), svg("c.svg"), png("d.png", 12)])

  run(controller, [listOp()])

  expect(listed(root)).toEqual(["b.png is too large.", "c.svg is not a PNG.", "d.png is too large."])
  const entries = [...root.querySelectorAll("#refused > [data-reactive-file-rejected]")]
  expect(entries.map((entry) => entry.querySelector('[data-reactive-file="name"]').textContent)).toEqual([
    "b.png",
    "c.svg",
    "d.png",
  ])
  expect(
    entries.map((entry) =>
      [...entry.querySelectorAll("[data-reactive-file-reason]")].map((part) => part.dataset.reactiveFileReason),
    ),
  ).toEqual([["size"], ["type"], ["size"]])
  expect(entries.every((entry) => entry.localName === "p" && entry.getAttribute("data-reactive-file-rejected") === "")).toBe(
    true,
  )
  expect(names(input)).toEqual(["a.png"])
})

test("rejected: the list is filled before the first reactive:file-rejected handler runs", () => {
  const { root, controller, input } = mount(picker() + LIST)
  const seen = []
  input.addEventListener("reactive:file-rejected", () => seen.push(listed(root).length))
  choose(input, [png("b.png", 11), svg("c.svg")])

  run(controller, [listOp()])

  expect(seen).toEqual([2, 2])
})

test("rejected: a second pick replaces the entries", () => {
  const { root, controller, input } = mount(picker() + LIST)
  choose(input, [png("b.png", 11), svg("c.svg")])
  run(controller, [listOp()])

  choose(input, [png("a.png"), svg("e.svg")])
  run(controller, [listOp()])

  expect(listed(root)).toEqual(["e.svg is not a PNG."])
})

test("rejected: a pick with no refusal, or an empty pick, empties the list", () => {
  const { root, controller, input } = mount(picker() + LIST)
  choose(input, [png("b.png", 11)])
  run(controller, [listOp()])
  expect(listed(root)).toEqual(["b.png is too large."])

  choose(input, [png("a.png")])
  run(controller, [listOp()])
  expect(listed(root)).toEqual([])

  choose(input, [png("b.png", 11)])
  run(controller, [listOp()])
  choose(input, [])
  run(controller, [listOp()])
  expect(listed(root)).toEqual([])
})

test("rejected: author content in the container and the <template> stay", () => {
  const { root, controller, input } = mount(picker() + LIST)
  choose(input, [png("b.png", 11)])
  run(controller, [listOp()])
  choose(input, [png("a.png")])
  run(controller, [listOp()])

  const container = root.querySelector("#refused")
  expect([...container.children].map((child) => child.localName)).toEqual(["h3", "template"])
  expect(container.querySelector("#refused-heading").textContent).toBe("Not added")
  expect(container.querySelector("template").content.querySelectorAll("[data-reactive-file-reason]").length).toBe(2)
})

test("rejected: a file name is written as text, never parsed as HTML", () => {
  const { root, controller, input } = mount(picker() + LIST)
  const hostile = "<img src=x onerror=alert(1)>.png"
  choose(input, [png(hostile, 11)])

  run(controller, [listOp()])

  const entry = root.querySelector("#refused > [data-reactive-file-rejected]")
  expect(entry.querySelector('[data-reactive-file="name"]').textContent).toBe(hostile)
  expect(entry.querySelector("img")).toBeNull()
  expect(root.querySelector("#refused img")).toBeNull()
})

test("rejected: every top-level element of a clone is marked and appended; top-level text is dropped", () => {
  const { root, controller, input } = mount(
    picker() +
      `<div id="refused"><template> lead <dt data-reactive-file="name"></dt> between <dd>refused</dd> tail </template></div>`,
  )
  choose(input, [png("b.png", 11), svg("c.svg")])

  run(controller, [listOp()])

  const container = root.querySelector("#refused")
  const added = [...container.childNodes].filter((node) => node.localName !== "template")
  expect(added.map((node) => [node.localName, node.textContent])).toEqual([
    ["dt", "b.png"],
    ["dd", "refused"],
    ["dt", "c.svg"],
    ["dd", "refused"],
  ])
  expect(added.every((node) => node.hasAttribute("data-reactive-file-rejected"))).toBe(true)
})

test("rejected: a slot outside any reason part is filled for every reason", () => {
  const { root, controller, input } = mount(
    picker() + `<ul id="refused"><template><li><b data-reactive-file="name"></b></li></template></ul>`,
  )
  choose(input, [png("b.png", 11), svg("c.svg")])

  run(controller, [listOp()])

  expect(listed(root)).toEqual(["b.png", "c.svg"])
})

test("rejected: global: true resolves the container document-wide", () => {
  document.body.insertAdjacentHTML("beforeend", LIST)
  const { controller, input } = mount(picker())
  choose(input, [svg("c.svg")])

  run(controller, [listOp({ global: true, name: undefined, wrap: undefined })])

  expect(listed(document.body)).toEqual(["c.svg is not a PNG."])
})

test("rejected: the single-file path of a multiple input lists its one refusal", () => {
  const { root, controller, input } = mount(picker() + LIST)
  choose(input, [png("b.png", 11), png("a.png")])

  run(controller, [listOp({ per_file: undefined })])

  expect(listed(root)).toEqual(["b.png is too large."])
})

test("rejected: a container that is not on the page warns under verbose; the events still fire", () => {
  const { controller, input } = mount(picker(), ` data-reactive-verbose="true"`)
  const seen = rejections(input)
  choose(input, [png("b.png", 11)])

  run(controller, [listOp()])

  expect(seen.map(({ reason }) => reason)).toEqual(["size"])
  expect(warnings.join("\n")).toContain("preview_file rejected:")
  expect(warnings.join("\n")).toContain("#refused")
})

test("rejected: a container without a <template> warns under verbose; the events still fire", () => {
  const { root, controller, input } = mount(picker() + `<ul id="refused"><li>x</li></ul>`, ` data-reactive-verbose="true"`)
  const seen = rejections(input)
  choose(input, [svg("c.svg")])

  run(controller, [listOp()])

  expect(seen.map(({ reason }) => reason)).toEqual(["type"])
  expect(warnings.join("\n")).toContain("<template>")
  expect(root.querySelector("#refused").textContent).toBe("x")
})

test("rejected: a miss is silent without verbose", () => {
  const { controller, input } = mount(picker() + `<ul id="refused"></ul>`)
  choose(input, [svg("c.svg")])

  run(controller, [listOp(), ["preview_file", { to: "#pick", into: "#shot", rejected: "#nowhere" }]])

  expect(warnings).toEqual([])
})

test("rejected: a template with no name slot lists one entry per refused file and writes no name", () => {
  const { root, controller, input } = mount(
    picker() + `<ul id="refused"><template><li>A file was refused.</li></template></ul>`,
  )
  choose(input, [png("b.png", 11), svg("c.svg")])

  run(controller, [listOp()])

  expect(listed(root)).toEqual(["A file was refused.", "A file was refused."])
  expect(root.querySelector("#refused").textContent).not.toContain(".png")
  expect(root.querySelector("#refused").textContent).not.toContain(".svg")
})

test("rejected: a reason with no part of its own keeps only the entry's unmarked parts", () => {
  const { root, controller, input } = mount(
    picker() +
      `<ul id="refused"><template><li><b data-reactive-file="name"></b>` +
      `<span data-reactive-file-reason="size"> is too large.</span></li></template></ul>`,
  )
  const seen = rejections(input)
  choose(input, [png("b.png", 11), svg("c.svg")])

  run(controller, [listOp()])

  // c.svg is refused for its type, which has no part: its entry is the name alone.
  expect(listed(root)).toEqual(["b.png is too large.", "c.svg"])
  expect(root.querySelectorAll("#refused [data-reactive-file-reason]").length).toBe(1)
  expect(seen.map(({ reason }) => reason)).toEqual(["size", "type"])
})

test("rejected: a reason part at the top level of the template lists only the reasons it has a part for", () => {
  const { root, controller, input } = mount(
    picker() +
      `<ul id="refused"><template>` +
      `<li data-reactive-file-reason="size"><b data-reactive-file="name"></b> is too large.</li>` +
      `</template></ul>`,
  )
  const seen = rejections(input)
  choose(input, [png("b.png", 11), svg("c.svg"), png("d.png", 12)])

  run(controller, [listOp()])

  expect(listed(root)).toEqual(["b.png is too large.", "d.png is too large."])
  // The type refusal still fires: only the list has no sentence for it.
  expect(seen.map(({ reason, file }) => [reason, file])).toEqual([
    ["size", "b.png"],
    ["type", "c.svg"],
    ["size", "d.png"],
  ])
})

test("rejected: a slot on a top-level element is filled; a slot value the op does not know is left untouched", () => {
  const { root, controller, input } = mount(
    picker() +
      `<dl id="refused"><template><dt data-reactive-file="name">?</dt>` +
      `<dd data-reactive-file="index">#</dd></template></dl>`,
  )
  choose(input, [png("b.png", 11)])

  run(controller, [listOp()])

  expect([...root.querySelectorAll("#refused > [data-reactive-file-rejected]")].map((node) => node.textContent)).toEqual([
    "b.png",
    "#",
  ])
})

test("rejected: a selector that matches two containers lists into each", () => {
  const { root, controller, input } = mount(
    picker() +
      `<ul class="refused" id="one"><template><li><b data-reactive-file="name"></b></li></template></ul>` +
      `<ol class="refused" id="two"><template><li>refused: <i data-reactive-file="name"></i></li></template></ol>`,
  )
  choose(input, [svg("c.svg")])

  run(controller, [listOp({ rejected: ".refused" })])

  const entries = (id) => [...root.querySelectorAll(`#${id} > [data-reactive-file-rejected]`)].map((e) => e.textContent)
  expect(entries("one")).toEqual(["c.svg"])
  expect(entries("two")).toEqual(["refused: c.svg"])
})

// --- a morph keeps the list (issue #445) ---------------------------------------
// The action that follows the pick on the same change replies with a morph,
// and the server render of the container has no entries. Turbo asks
// turbo:before-morph-element (cancelable, detail.newElement = the render)
// before Idiomorph syncs the children; the runtime copies the marked entries
// into the render, so the children sync keeps them. `morphChildren` below is
// that sync, reduced to what matters here: the old children become the new.

function morphContainer(el, html) {
  const holder = document.createElement("div")
  holder.innerHTML = html
  const next = holder.firstElementChild
  const event = new window.CustomEvent("turbo:before-morph-element", {
    bubbles: true,
    cancelable: true,
    detail: { currentElement: el, newElement: next },
  })
  el.dispatchEvent(event)
  if (event.defaultPrevented) return
  el.replaceChildren(...next.childNodes)
}

test("a morph of the container whose render has no entries keeps them; the next pick replaces them", () => {
  const { root, controller, input } = mount(picker() + LIST)
  choose(input, [png("a.png"), png("b.png", 11), svg("c.svg")])
  run(controller, [listOp()])

  morphContainer(root.querySelector("#refused"), LIST)

  expect(listed(root)).toEqual(["b.png is too large.", "c.svg is not a PNG."])
  expect(root.querySelector("#refused-heading").textContent).toBe("Not added")

  choose(input, [svg("e.svg")])
  run(controller, [listOp()])

  expect(listed(root)).toEqual(["e.svg is not a PNG."])
})

test("a container restored with its entries (a Turbo cache restore: a new node) keeps them through a morph", () => {
  const { root, controller, input } = mount(picker() + LIST)
  choose(input, [svg("c.svg")])
  run(controller, [listOp()])
  // A snapshot restore puts a copy of the page back: the same markup, new nodes
  // the op never listed into.
  const restored = root.querySelector("#refused").cloneNode(true)
  root.querySelector("#refused").replaceWith(restored)

  morphContainer(restored, LIST)

  expect(listed(root)).toEqual(["c.svg is not a PNG."])
})

test("a morph of an element without entries leaves its render alone", () => {
  const { root } = mount(LIST)

  morphContainer(root.querySelector("#refused"), `<div id="refused"><h3 id="refused-heading">Changed</h3><template></template></div>`)

  expect(root.querySelector("#refused-heading").textContent).toBe("Changed")
  expect(listed(root)).toEqual([])
})

test("a morph another listener cancels, before or after the runtime's, leaves the entries once", () => {
  const { root, controller, input } = mount(picker() + LIST)
  choose(input, [svg("c.svg")])
  run(controller, [listOp()])
  const container = root.querySelector("#refused")

  // Before: a listener on the element runs ahead of the runtime's document one.
  const cancel = (event) => event.preventDefault()
  container.addEventListener("turbo:before-morph-element", cancel)
  morphContainer(container, LIST)
  container.removeEventListener("turbo:before-morph-element", cancel)
  expect(listed(root)).toEqual(["c.svg is not a PNG."])

  // After: a document listener added later runs behind it; the copies went
  // into a render Turbo then discards.
  document.addEventListener("turbo:before-morph-element", cancel)
  try {
    morphContainer(container, LIST)
  } finally {
    document.removeEventListener("turbo:before-morph-element", cancel)
  }
  expect(listed(root)).toEqual(["c.svg is not a PNG."])
})

test("two morphs in a row keep the entries once; the next pick replaces them", () => {
  const { root, controller, input } = mount(picker() + LIST)
  choose(input, [svg("c.svg")])
  run(controller, [listOp()])
  const container = root.querySelector("#refused")

  morphContainer(container, LIST)
  morphContainer(container, LIST)

  expect(listed(root)).toEqual(["c.svg is not a PNG."])

  choose(input, [svg("e.svg"), png("b.png", 11)])
  run(controller, [listOp()])

  expect(listed(root)).toEqual(["e.svg is not a PNG.", "b.png is too large."])
})

test("the removal ask (no newElement) is ignored", () => {
  const { root, controller, input } = mount(picker() + LIST)
  choose(input, [svg("c.svg")])
  run(controller, [listOp()])
  const container = root.querySelector("#refused")

  const event = new window.CustomEvent("turbo:before-morph-element", { bubbles: true, cancelable: true, detail: {} })
  container.dispatchEvent(event)

  expect(event.defaultPrevented).toBe(false)
  expect(listed(root)).toEqual(["c.svg is not a PNG."])
})

test("registration is idempotent: one morph listener however often it runs", () => {
  // A second listener would copy the entries into the render once more, so
  // every refused file would show twice after a morph. Count the
  // registrations; the stub does not forward, so the listener beforeAll added
  // stays the only real one for the tests after this.
  mod.__resetReactiveRejectedFilesForTest()
  const added = []
  const real = document.addEventListener
  document.addEventListener = (type) => added.push(type)
  try {
    mod.registerReactiveRejectedFiles()
    mod.registerReactiveRejectedFiles()
    mod.registerReactiveRejectedFiles()
  } finally {
    document.addEventListener = real
  }

  expect(added).toEqual(["turbo:before-morph-element"])
})
