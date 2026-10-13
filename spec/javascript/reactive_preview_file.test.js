// Issue #375: js.preview_file(to, into:, name:) — paint the file a file input
// holds onto an <img> before any upload, through an object URL the CLIENT
// creates (URL.createObjectURL) and owns. The op carries no URL, and a `url`
// key on a raw op list is never read, so the `src` refusal of set_attr (issue
// #96) stays whole: only an <img> ever gets a src, and only a blob: URL made
// from the input's own File.
//
// The runtime keeps the last URL per img and revokes it on a re-pick, on a
// clear or a non-image file, and once the img leaves the page or loses that
// src (a morph that strips it in place) — a MutationObserver that runs only
// while a preview is live.
//
// happy-dom has no settable FileList and no real object URLs, so these tests
// define `files` on the input and stub URL.createObjectURL/revokeObjectURL;
// spec/system/preview_file_spec.rb proves the real thing in Chromium.
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll, beforeEach, afterEach } from "bun:test"
import { Window } from "happy-dom"

let mod
let ReactiveController
const window = new Window()
const SAVED = {}
let created
let revoked
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
  revoked = []
  warnings = []
  URL.createObjectURL = (file) => {
    created.push(file)
    return `blob:test/${created.length}`
  }
  URL.revokeObjectURL = (url) => revoked.push(url)
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

// MutationObserver callbacks are microtasks; a macrotask is past all of them.
const settle = () => new Promise((resolve) => setTimeout(resolve, 0))

const png = (name = "a.png") => new File(["png"], name, { type: "image/png" })
const txt = (name = "notes.txt") => new File(["txt"], name, { type: "text/plain" })

function mount(html, { id = "r" } = {}) {
  document.body.insertAdjacentHTML(
    "beforeend",
    `<div id="${id}" data-controller="reactive" data-reactive-token-value="t">${html}</div>`,
  )
  const root = document.getElementById(id)
  const controller = new ReactiveController()
  controller.element = root
  return { root, controller }
}

const FIELD = `<input type="file" id="photo-file"><img id="photo" alt=""><span id="photo-name"></span>`

function choose(input, files) {
  Object.defineProperty(input, "files", { value: files, configurable: true })
}

function run(controller, ops) {
  controller.runOps({ params: { ops }, target: controller.element, preventDefault() {} })
}

const OP = ["preview_file", { to: "#photo-file", into: "#photo", name: "#photo-name" }]

// --- painting the preview ---------------------------------------------------

test("an image file sets img.src to an object URL made from that File", () => {
  const { root, controller } = mount(FIELD)
  const file = png()
  choose(root.querySelector("#photo-file"), [file])

  run(controller, [OP])

  expect(created).toEqual([file])
  expect(root.querySelector("#photo").getAttribute("src")).toBe("blob:test/1")
  expect(root.querySelector("#photo-name").textContent).toBe("a.png")
})

test("a url key on a raw op list is ignored — the src is always the client's own object URL", () => {
  const { root, controller } = mount(FIELD)
  choose(root.querySelector("#photo-file"), [png()])

  run(controller, [["preview_file", { to: "#photo-file", into: "#photo", url: "javascript:alert(1)" }]])

  expect(root.querySelector("#photo").getAttribute("src")).toBe("blob:test/1")
})

test("choosing a second image revokes the first object URL and shows the second", () => {
  const { root, controller } = mount(FIELD)
  const input = root.querySelector("#photo-file")
  choose(input, [png("one.png")])
  run(controller, [OP])
  choose(input, [png("two.png")])

  run(controller, [OP])

  expect(revoked).toEqual(["blob:test/1"])
  expect(root.querySelector("#photo").getAttribute("src")).toBe("blob:test/2")
  expect(root.querySelector("#photo-name").textContent).toBe("two.png")
})

test("clearing the input removes src, revokes the URL and clears the name", () => {
  const { root, controller } = mount(FIELD)
  const input = root.querySelector("#photo-file")
  choose(input, [png()])
  run(controller, [OP])
  choose(input, [])

  run(controller, [OP])

  expect(revoked).toEqual(["blob:test/1"])
  expect(root.querySelector("#photo").hasAttribute("src")).toBe(false)
  expect(root.querySelector("#photo-name").textContent).toBe("")
})

test("a non-image file removes src, revokes the URL and creates none", () => {
  const { root, controller } = mount(FIELD)
  const input = root.querySelector("#photo-file")
  choose(input, [png()])
  run(controller, [OP])
  choose(input, [txt()])

  run(controller, [OP])

  expect(created.length).toBe(1)
  expect(revoked).toEqual(["blob:test/1"])
  expect(root.querySelector("#photo").hasAttribute("src")).toBe(false)
  expect(root.querySelector("#photo-name").textContent).toBe("")
})

test("a server-rendered src is cleared but never revoked (it is not ours)", () => {
  const { root, controller } = mount(`<input type="file" id="photo-file"><img id="photo" src="/avatar.png">`)
  choose(root.querySelector("#photo-file"), [])

  run(controller, [["preview_file", { to: "#photo-file", into: "#photo" }]])

  expect(revoked).toEqual([])
  expect(root.querySelector("#photo").hasAttribute("src")).toBe(false)
})

test("several files preview the first IMAGE file only", () => {
  const { root, controller } = mount(FIELD)
  const second = png("second.png")
  choose(root.querySelector("#photo-file"), [txt(), second, png("third.png")])

  run(controller, [OP])

  expect(created).toEqual([second])
  expect(root.querySelector("#photo-name").textContent).toBe("second.png")
})

test("name: is optional", () => {
  const { root, controller } = mount(FIELD)
  choose(root.querySelector("#photo-file"), [png()])

  run(controller, [["preview_file", { to: "#photo-file", into: "#photo" }]])

  expect(root.querySelector("#photo").getAttribute("src")).toBe("blob:test/1")
  expect(root.querySelector("#photo-name").textContent).toBe("")
})

test("global: true resolves into: and name: document-wide", () => {
  document.body.innerHTML = `<img id="outside"><b id="outside-name"></b>`
  const { root, controller } = mount(`<input type="file" id="photo-file">`)
  choose(root.querySelector("#photo-file"), [png()])

  run(controller, [["preview_file", { to: "#photo-file", into: "#outside", name: "#outside-name", global: true }]])

  expect(document.getElementById("outside").getAttribute("src")).toBe("blob:test/1")
  expect(document.getElementById("outside-name").textContent).toBe("a.png")
})

// --- refusals ---------------------------------------------------------------

test("a target that is not a file input warns and skips", () => {
  const { root, controller } = mount(`<input type="text" id="photo-file"><img id="photo">`)
  choose(root.querySelector("#photo-file"), [png()])

  run(controller, [["preview_file", { to: "#photo-file", into: "#photo" }]])

  expect(created).toEqual([])
  expect(root.querySelector("#photo").hasAttribute("src")).toBe(false)
  expect(warnings.join("\n")).toContain("preview_file")
})

for (const tag of ["iframe", "script", "frame", "video", "div"]) {
  test(`an into: that is a <${tag}>, not an <img>, warns and never gets a src`, () => {
    const { root, controller } = mount(`<input type="file" id="photo-file"><${tag} id="photo"></${tag}>`)
    choose(root.querySelector("#photo-file"), [png()])

    run(controller, [["preview_file", { to: "#photo-file", into: "#photo" }]])

    expect(created).toEqual([])
    expect(root.querySelector("#photo").hasAttribute("src")).toBe(false)
    expect(warnings.join("\n")).toContain("preview_file")
  })
}

test("an into: that matches nothing warns and creates no URL", () => {
  const { root, controller } = mount(`<input type="file" id="photo-file">`)
  choose(root.querySelector("#photo-file"), [png()])

  run(controller, [["preview_file", { to: "#photo-file", into: "#missing" }]])

  expect(created).toEqual([])
  expect(warnings.join("\n")).toContain("preview_file")
})

// --- revoking when the img goes away ---------------------------------------

test("removing the img revokes its object URL", async () => {
  const { root, controller } = mount(FIELD)
  choose(root.querySelector("#photo-file"), [png()])
  run(controller, [OP])

  root.querySelector("#photo").remove()
  await settle()

  expect(revoked).toEqual(["blob:test/1"])
})

test("replacing the img (a morph that swaps the node) revokes the old node's URL", async () => {
  const { root, controller } = mount(FIELD)
  choose(root.querySelector("#photo-file"), [png()])
  run(controller, [OP])

  root.querySelector("#photo").outerHTML = `<img id="photo" alt="">`
  await settle()

  expect(revoked).toEqual(["blob:test/1"])
})

test("replacing the whole root revokes the URL of an img inside it", async () => {
  const { root, controller } = mount(FIELD)
  choose(root.querySelector("#photo-file"), [png()])
  run(controller, [OP])

  root.replaceWith(document.createElement("div"))
  await settle()

  expect(revoked).toEqual(["blob:test/1"])
})

test("a morph that strips the src in place revokes the URL", async () => {
  const { root, controller } = mount(FIELD)
  choose(root.querySelector("#photo-file"), [png()])
  run(controller, [OP])

  root.querySelector("#photo").removeAttribute("src")
  await settle()

  expect(revoked).toEqual(["blob:test/1"])
})

test("an img moved within the page in one task keeps its URL", async () => {
  const { root, controller } = mount(`${FIELD}<section id="elsewhere"></section>`)
  choose(root.querySelector("#photo-file"), [png()])
  run(controller, [OP])

  root.querySelector("#elsewhere").append(root.querySelector("#photo"))
  await settle()

  expect(revoked).toEqual([])
  expect(root.querySelector("#photo").getAttribute("src")).toBe("blob:test/1")
})

test("a URL is revoked once, never twice", async () => {
  const { root, controller } = mount(FIELD)
  const input = root.querySelector("#photo-file")
  choose(input, [png()])
  run(controller, [OP])
  choose(input, [])
  run(controller, [OP])

  root.querySelector("#photo").remove()
  await settle()

  expect(revoked).toEqual(["blob:test/1"])
})

// --- the server-pushed path (reply.js) ---------------------------------------

test("the reactive:js stream action runs preview_file scoped to its target root", () => {
  window.Turbo = { StreamActions: {} }
  globalThis.window = window
  mod.registerReactiveJs()
  const { root } = mount(FIELD)
  choose(root.querySelector("#photo-file"), [png()])
  const stream = document.createElement("turbo-stream")
  stream.setAttribute("target", "r")
  stream.setAttribute("data-reactive-ops", JSON.stringify([OP]))

  window.Turbo.StreamActions["reactive:js"].call(stream)

  expect(root.querySelector("#photo").getAttribute("src")).toBe("blob:test/1")
  delete window.Turbo
})
