// on(:action, event: "app:item-created", window: true, detail_params: { id: :id })
// (issue #462): a server trigger bound to a CustomEvent posts named values from
// event.detail as params. The Ruby helper emits the mapping as
// data-reactive-detail-params-param='{"<param>":"<detail key>"}'; the client
// reads each listed top-level key off event.detail in dispatch() and merges
// the values UNDER the static params (data-reactive-params-param wins), before
// the root's fields are collected. Wire contract:
//
//   * only a flat scalar is copied — a String, a finite Number, a Boolean;
//   * a missing event.detail, a non-object one, a missing key, null or
//     undefined sends NOTHING for that param (the server's schema refuses or
//     defaults it; the client never invents a value);
//   * an Object or Array is skipped, warned under verbose_errors
//     (data-reactive-verbose="true" on the root);
//   * the mapping is an allowlist: a detail key it does not name is never sent;
//   * the multipart body (a chosen file in the root) carries the same values
//     as scalar fields, params[<name>];
//   * an event queued by phlex/reactive/early before the root connects posts
//     the same params once replayed — the replay keeps detail and params.
//
// happy-dom, so the roots and the events are real. Stimulus is mocked: a
// "live" dispatch is the controller's dispatch(event) with the params Stimulus
// would stamp (data-reactive-*-param, JSON typecast).
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll, beforeEach, afterEach } from "bun:test"
import { Window } from "happy-dom"

const KEY = Symbol.for("phlex-reactive.early")
const window = new Window()
let ReactiveController
const SAVED = {}
let posts
let warns
const realWarn = console.warn

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
    posts.push(opts.body)
    return Promise.resolve({
      redirected: false,
      ok: true,
      headers: { get: () => "text/vnd.turbo-stream.html" },
      text: () => Promise.resolve(""),
    })
  }
  warns = []
  console.warn = (...args) => warns.push(args.join(" "))
  document.head.innerHTML = ""
  document.body.innerHTML = ""
  if (globalThis[KEY]) globalThis[KEY].queue.length = 0
})

afterEach(() => {
  for (const root of document.querySelectorAll('[data-controller~="reactive"]')) root.__controller?.disconnect()
  console.warn = realWarn
  for (const [key, value] of Object.entries(SAVED)) globalThis[key] = value
})

const flush = () => new Promise((resolve) => setTimeout(resolve, 0))
const settle = async () => {
  await flush()
  await flush()
}
const json = (body) => JSON.parse(body)

// Connect one controller on the root, as Stimulus would. The mocked Stimulus
// has no values API: tokenValue mirrors the attribute.
function connect(root) {
  const controller = new ReactiveController()
  controller.element = root
  controller.tokenValue = root.getAttribute("data-reactive-token-value") ?? ""
  root.__controller = controller
  controller.connect()
  return controller
}

// The list: its root is the trigger, bound to the page-level custom event. The
// attribute shapes are the Ruby on()'s verbatim.
const DETAIL_PARAMS = '{"id":"id"}'
function list({ detailParams = DETAIL_PARAMS, params = "{}", verbose = false, inner = "" } = {}) {
  return `<div id="list" data-controller="reactive" data-reactive-token-value="list-token"
    ${verbose ? 'data-reactive-verbose="true"' : ""}
    data-action="app:item-created@window->reactive#dispatch"
    data-reactive-action-param="show_new_item" data-reactive-window-param="true"
    data-reactive-params-param='${params}' data-reactive-detail-params-param='${detailParams}'>${inner}</div>`
}

async function mount(html) {
  document.body.innerHTML = html
  await window.happyDOM.waitUntilComplete()
  await flush()
  return document.getElementById("list")
}

// Stimulus's window listener hands dispatch() the event with currentTarget the
// window and the trigger's params typecast (a JSON attribute is an object).
async function live(root, detail, { params = {}, detailParams = { id: "id" } } = {}) {
  const event = new window.CustomEvent("app:item-created", { bubbles: true, detail })
  Object.defineProperty(event, "currentTarget", { value: window, configurable: true })
  event.params = { action: "show_new_item", params, window: true, detailParams }
  root.__controller.dispatch(event)
  await settle()
}

// --- the live path ---------------------------------------------------------

test("posts the mapped scalar off event.detail and skips a key the mapping does not name", async () => {
  const root = await mount(list())
  connect(root)

  await live(root, { id: 7, junk: {} })

  expect(posts).toHaveLength(1)
  expect(json(posts[0])).toEqual({ token: "list-token", act: "show_new_item", params: { id: 7 } })
})

test("copies a String and a Boolean as they are (the schema casts them server-side)", async () => {
  const root = await mount(list({ detailParams: '{"id":"id","urgent":"flag","name":"label"}' }))
  connect(root)

  await live(root, { id: "7", flag: false, label: "Milk" }, { detailParams: { id: "id", urgent: "flag", name: "label" } })

  expect(json(posts[0]).params).toEqual({ id: "7", urgent: false, name: "Milk" })
})

test("a missing event.detail posts nothing for the param", async () => {
  const root = await mount(list())
  connect(root)

  await live(root, undefined)

  expect(posts).toHaveLength(1)
  expect(json(posts[0]).params).toEqual({})
})

test("a non-object detail, a missing key, null and undefined each post nothing", async () => {
  const root = await mount(list())
  connect(root)

  await live(root, "7")
  await live(root, { other: 7 })
  await live(root, { id: null })
  await live(root, { id: undefined })

  expect(posts).toHaveLength(4)
  for (const body of posts) expect(json(body).params).toEqual({})
  expect(warns).toEqual([])
})

test("a nested value is skipped and warned under verbose_errors; the scalar beside it still posts", async () => {
  const root = await mount(list({ detailParams: '{"id":"id","meta":"meta"}', verbose: true }))
  connect(root)

  await live(root, { id: 7, meta: { nested: true } }, { detailParams: { id: "id", meta: "meta" } })

  expect(json(posts[0]).params).toEqual({ id: 7 })
  expect(warns).toHaveLength(1)
  expect(warns[0]).toMatch(/detail_params/)
  expect(warns[0]).toMatch(/meta/)
})

test("an Array, NaN and Infinity are skipped too; nothing is warned without verbose_errors", async () => {
  const root = await mount(list({ detailParams: '{"id":"id","tags":"tags","n":"n","m":"m"}' }))
  connect(root)

  await live(root, { id: 7, tags: [1, 2], n: Number.NaN, m: Number.POSITIVE_INFINITY }, {
    detailParams: { id: "id", tags: "tags", n: "n", m: "m" },
  })

  expect(json(posts[0]).params).toEqual({ id: 7 })
  expect(warns).toEqual([])
})

test("a static param wins over the detail value of the same name", async () => {
  const root = await mount(list({ params: '{"id":1}' }))
  connect(root)

  await live(root, { id: 7 }, { params: { id: 1 } })

  expect(json(posts[0]).params).toEqual({ id: 1 })
})

test("the root's own fields are collected as before, under the detail values", async () => {
  const root = await mount(list({ inner: '<input name="filter" value="milk"><input name="id" value="99">' }))
  connect(root)

  await live(root, { id: 7 })

  // A detail value is an explicit trigger param, so it wins over a collected
  // field, as data-reactive-params-param does.
  expect(json(posts[0]).params).toEqual({ filter: "milk", id: 7 })
})

test("a mapping handed over as a JSON string (a non-typecasting harness) reads the same", async () => {
  const root = await mount(list())
  connect(root)

  await live(root, { id: 7 }, { detailParams: DETAIL_PARAMS })

  expect(json(posts[0]).params).toEqual({ id: 7 })
})

test("a malformed mapping posts the static params only", async () => {
  const root = await mount(list())
  connect(root)

  await live(root, { id: 7 }, { detailParams: "not json" })
  await live(root, { id: 7 }, { detailParams: ["id"] })

  expect(posts).toHaveLength(2)
  for (const body of posts) expect(json(body).params).toEqual({})
})

test("announces the detail values in reactive:before-dispatch, as the trigger's params", async () => {
  const root = await mount(list())
  connect(root)
  const seen = []
  root.addEventListener("reactive:before-dispatch", (event) => seen.push(event.detail.params))

  await live(root, { id: 7 })

  expect(seen).toEqual([{ id: 7 }])
})

// --- the multipart path ----------------------------------------------------

test("a chosen file in the root switches to FormData and the detail value rides as params[<name>]", async () => {
  const root = await mount(list({ inner: '<input type="file" name="attachment">' }))
  Object.defineProperty(root.querySelector("input"), "files", {
    value: [new File(["x"], "receipt.txt", { type: "text/plain" })],
    configurable: true,
  })
  connect(root)

  await live(root, { id: 7 })

  expect(posts).toHaveLength(1)
  const body = posts[0]
  expect(body).toBeInstanceOf(FormData)
  expect(body.get("token")).toBe("list-token")
  expect(body.get("act")).toBe("show_new_item")
  expect(body.get("params[id]")).toBe("7")
  expect(body.get("params[attachment]")).toBeInstanceOf(File)
})

// --- before the root connects (phlex/reactive/early, issue #273) -------------

test("an event queued before connect is replayed with the same params as a live one", async () => {
  const root = await mount(list())
  // The entry early.js queues for a window-bound custom event, in its wire
  // shape (reactive_early.test.js proves the recording, detail included). It
  // is written by hand here because early.js binds the shared queue once per
  // process and two suites delete that global, so the recorder and the
  // controller stop sharing one queue in a combined run; the replay is the
  // controller's own path either way.
  const event = new window.CustomEvent("app:item-created", { bubbles: true, detail: { id: 7, junk: {} } })
  document.body.dispatchEvent(event)
  const token = "app:item-created@window->reactive#dispatch"
  const queue = (globalThis[KEY] ??= { queue: [], connected: new WeakSet() }).queue
  queue.push({
    event,
    el: root,
    root,
    descs: [{ token, type: "app:item-created", filter: undefined, win: true, method: "dispatch" }],
    win: true,
    at: performance.now(),
  })
  expect(posts).toHaveLength(0)

  connect(root)
  await settle()

  expect(posts).toHaveLength(1)
  const replayed = json(posts[0])
  expect(replayed).toEqual({ token: "list-token", act: "show_new_item", params: { id: 7 } })

  await live(root, { id: 7, junk: {} })
  expect(json(posts[1])).toEqual(replayed)
})
