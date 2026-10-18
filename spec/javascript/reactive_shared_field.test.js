// A shared field posts with its own root AND the host's actions (issue #434).
//
// A reactive component rendered inside another is its own root: the host's
// #collectFields skips every control under a nested token-bearing root (issue
// #15). A control marked data-reactive-shared-field (reactive_shared_field) is
// the opt-in exception: it is collected by its own root and by the next
// token-bearing root above it, one level only. Nested client-only roots stay
// transparent on both sides (issue #410).
//
// happy-dom, so selectors, closest() and FormData are real.
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll, beforeEach, afterEach } from "bun:test"
import { Window } from "happy-dom"

const window = new Window()
let ReactiveController
const SAVED = {}
let posts

beforeAll(async () => {
  mock.module("@hotwired/stimulus", () => ({ Controller: class {} }))
  ReactiveController = (await import("../../app/javascript/phlex/reactive/reactive_controller.js")).default
})

// A JSON body is parsed; a FormData body is kept as { multipart, form } so a
// test can read its wire keys.
beforeEach(() => {
  for (const key of ["document", "window", "Event", "CustomEvent", "MutationObserver", "fetch"]) SAVED[key] = globalThis[key]
  globalThis.document = window.document
  globalThis.window = window
  globalThis.Event = window.Event
  globalThis.CustomEvent = window.CustomEvent
  globalThis.MutationObserver = window.MutationObserver
  window.Turbo = { renderStreamMessage: () => {} }
  posts = []
  globalThis.fetch = (path, opts) => {
    posts.push(opts.body instanceof FormData ? { multipart: true, form: opts.body } : JSON.parse(opts.body))
    return Promise.resolve({
      redirected: false,
      ok: true,
      headers: { get: () => "text/vnd.turbo-stream.html" },
      text: () => Promise.resolve(""),
    })
  }
  document.body.innerHTML = ""
})

afterEach(() => {
  for (const root of document.querySelectorAll('[data-controller~="reactive"]')) root.__controller?.disconnect()
  for (const [key, value] of Object.entries(SAVED)) globalThis[key] = value
})

const flush = () => new Promise((resolve) => setTimeout(resolve, 0))

// One controller per awake root, as Stimulus connects them. The mocked
// Stimulus has no values API: tokenValue mirrors the attribute.
function mount(html) {
  document.body.innerHTML = html
  for (const root of document.querySelectorAll('[data-controller~="reactive"]')) {
    const controller = new ReactiveController()
    controller.element = root
    controller.tokenValue = root.getAttribute("data-reactive-token-value") ?? ""
    root.__controller = controller
    controller.connect()
  }
}

// Stimulus routes an action to the controller of the NEAREST root.
async function click(id) {
  const el = document.getElementById(id)
  const root = el.closest('[data-controller~="reactive"]')
  const event = new window.Event("click", { bubbles: true, cancelable: true })
  Object.defineProperty(event, "currentTarget", { value: el, configurable: true })
  event.params = { action: el.dataset.reactiveActionParam, params: "{}" }
  root.__controller.dispatch(event)
  await flush()
  await flush()
}

// The issue's reproduction: a picker widget (its own server root, its own
// action) inside an item form that saves through a reactive action.
const PICKER = (extra = "") => `
  <div id="picker" data-controller="reactive" data-reactive-token-value="picker-token">
    <input type="hidden" name="item[choice]" value="b" data-reactive-shared-field>
    <input name="picker_query" value="internal">
    <button id="pick" data-reactive-action-param="pick">Pick b</button>
    ${extra}
  </div>`

const FORM = (inner) => `
  <div id="item-form" data-controller="reactive" data-reactive-token-value="form-token">
    <input name="item[title]" value="Lamp">
    ${inner}
    <button id="save" data-reactive-action-param="save">Save</button>
  </div>`

test("the host's action posts a shared field from a nested server root", async () => {
  mount(FORM(PICKER()))

  await click("save")

  expect(posts).toHaveLength(1)
  expect(posts[0].token).toBe("form-token")
  expect(posts[0].params).toEqual({ "item[title]": "Lamp", "item[choice]": "b" })
})

test("the nested root's own action still collects its own fields, shared one included", async () => {
  mount(FORM(PICKER()))

  await click("pick")

  expect(posts).toHaveLength(1)
  expect(posts[0].token).toBe("picker-token")
  expect(posts[0].params).toEqual({ "item[choice]": "b", picker_query: "internal" })
})

test("without the marker the nested root keeps every field (issue #15)", async () => {
  mount(FORM(PICKER()).replace(" data-reactive-shared-field", ""))

  await click("save")

  expect(posts[0].params).toEqual({ "item[title]": "Lamp" })
})

test("a grand-host does not collect a shared field two levels down", async () => {
  mount(`
    <div id="page" data-controller="reactive" data-reactive-token-value="page-token">
      <input name="page_note" value="top">
      <button id="publish" data-reactive-action-param="publish">Publish</button>
      ${FORM(PICKER())}
    </div>`)

  await click("publish")
  await click("save")

  expect(posts.map((p) => p.token)).toEqual(["page-token", "form-token"])
  expect(posts[0].params).toEqual({ page_note: "top" })
  expect(posts[1].params).toEqual({ "item[title]": "Lamp", "item[choice]": "b" })
})

test("client-only roots between the field, its root and the host stay transparent (issue #410)", async () => {
  mount(`
    <div id="item-form" data-controller="reactive" data-reactive-token-value="form-token">
      <input name="item[title]" value="Lamp">
      <div id="filter" data-controller="reactive">
        <div id="picker" data-controller="reactive" data-reactive-token-value="picker-token">
          <div id="picker-search" data-controller="reactive">
            <input type="hidden" name="item[choice]" value="b" data-reactive-shared-field>
            <input name="picker_query" value="internal">
          </div>
          <button id="pick" data-reactive-action-param="pick">Pick b</button>
        </div>
      </div>
      <button id="save" data-reactive-action-param="save">Save</button>
    </div>`)

  await click("save")
  await click("pick")

  expect(posts.map((p) => p.token)).toEqual(["form-token", "picker-token"])
  expect(posts[0].params).toEqual({ "item[title]": "Lamp", "item[choice]": "b" })
  expect(posts[1].params).toEqual({ "item[choice]": "b", picker_query: "internal" })
})

test("a shared editor is collected by the host too", async () => {
  mount(FORM(PICKER('<div name="item[note]" contenteditable="true" data-reactive-shared-field>Hi</div>')))

  await click("save")

  expect(posts[0].params).toEqual({ "item[title]": "Lamp", "item[choice]": "b", "item[note]": "Hi" })
})

test("a shared field rides the multipart body when the host posts a file", async () => {
  mount(FORM(`<input type="file" name="item[photo]" id="photo">${PICKER()}`))
  Object.defineProperty(document.getElementById("photo"), "files", {
    value: [new File(["x"], "photo.txt", { type: "text/plain" })],
    configurable: true,
  })

  await click("save")

  expect(posts).toHaveLength(1)
  expect(posts[0].multipart).toBe(true)
  const form = posts[0].form
  expect(form.get("token")).toBe("form-token")
  expect(form.get("params[item][title]")).toBe("Lamp")
  expect(form.get("params[item][choice]")).toBe("b")
  expect(form.get("params[picker_query]")).toBeNull()
  expect(form.get("params[item][photo]").name).toBe("photo.txt")
})

test("a shared file input inside the nested root posts with the host", async () => {
  mount(FORM(PICKER('<input type="file" name="item[scan]" id="scan" data-reactive-shared-field>')))
  Object.defineProperty(document.getElementById("scan"), "files", {
    value: [new File(["x"], "scan.txt", { type: "text/plain" })],
    configurable: true,
  })

  await click("save")

  expect(posts[0].multipart).toBe(true)
  expect(posts[0].form.get("params[item][choice]")).toBe("b")
  expect(posts[0].form.get("params[item][scan]").name).toBe("scan.txt")
})
