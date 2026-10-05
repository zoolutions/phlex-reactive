// Unit tests for the feature-module loader (issue #275, phase 1).
//
// The client is being split into a small core plus feature modules that load
// when a root's markup asks for them. This phase ships the loader only — no
// production feature has moved — so every test drives it with a FAKE feature
// registered through the test seam. Contract:
//
//   connect()   stays synchronous. It STARTS the imports a root needs (a
//               marker scan) and never awaits them: the early-queue drain
//               (issues #273/#274) still runs last, in the same task.
//   feature     { connect(controller), disconnect(controller) } — connect runs
//               when the import resolves, unless the root disconnected (or
//               reconnected) meanwhile; disconnect runs only for a feature
//               that connected on this connection.
//   ready       a promise on the controller, resolved once this root's
//               features are loaded and connected. It never rejects.
//   failure     never a silent dead root: reactive:error { kind: "feature",
//               feature, phase, error } on every root it costs, with phase
//               "load" (the import failed), "connect" (the feature threw) or
//               "detect" (its marker check threw). A failed import STAYS
//               failed until the page is reloaded — a browser caches a module
//               that failed to load — and is logged once per page.
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll, beforeEach } from "bun:test"
import { Window } from "happy-dom"

const window = new Window()
let ReactiveController
let setFeature
let resetFeatures

beforeAll(async () => {
  globalThis.document = window.document
  globalThis.CustomEvent = window.CustomEvent
  mock.module("@hotwired/stimulus", () => ({ Controller: class {} }))
  const mod = await import("../../app/javascript/phlex/reactive/reactive_controller.js")
  ReactiveController = mod.default
  setFeature = mod.__setReactiveFeatureForTest
  resetFeatures = mod.__resetReactiveFeaturesForTest
})

beforeEach(() => {
  globalThis.document = window.document
  globalThis.CustomEvent = window.CustomEvent
  document.body.innerHTML = ""
  resetFeatures()
})

const MARKER = "data-fake-feature"
const tick = () => new Promise((resolve) => setTimeout(resolve, 0))

// A root in the document; `marked` gives it the fake feature's marker.
function mountRoot({ marked = true, id = "root" } = {}) {
  const root = document.createElement("div")
  root.id = id
  if (marked) root.setAttribute(MARKER, "")
  document.body.appendChild(root)
  return root
}

function controllerFor(root) {
  const controller = new ReactiveController()
  controller.element = root
  return controller
}

// Registers the fake feature behind an import the test settles by hand.
function fakeFeature({ name = "fake" } = {}) {
  const log = []
  const feature = {
    connect: (controller) => log.push(["connect", controller]),
    disconnect: (controller) => log.push(["disconnect", controller]),
  }
  const pending = []
  let loads = 0
  setFeature(name, (root) => root.hasAttribute(MARKER), () => {
    loads++
    return new Promise((resolve, reject) => pending.push({ resolve, reject }))
  })
  return {
    log,
    loads: () => loads,
    resolve: () => pending.shift().resolve(feature),
    reject: (error) => pending.shift().reject(error),
  }
}

const namesOf = (log) => log.map(([name]) => name)

test("a root that needs no feature loads none and is ready at once", async () => {
  const fake = fakeFeature()
  const controller = controllerFor(mountRoot({ marked: false }))

  controller.connect()
  await controller.ready

  expect(fake.loads()).toBe(0)
  expect(fake.log).toEqual([])
})

test("ready is a resolved promise before connect() ever runs", async () => {
  const controller = controllerFor(mountRoot({ marked: false }))

  await expect(controller.ready).resolves.toBeUndefined()
})

test("connect() starts the import a marked root needs and connects the feature when it resolves", async () => {
  const fake = fakeFeature()
  const controller = controllerFor(mountRoot())

  controller.connect()
  expect(fake.loads()).toBe(1)
  expect(fake.log).toEqual([])

  fake.resolve()
  await controller.ready

  expect(fake.log).toEqual([["connect", controller]])
})

test("connect() does not wait for the import: the root is announced first", async () => {
  const fake = fakeFeature()
  const root = mountRoot()
  const order = []
  root.addEventListener("reactive:connect", () => order.push("reactive:connect"))
  const controller = controllerFor(root)

  controller.connect()
  order.push("connect returned")
  fake.resolve()
  await controller.ready
  order.push(...namesOf(fake.log))

  expect(order).toEqual(["reactive:connect", "connect returned", "connect"])
})

// The invariant #274 depends on: a trigger queued before connect is replayed
// INSIDE connect(), in the same task, whatever a feature import is doing. An
// await before the drain would let the event that woke a dormant root reach
// its live listener first and run twice.
test("a queued early trigger is replayed inside connect(), before a pending feature connects", async () => {
  const fake = fakeFeature()
  const root = mountRoot()
  const button = document.createElement("button")
  const token = "click->reactive#dispatch"
  button.setAttribute("data-action", token)
  root.appendChild(button)
  const early = (globalThis[Symbol.for("phlex-reactive.early")] ??= { queue: [], connected: new WeakSet() })
  const event = new window.MouseEvent("click", { bubbles: true, cancelable: true })
  early.queue.length = 0
  early.queue.push({
    event,
    el: button,
    root,
    descs: [{ token, type: "click", method: "dispatch", filter: "" }],
    at: performance.now(),
  })
  const controller = controllerFor(root)
  const order = []
  controller.dispatch = (replayed) => order.push(`replayed ${replayed.type}`)

  controller.connect()
  order.push("connect returned")
  fake.resolve()
  await controller.ready
  order.push(...namesOf(fake.log))

  expect(order).toEqual(["replayed click", "connect returned", "connect"])
  expect(early.queue).toEqual([])
})

test("ready stays pending until the feature has connected", async () => {
  const fake = fakeFeature()
  const controller = controllerFor(mountRoot())
  let settled = false

  controller.connect()
  controller.ready.then(() => (settled = true))
  await tick()
  expect(settled).toBe(false)

  fake.resolve()
  await controller.ready
  expect(settled).toBe(true)
})

test("two roots that need one feature import it once", async () => {
  const fake = fakeFeature()
  const first = controllerFor(mountRoot({ id: "a" }))
  const second = controllerFor(mountRoot({ id: "b" }))

  first.connect()
  second.connect()
  fake.resolve()
  await Promise.all([first.ready, second.ready])

  expect(fake.loads()).toBe(1)
  expect(fake.log).toEqual([
    ["connect", first],
    ["connect", second],
  ])
})

test("a root connecting after the feature loaded reuses the loaded module", async () => {
  const fake = fakeFeature()
  const first = controllerFor(mountRoot({ id: "a" }))
  first.connect()
  fake.resolve()
  await first.ready

  const second = controllerFor(mountRoot({ id: "b" }))
  second.connect()
  await second.ready

  expect(fake.loads()).toBe(1)
  expect(fake.log.at(-1)).toEqual(["connect", second])
})

test("a root that disconnects before the import resolves never connects the feature", async () => {
  const fake = fakeFeature()
  const controller = controllerFor(mountRoot())

  controller.connect()
  const ready = controller.ready
  controller.disconnect()
  fake.resolve()
  await ready

  expect(fake.log).toEqual([])
})

test("disconnect() disconnects a feature that connected, once", async () => {
  const fake = fakeFeature()
  const controller = controllerFor(mountRoot())
  controller.connect()
  fake.resolve()
  await controller.ready

  controller.disconnect()
  controller.disconnect()

  expect(fake.log).toEqual([
    ["connect", controller],
    ["disconnect", controller],
  ])
})

test("a root that reconnects while the import is pending connects the feature once", async () => {
  const fake = fakeFeature()
  const controller = controllerFor(mountRoot())

  controller.connect()
  controller.disconnect()
  controller.connect()
  fake.resolve()
  await controller.ready

  expect(fake.loads()).toBe(1)
  expect(fake.log).toEqual([["connect", controller]])
})

test("a failed import surfaces as reactive:error and marks the root; ready still resolves", async () => {
  const fake = fakeFeature()
  const root = mountRoot()
  const errors = []
  root.addEventListener("reactive:error", (event) => errors.push(event.detail))
  const consoleError = console.error
  const logged = []
  console.error = (...args) => logged.push(args)
  const controller = controllerFor(root)
  const failure = new Error("404")

  try {
    controller.connect()
    fake.reject(failure)
    await controller.ready
  } finally {
    console.error = consoleError
  }

  expect(errors).toEqual([{ kind: "feature", feature: "fake", phase: "load", error: failure }])
  expect(root.getAttribute("data-reactive-error")).toBe("feature")
  expect(logged).toEqual([
    ['[phlex-reactive] could not load the "fake" feature module; it stays unavailable until the page is reloaded', failure],
  ])
  expect(fake.log).toEqual([])
})

test("a feature whose connect throws is reported as a connect failure; ready still resolves", async () => {
  const root = mountRoot()
  const errors = []
  root.addEventListener("reactive:error", (event) => errors.push(event.detail))
  const failure = new Error("boom")
  setFeature(
    "fake",
    (el) => el.hasAttribute(MARKER),
    () =>
      Promise.resolve({
        connect: () => {
          throw failure
        },
        disconnect: () => {
          throw new Error("disconnect of a feature that never connected")
        },
      }),
  )
  const consoleError = console.error
  const logged = []
  console.error = (...args) => logged.push(args)
  const controller = controllerFor(root)

  try {
    controller.connect()
    await controller.ready
  } finally {
    console.error = consoleError
  }

  expect(errors).toEqual([{ kind: "feature", feature: "fake", phase: "connect", error: failure }])
  expect(logged).toEqual([['[phlex-reactive] the "fake" feature module failed to connect', failure]])
  expect(() => controller.disconnect()).not.toThrow()
})

// A browser caches a module that failed to load (a 404, an evaluation error):
// importing it again re-rejects without a request. So the loader does not
// pretend to retry — the feature is gone until the page is reloaded.
test("a failed import stays failed: later roots are told, nothing is re-imported, one log line", async () => {
  const fake = fakeFeature()
  const failure = new Error("404")
  const errors = []
  const consoleError = console.error
  const logged = []
  console.error = (...args) => logged.push(args)
  const roots = ["a", "b", "c"].map((id) => mountRoot({ id }))
  for (const root of roots) {
    root.addEventListener("reactive:error", (event) => errors.push([root.id, event.detail.phase, event.detail.error]))
  }

  try {
    const first = controllerFor(roots[0])
    first.connect()
    fake.reject(failure)
    await first.ready
    for (const root of roots.slice(1)) {
      const controller = controllerFor(root)
      controller.connect()
      await controller.ready
    }
  } finally {
    console.error = consoleError
  }

  expect(fake.loads()).toBe(1)
  expect(errors).toEqual([
    ["a", "load", failure],
    ["b", "load", failure],
    ["c", "load", failure],
  ])
  expect(roots.map((root) => root.getAttribute("data-reactive-error"))).toEqual(["feature", "feature", "feature"])
  expect(logged.length).toBe(1)
  expect(fake.log).toEqual([])
})

// needs() runs inside connect(), before the early drain. If it could abort
// connect() the root would be dead and its queued triggers lost.
test("a marker check that throws is reported, counts as not needed, and connect() still drains", async () => {
  const failure = new Error("bad marker")
  let loads = 0
  setFeature(
    "broken",
    () => {
      throw failure
    },
    () => {
      loads++
      return Promise.resolve({})
    },
  )
  const fake = fakeFeature()
  const root = mountRoot()
  const button = document.createElement("button")
  const token = "click->reactive#dispatch"
  button.setAttribute("data-action", token)
  root.appendChild(button)
  const early = (globalThis[Symbol.for("phlex-reactive.early")] ??= { queue: [], connected: new WeakSet() })
  early.queue.length = 0
  early.queue.push({
    event: new window.MouseEvent("click", { bubbles: true, cancelable: true }),
    el: button,
    root,
    descs: [{ token, type: "click", method: "dispatch", filter: "" }],
    at: performance.now(),
  })
  const errors = []
  root.addEventListener("reactive:error", (event) => errors.push(event.detail))
  const consoleError = console.error
  const logged = []
  console.error = (...args) => logged.push(args)
  const controller = controllerFor(root)
  const replayed = []
  controller.dispatch = (event) => replayed.push(event.type)

  try {
    expect(() => controller.connect()).not.toThrow()
    expect(replayed).toEqual(["click"])
    fake.resolve()
    await controller.ready
  } finally {
    console.error = consoleError
  }

  expect(errors).toEqual([{ kind: "feature", feature: "broken", phase: "detect", error: failure }])
  expect(logged).toEqual([['[phlex-reactive] the "broken" feature module could not tell whether a root needs it', failure]])
  expect(loads).toBe(0)
  // The root's other feature is unaffected.
  expect(fake.log).toEqual([["connect", controller]])
  expect(replayed).toEqual(["click"])
})

// Two features on one root, each behind its own hand-settled import.
function twoFeatures() {
  const log = []
  const settle = {}
  for (const name of ["first", "second"]) {
    setFeature(
      name,
      (root) => root.hasAttribute(MARKER),
      () =>
        new Promise((resolve, reject) => {
          settle[name] = {
            resolve: () =>
              resolve({
                connect: () => log.push(`connect ${name}`),
                disconnect: () => log.push(`disconnect ${name}`),
              }),
            reject,
          }
        }),
    )
  }
  return { log, settle }
}

test("features connect in registry order, whichever import lands first", async () => {
  const { log, settle } = twoFeatures()
  const controller = controllerFor(mountRoot())

  controller.connect()
  settle.second.resolve()
  await tick()
  expect(log).toEqual([])

  settle.first.resolve()
  await controller.ready
  expect(log).toEqual(["connect first", "connect second"])

  controller.disconnect()
  expect(log.slice(2)).toEqual(["disconnect first", "disconnect second"])
})

test("a feature whose disconnect throws does not stop the rest of disconnect()", async () => {
  const log = []
  const failure = new Error("teardown")
  setFeature(
    "first",
    (root) => root.hasAttribute(MARKER),
    () =>
      Promise.resolve({
        disconnect: () => {
          throw failure
        },
      }),
  )
  setFeature(
    "second",
    (root) => root.hasAttribute(MARKER),
    () => Promise.resolve({ disconnect: () => log.push("disconnect second") }),
  )
  const root = mountRoot()
  const controller = controllerFor(root)
  controller.connect()
  await controller.ready
  const early = globalThis[Symbol.for("phlex-reactive.early")]
  const consoleError = console.error
  const logged = []
  console.error = (...args) => logged.push(args)

  try {
    expect(() => controller.disconnect()).not.toThrow()

    expect(log).toEqual(["disconnect second"])
    expect(logged).toEqual([['[phlex-reactive] the "first" feature module failed to disconnect', failure]])
    // The rest of disconnect() ran: early.js queues this root's triggers again.
    expect(early.connected.has(root)).toBe(false)
    expect(root.hasAttribute("data-reactive-connected")).toBe(false)

    // No feature is disconnected a second time: neither the one that threw
    // (it would log again) nor the one that did not (it would push again).
    controller.disconnect()
    expect(logged.length).toBe(1)
    expect(log).toEqual(["disconnect second"])
  } finally {
    console.error = consoleError
  }
})

test("one feature failing to load does not keep the others from connecting", async () => {
  const { log, settle } = twoFeatures()
  const root = mountRoot()
  const errors = []
  root.addEventListener("reactive:error", (event) => errors.push(event.detail.feature))
  const consoleError = console.error
  console.error = () => {}
  const controller = controllerFor(root)

  try {
    controller.connect()
    settle.first.reject(new Error("404"))
    settle.second.resolve()
    await controller.ready
  } finally {
    console.error = consoleError
  }

  expect(errors).toEqual(["first"])
  expect(log).toEqual(["connect second"])
})

test("a failed import on a root that already left is not reported on it", async () => {
  const fake = fakeFeature()
  const root = mountRoot()
  const errors = []
  document.addEventListener("reactive:error", (event) => errors.push(event.detail))
  const controller = controllerFor(root)

  controller.connect()
  const ready = controller.ready
  controller.disconnect()
  fake.reject(new Error("gone"))
  await ready

  expect(errors).toEqual([])
  expect(root.hasAttribute("data-reactive-error")).toBe(false)
})

test("no production feature is registered yet (phase 1 moves no code)", async () => {
  const { reactiveFeatureNames } = await import("../../app/javascript/phlex/reactive/reactive_controller.js")

  expect(reactiveFeatureNames()).toEqual([])
})
