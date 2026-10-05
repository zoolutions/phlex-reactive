// The DEFAULT client entry, phlex/reactive/reactive_controller (issue #275).
//
// The runtime's source is a core plus feature modules. This entry imports all
// of them statically and hands each feature to the core before anything can
// connect — so it behaves as the single-file client did before the split:
//
//   * a feature connects INSIDE connect(), in the same task: a draft is
//     restored there, a lazy shell armed there;
//   * nothing is imported on demand, nothing waits: `featuresReady` is the
//     already-resolved promise, no timeout is armed, no request is held back;
//   * the "module still on its way" window of the opt-in phlex/reactive/core
//     does not exist — and with it none of that window's edge cases.
//
// (The rest of the JS suite imports this same entry, so every other test file
// runs on this path too. The opt-in path is forced, where it is under test,
// with the cold reset seam.)
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll, beforeEach, afterEach } from "bun:test"
import { Window } from "happy-dom"

const KEY = "phlex-reactive:persist:entry"
const window = new Window()
let entry
let ReactiveController

beforeAll(async () => {
  mock.module("@hotwired/stimulus", () => ({ Controller: class {} }))
  entry = await import("../../app/javascript/phlex/reactive/reactive_controller.js")
  ReactiveController = entry.default
})

const REAL = { setTimeout: globalThis.setTimeout, localStorage: globalThis.localStorage }
let store
let timers
let posts

beforeEach(() => {
  entry.__resetReactiveFeaturesForTest() // the default entry's own state: every feature handed over
  globalThis.document = window.document
  globalThis.window = window
  globalThis.CustomEvent = window.CustomEvent
  document.head.innerHTML = ""
  document.body.innerHTML = ""
  store = new Map()
  globalThis.localStorage = {
    getItem: (key) => (store.has(key) ? store.get(key) : null),
    setItem: (key, value) => store.set(key, String(value)),
    removeItem: (key) => store.delete(key),
  }
  // Every timer the client arms is recorded (and never fired).
  timers = []
  globalThis.setTimeout = (fn, ms) => timers.push({ fn, ms })
  posts = []
  window.Turbo = { StreamActions: {}, renderStreamMessage: () => {} }
  globalThis.fetch = (url, options) => {
    posts.push({ url, body: options.body ? JSON.parse(options.body) : null })
    return Promise.resolve({
      redirected: false,
      ok: true,
      status: 200,
      headers: { get: () => "text/vnd.turbo-stream.html" },
      text: () => Promise.resolve(""),
    })
  }
})

afterEach(() => {
  globalThis.setTimeout = REAL.setTimeout
  globalThis.localStorage = REAL.localStorage
})

const tick = () => new Promise((resolve) => REAL.setTimeout(resolve, 0))

function seedDraft(fields) {
  store.set(KEY, JSON.stringify({ v: 1, savedAt: Date.now(), fields }))
}

function persistRoot() {
  document.body.innerHTML = `
    <form id="f"><div id="root" data-controller="reactive" data-reactive-token-value="tok"
         data-reactive-persist='{"key":"entry","ttl":60,"debounce":0}'>
      <input type="text" name="note"><input type="text" name="extra">
    </div></form>`
  const root = document.getElementById("root")
  const controller = new ReactiveController()
  controller.element = root
  controller.tokenValue = "tok"
  return { root, controller, note: root.querySelector('[name="note"]'), extra: root.querySelector('[name="extra"]') }
}

test("the entry hands every feature in the core's table to the core", () => {
  expect(entry.reactiveFeatureNames()).toEqual(["persist", "defer", "form", "effects", "dev"])
  expect(typeof entry.registerReactiveFeature).toBe("function")
})

test("the entry re-exports the core's public names", () => {
  for (const name of ["enableLatencySim", "disableLatencySim", "registerReactiveActions", "ACTIVE_ATTR", "REQUESTS_ATTR"]) {
    expect(entry[name]).toBeDefined()
  }
})

test("a draft is restored inside connect(), and the root is announced after it", () => {
  seedDraft({ note: "Ada" })
  const { root, controller, note } = persistRoot()
  const seen = []
  root.addEventListener("reactive:persist-restored", () => seen.push("restored"))
  root.addEventListener("reactive:connect", () => seen.push(`connect, note=${note.value}`))

  controller.connect()

  expect(note.value).toBe("Ada")
  expect(seen).toEqual(["restored", "connect, note=Ada"])
})

test("nothing waits: featuresReady stays the resolved promise and no import timeout is armed", () => {
  seedDraft({ note: "Ada" })
  const { controller } = persistRoot()
  const before = controller.featuresReady

  controller.connect()

  expect(controller.featuresReady).toBe(before)
  expect(timers).toEqual([])
})

test("an action fired right after connect posts the restored values without waiting for anything", async () => {
  seedDraft({ note: "Ada" })
  const { controller } = persistRoot()
  controller.connect()
  // If the request waited on featuresReady it would hang on this.
  controller.featuresReady = new Promise(() => {})

  await controller.dispatch({ params: { action: "save", params: "{}" }, preventDefault: () => {} })
  await controller.queue

  expect(posts.map((post) => [post.body.act, post.body.params.note])).toEqual([["save", "Ada"]])
})

test("an edit right after connect is drafted by that edit: there is no import window to fall into", () => {
  seedDraft({ note: "Ada" })
  const { controller, extra } = persistRoot()
  controller.connect()

  extra.value = "typed"
  extra.dispatchEvent(new window.Event("input", { bubbles: true }))

  expect(JSON.parse(store.get(KEY)).fields).toEqual({ note: "Ada", extra: "typed" })
})

test("the core's stand-in listeners for the import window are never installed", () => {
  const { controller } = persistRoot()
  const submitEnd = []
  const add = document.addEventListener.bind(document)
  document.addEventListener = (type, ...rest) => {
    if (type === "turbo:submit-end") submitEnd.push(rest[0])
    return add(type, ...rest)
  }

  try {
    controller.connect()
  } finally {
    document.addEventListener = add
  }

  // Only the feature's own listener — the stand-in exists for a root that waits.
  expect(submitEnd).toHaveLength(1)
})

test("a lazy shell is armed inside connect()", () => {
  document.body.innerHTML = `<div id="lazy" data-controller="reactive" data-reactive-defer-token="t" data-reactive-defer-pending="true"></div>`
  const controller = new ReactiveController()
  controller.element = document.getElementById("lazy")

  controller.connect()

  // The lazy-mount fetch has already been issued.
  expect(posts.map((post) => post.url)).toEqual(["/reactive/defer"])
})

test("a reactive:defer stream is applied in the same tick", () => {
  document.body.innerHTML = `<div id="totals"></div>`
  entry.registerReactiveDefer()

  window.Turbo.StreamActions["reactive:defer"].call({
    getAttribute: (name) => ({ target: "totals", "data-reactive-defer-token": "t" })[name] ?? null,
  })

  expect(posts.map((post) => post.url)).toEqual(["/reactive/defer"])
})

test("a persist op runs in the same tick", () => {
  seedDraft({ note: "Ada" })
  const { controller } = persistRoot()
  controller.connect()

  controller.runOps({ preventDefault() {}, params: { ops: JSON.stringify([["persist_clear", { to: "@root" }]]) } })

  expect(store.has(KEY)).toBe(false)
})

// --- loading both entries ---------------------------------------------------------

test("a second copy of the core says, loudly, that the client was loaded twice", async () => {
  const consoleError = console.error
  const logged = []
  console.error = (...args) => logged.push(String(args[0]))

  try {
    // A second module instance of the runtime: what an app gets when it
    // imports the default bundle (its own copy inside) AND phlex/reactive/core
    // (which carries another).
    await import("../../app/javascript/phlex/reactive/runtime.js?second-copy")
    await tick()
  } finally {
    console.error = consoleError
  }

  expect(logged.filter((line) => line.includes("the client was loaded twice"))).toHaveLength(1)
  expect(logged[0]).toContain("phlex/reactive/reactive_controller")
  expect(logged[0]).toContain("phlex/reactive/core")
})
