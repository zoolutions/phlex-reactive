// Tokenless client-only roots are transparent to server round trips (issue #410).
//
// A ClientBindings component (reactive_filter, reactive_show, on_client) renders a
// reactive root with no identity token. Rendered inside a token-bearing
// component, it used to swallow that component's server triggers: Stimulus binds
// `change->reactive#dispatch` to the NEAREST reactive root, the client-only one,
// which has no token; and the outer root's #collectFields skipped every control
// under a nested root (issue #15). Now:
//
//   dispatch()       on a client-only root forwards to the nearest token-bearing
//                    ancestor root (skipping further client-only roots), waking a
//                    dormant one first.
//   #collectFields() looks through nested client-only roots; a nested
//                    token-bearing root keeps its own fields (issue #15).
//
// happy-dom, so selectors and events are real.
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
    posts.push(JSON.parse(opts.body))
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

// Connect one controller per awake root, in document order, as Stimulus does.
// The mocked Stimulus has no values API: tokenValue mirrors the attribute.
function connect(root) {
  const controller = new ReactiveController()
  controller.element = root
  controller.tokenValue = root.getAttribute("data-reactive-token-value") ?? ""
  root.__controller = controller
  controller.connect()
  return controller
}

function mount(html) {
  document.body.innerHTML = html
  for (const root of document.querySelectorAll('[data-controller~="reactive"]')) connect(root)
}

// Stimulus routes an action to the controller of the NEAREST root and stamps the
// trigger's params on the event. Mirror that: the nearest awake root's controller.
async function trigger(el, type = "change") {
  const root = el.closest('[data-controller~="reactive"]')
  const event = new window.Event(type, { bubbles: true, cancelable: true })
  Object.defineProperty(event, "currentTarget", { value: el, configurable: true })
  event.params = { action: el.dataset.reactiveActionParam, params: "{}" }
  root.__controller.dispatch(event)
  await flush()
  await flush()
}

function tick(box) {
  box.checked = true
  return trigger(box)
}

const box = (value, extra = "") =>
  `<input type="checkbox" name="tags[]" value="${value}" data-reactive-action-param="pick" ${extra}>`

const PICKER = `
  <div id="picker" data-controller="reactive" data-reactive-token-value="outer-token">
    <label>${box("red", 'id="red"')}</label>
    <div id="search" data-controller="reactive">
      <input name="q" form="none" value="">
      <label>${box("blue", 'id="blue"')}</label>
      <div id="deeper" data-controller="reactive">
        <label>${box("green", 'id="green"')}</label>
      </div>
    </div>
  </div>`

test("a trigger inside a nested client-only root dispatches on the token-bearing root", async () => {
  mount(PICKER)

  await tick(document.getElementById("blue"))

  expect(posts).toHaveLength(1)
  expect(posts[0].token).toBe("outer-token")
  expect(posts[0].act).toBe("pick")
  expect(posts[0].params["tags[]"]).toEqual(["blue"])
})

test("several client-only roots between the trigger and the server root resolve to it", async () => {
  mount(PICKER)

  await tick(document.getElementById("green"))

  expect(posts).toHaveLength(1)
  expect(posts[0].token).toBe("outer-token")
  expect(posts[0].params["tags[]"]).toEqual(["green"])
})

test("a trigger on the server root collects controls under its nested client-only roots", async () => {
  mount(PICKER)
  document.getElementById("blue").checked = true
  document.getElementById("green").checked = true

  await tick(document.getElementById("red"))

  expect(posts).toHaveLength(1)
  expect(posts[0].params["tags[]"]).toEqual(["red", "blue", "green"])
})

test("a nested token-bearing root keeps its own fields and its own triggers (issue #15)", async () => {
  mount(`
    <div id="outer" data-controller="reactive" data-reactive-token-value="outer-token">
      <input name="notes" value="outer notes">
      <button id="save" data-reactive-action-param="save">Save</button>
      <div id="row" data-controller="reactive" data-reactive-token-value="row-token">
        <input name="quantity" value="3">
        <button id="update" data-reactive-action-param="update">Update</button>
      </div>
    </div>`)

  await trigger(document.getElementById("save"), "click")
  await trigger(document.getElementById("update"), "click")

  expect(posts.map((p) => p.token)).toEqual(["outer-token", "row-token"])
  expect(posts[0].params).toEqual({ notes: "outer notes" })
  expect(posts[1].params).toEqual({ quantity: "3" })
})

test("a server field under a client-only root inside a nested server root stays with that nested root", async () => {
  mount(`
    <div id="outer" data-controller="reactive" data-reactive-token-value="outer-token">
      <button id="save" data-reactive-action-param="save">Save</button>
      <div id="row" data-controller="reactive" data-reactive-token-value="row-token">
        <div id="row-search" data-controller="reactive">
          <input name="quantity" value="3">
          <button id="update" data-reactive-action-param="update">Update</button>
        </div>
      </div>
    </div>`)

  await trigger(document.getElementById("save"), "click")
  await trigger(document.getElementById("update"), "click")

  expect(posts.map((p) => p.token)).toEqual(["outer-token", "row-token"])
  expect(posts[0].params).toEqual({})
  expect(posts[1].params).toEqual({ quantity: "3" })
})

test("a client-only root's own client bindings stay on that root", () => {
  mount(`
    <div id="picker" data-controller="reactive" data-reactive-token-value="outer-token">
      <div id="search" data-controller="reactive" data-reactive-filter-input='[name="q"]' data-reactive-filter-option="[data-option]">
        <input name="q" form="none" value="">
        <label data-option data-reactive-filter-text="blue">${box("blue")}</label>
        <label data-option data-reactive-filter-text="green">${box("green")}</label>
      </div>
    </div>`)
  const q = document.querySelector('[name="q"]')

  q.value = "gre"
  q.dispatchEvent(new window.Event("input", { bubbles: true }))

  const hidden = [...document.querySelectorAll("[data-option]")].map((el) => el.hidden)
  expect(hidden).toEqual([true, false])
  expect(posts).toHaveLength(0)
})

test("a held dispatch cancels the native default now, and the trigger reaches the woken root", async () => {
  document.body.innerHTML = `
    <div id="picker" data-reactive-dormant="reactive" data-reactive-token-value="outer-token">
      <div id="search" data-controller="reactive"><button id="go" type="submit" data-reactive-action-param="pick">Go</button></div>
    </div>`
  connect(document.getElementById("search"))
  const go = document.getElementById("go")
  const event = new window.Event("click", { bubbles: true, cancelable: true })
  Object.defineProperty(event, "currentTarget", { value: go, configurable: true })
  event.params = { action: "pick", params: "{}" }

  document.getElementById("search").__controller.dispatch(event)
  expect(event.defaultPrevented).toBe(true)

  Object.defineProperty(event, "currentTarget", { value: null, configurable: true })
  connect(document.getElementById("picker"))
  await flush()
  await flush()

  expect(posts).toHaveLength(1)
  expect(posts[0].token).toBe("outer-token")
})

test("a dormant token-bearing ancestor is woken and receives the forwarded dispatch", async () => {
  document.body.innerHTML = `
    <div id="picker" data-reactive-dormant="reactive" data-reactive-token-value="outer-token">
      <div id="search" data-controller="reactive">${box("blue", 'id="blue"')}</div>
    </div>`
  connect(document.getElementById("search"))
  const blue = document.getElementById("blue")
  blue.checked = true

  await trigger(blue)
  const picker = document.getElementById("picker")
  expect(picker.dataset.controller).toBe("reactive")
  expect(picker.dataset.reactiveDormant).toBeUndefined()
  expect(posts).toHaveLength(0)

  // Stimulus connects the woken root; the held dispatch runs then.
  connect(picker)
  await flush()
  await flush()

  expect(posts).toHaveLength(1)
  expect(posts[0].token).toBe("outer-token")
  expect(posts[0].params["tags[]"]).toEqual(["blue"])
})

test("with no token-bearing ancestor nothing is sent and the verbose gate warns once", async () => {
  mount(`
    <div id="search" data-controller="reactive" data-reactive-verbose="true">
      ${box("blue", 'id="blue"')}
    </div>`)
  const warnings = []
  const warn = console.warn
  console.warn = (...args) => warnings.push(args.join(" "))
  try {
    await tick(document.getElementById("blue"))
  } finally {
    console.warn = warn
  }

  expect(posts).toHaveLength(0)
  expect(warnings.filter((w) => w.includes("pick") && w.includes("no token"))).toHaveLength(1)
})

test("a lazy shell is not client-only: its own trigger is not forwarded", async () => {
  mount(`
    <div id="outer" data-controller="reactive" data-reactive-token-value="outer-token">
      <div id="shell" data-controller="reactive" data-reactive-lazy-on="click" data-reactive-defer-token="shell-token">
        <button id="load" data-reactive-action-param="pick">Load</button>
      </div>
    </div>`)

  await trigger(document.getElementById("load"), "click")

  expect(posts.every((p) => p.token !== "outer-token")).toBe(true)
})
