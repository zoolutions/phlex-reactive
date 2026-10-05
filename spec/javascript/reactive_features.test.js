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
//   featuresReady  a promise on the controller, resolved once this root's
//               features are loaded and connected. It never rejects.
//   failure     never a silent dead root: reactive:error { kind: "feature",
//               feature, phase, error } on every root it costs, with phase
//               "load" (the import failed), "connect" (the feature threw) or
//               "detect" (its marker check threw). A failed import STAYS
//               failed until the page is reloaded — a browser caches a module
//               that failed to load — and is logged once per page.
//
// Run with: bun test spec/javascript
import { test as anyTest, expect, mock, beforeAll, beforeEach, afterAll } from "bun:test"

// The opt-in entry's loader (issue #275). The shipped default entry has none
// (issue #305: built with __SPLIT__ false), so under
// `bun test --define __SPLIT__=false` there is nothing here to test.
const test = anyTest.skipIf(!__SPLIT__)
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
  // The opt-in entry: it tells the shared runtime where each feature module
  // lives. Without it a cold feature has no import to wait for.
  await import("../../app/javascript/phlex/reactive/core.js")
  ReactiveController = mod.default
  setFeature = mod.__setReactiveFeatureForTest
  resetFeatures = mod.__resetReactiveFeaturesForTest
})

beforeEach(() => {
  globalThis.document = window.document
  globalThis.CustomEvent = window.CustomEvent
  document.body.innerHTML = ""
  // Cold: no feature module loaded — the state of a page on the opt-in
  // phlex/reactive/core. (This file is imported through the default entry,
  // which hands every feature over up front; that path has its own section.)
  resetFeatures(true)
})

// bun runs every test file in one process: leave the shipped table behind,
// with the default entry's features loaded again — not this file's last fake
// (a "defer" whose import was made to fail).
afterAll(() => resetFeatures())

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

// The one console line a feature failure logs, per feature and phase.
const unavailable = (name, phase) =>
  `[phlex-reactive] the "${name}" feature module (phlex/reactive/features/${name}) is unavailable: ${phase}. ` +
  "If you bundle or vendor the client, alias or pin phlex/reactive/features/* (README: esbuild / webpack / bun)."

test("a root that needs no feature loads none and is ready at once", async () => {
  const fake = fakeFeature()
  const controller = controllerFor(mountRoot({ marked: false }))

  controller.connect()
  await controller.featuresReady

  expect(fake.loads()).toBe(0)
  expect(fake.log).toEqual([])
})

test("featuresReady is a resolved promise before connect() ever runs", async () => {
  const controller = controllerFor(mountRoot({ marked: false }))

  await expect(controller.featuresReady).resolves.toBeUndefined()
})

test("connect() starts the import a marked root needs and connects the feature when it resolves", async () => {
  const fake = fakeFeature()
  const controller = controllerFor(mountRoot())

  controller.connect()
  expect(fake.loads()).toBe(1)
  expect(fake.log).toEqual([])

  fake.resolve()
  await controller.featuresReady

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
  await controller.featuresReady
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
  await controller.featuresReady
  order.push(...namesOf(fake.log))

  expect(order).toEqual(["replayed click", "connect returned", "connect"])
  expect(early.queue).toEqual([])
})

test("featuresReady stays pending until the feature has connected", async () => {
  const fake = fakeFeature()
  const controller = controllerFor(mountRoot())
  let settled = false

  controller.connect()
  controller.featuresReady.then(() => (settled = true))
  await tick()
  expect(settled).toBe(false)

  fake.resolve()
  await controller.featuresReady
  expect(settled).toBe(true)
})

test("two roots that need one feature import it once", async () => {
  const fake = fakeFeature()
  const first = controllerFor(mountRoot({ id: "a" }))
  const second = controllerFor(mountRoot({ id: "b" }))

  first.connect()
  second.connect()
  fake.resolve()
  await Promise.all([first.featuresReady, second.featuresReady])

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
  await first.featuresReady

  const second = controllerFor(mountRoot({ id: "b" }))
  second.connect()
  await second.featuresReady

  expect(fake.loads()).toBe(1)
  expect(fake.log.at(-1)).toEqual(["connect", second])
})

test("a root that disconnects before the import resolves never connects the feature", async () => {
  const fake = fakeFeature()
  const controller = controllerFor(mountRoot())

  controller.connect()
  const ready = controller.featuresReady
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
  await controller.featuresReady

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
  await controller.featuresReady

  expect(fake.loads()).toBe(1)
  expect(fake.log).toEqual([["connect", controller]])
})

test("a failed import surfaces as reactive:error and marks the root; featuresReady still resolves", async () => {
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
    await controller.featuresReady
  } finally {
    console.error = consoleError
  }

  expect(errors).toEqual([{ kind: "feature", feature: "fake", phase: "load", error: failure }])
  expect(root.getAttribute("data-reactive-error")).toBe("feature")
  expect(logged).toEqual([[unavailable("fake", "load"), failure]])
  expect(fake.log).toEqual([])
})

test("a feature whose connect throws is reported as a connect failure; featuresReady still resolves", async () => {
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
    await controller.featuresReady
  } finally {
    console.error = consoleError
  }

  expect(errors).toEqual([{ kind: "feature", feature: "fake", phase: "connect", error: failure }])
  expect(logged).toEqual([[unavailable("fake", "connect"), failure]])
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
    await first.featuresReady
    for (const root of roots.slice(1)) {
      const controller = controllerFor(root)
      controller.connect()
      await controller.featuresReady
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
    await controller.featuresReady
  } finally {
    console.error = consoleError
  }

  expect(errors).toEqual([{ kind: "feature", feature: "broken", phase: "detect", error: failure }])
  expect(logged).toEqual([[unavailable("broken", "detect"), failure]])
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
  await controller.featuresReady
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
  await controller.featuresReady
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
    await controller.featuresReady
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
  const ready = controller.featuresReady
  controller.disconnect()
  fake.reject(new Error("gone"))
  await ready

  expect(errors).toEqual([])
  expect(root.hasAttribute("data-reactive-error")).toBe(false)
})

test("the shipped table lists the moved features, persist first", async () => {
  const { reactiveFeatureNames } = await import("../../app/javascript/phlex/reactive/reactive_controller.js")

  // Table order is connect order: the draft restore writes the values every
  // other connect-time seed reads, so persist stays first as features move.
  expect(reactiveFeatureNames()).toEqual(["persist", "defer", "form", "bindings", "compute", "effects", "hints", "devtools"])
})

// --- The core handle ----------------------------------------------------------

test("a feature receives the core handle on connect and on disconnect", async () => {
  const seen = []
  setFeature(
    "fake",
    (root) => root.hasAttribute(MARKER),
    () =>
      Promise.resolve({
        connect: (controller, core) => seen.push(["connect", controller, core]),
        disconnect: (controller, core) => seen.push(["disconnect", controller, core]),
      }),
  )
  const root = mountRoot()
  const events = []
  root.addEventListener("fake:ping", (event) => events.push(event.detail))
  const controller = controllerFor(root)

  controller.connect()
  await controller.featuresReady
  const core = seen[0][2]
  core.emit("fake:ping", { n: 1 })
  controller.disconnect()

  expect(Object.keys(core).sort()).toEqual([
    "applyOps",
    "collectFields",
    "confirm",
    "diagnose",
    "emit",
    "forgetToken",
    "listnavOptions",
    "opTargets",
    "ownership",
    "owns",
    "proceed",
    "reseed",
  ])
  expect(events).toEqual([{ n: 1 }])
  expect(() => core.reseed()).not.toThrow()
  expect(seen.map(([name, who, handle]) => [name, who === controller, handle === core])).toEqual([
    ["connect", true, true],
    ["disconnect", true, true],
  ])
})

// --- Disconnect order ---------------------------------------------------------

// The draft flush reads the root's fields and must run while the root is
// still whole: features disconnect BEFORE any of the controller's own teardown.
test("features disconnect first, before any of the controller's own teardown", async () => {
  const early = (globalThis[Symbol.for("phlex-reactive.early")] ??= { queue: [], connected: new WeakSet() })
  const order = []
  for (const name of ["first", "second"]) {
    setFeature(
      name,
      (root) => root.hasAttribute(MARKER),
      () =>
        Promise.resolve({
          disconnect: (controller) =>
            order.push([name, early.connected.has(controller.element), controller.element.hasAttribute("data-reactive-connected")]),
        }),
    )
  }
  const root = mountRoot()
  // A token-bearing root wires a morph listener at connect; the controller's
  // own teardown removes it — the first thing that teardown can be seen doing.
  root.setAttribute("data-reactive-token-value", "tok")
  const controller = controllerFor(root)
  controller.connect()
  await controller.featuresReady
  const remove = root.removeEventListener.bind(root)
  root.removeEventListener = (...args) => {
    order.push("core teardown")
    return remove(...args)
  }

  controller.disconnect()

  expect(order.slice(0, 3)).toEqual([["first", true, true], ["second", true, true], "core teardown"])
})

// --- A slow or hung import ------------------------------------------------------

function setFeatureTimeout(ms) {
  document.head.innerHTML = `<meta name="phlex-reactive-feature-timeout" content="${ms}">`
}
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

test("an import that never settles is given up on: reported, and the root's other features connect", async () => {
  setFeatureTimeout(20)
  const { log, settle } = twoFeatures()
  const root = mountRoot()
  const errors = []
  root.addEventListener("reactive:error", (event) => errors.push([event.detail.feature, event.detail.phase]))
  const consoleError = console.error
  const logged = []
  console.error = (...args) => logged.push(String(args[0]))
  const controller = controllerFor(root)

  try {
    controller.connect()
    settle.second.resolve()
    await controller.featuresReady
  } finally {
    console.error = consoleError
    document.head.innerHTML = ""
  }

  expect(errors).toEqual([["first", "timeout"]])
  expect(logged).toEqual([unavailable("first", "timeout")])
  expect(log).toEqual(["connect second"])
  expect(root.getAttribute("data-reactive-error")).toBe("feature")
})

test("a feature that arrives after its timeout still connects", async () => {
  setFeatureTimeout(20)
  const { log, settle } = twoFeatures()
  const controller = controllerFor(mountRoot())
  const consoleError = console.error
  console.error = () => {}

  try {
    controller.connect()
    settle.second.resolve()
    await controller.featuresReady
    settle.first.resolve()
    await sleep(0)
  } finally {
    console.error = consoleError
    document.head.innerHTML = ""
  }

  expect(log).toEqual(["connect second", "connect first"])
  controller.disconnect()
  expect(log.slice(2)).toEqual(["disconnect second", "disconnect first"])
})

// The persist stand-in reacts to a submit by queueing forget() on the import.
// A late module must not restore the draft BEFORE that reaction has run.
test("a late feature connects after the reactions already queued on its import", async () => {
  setFeatureTimeout(20)
  const order = []
  let arrive
  let loading
  setFeature(
    "fake",
    (root) => root.hasAttribute(MARKER),
    () => (loading = new Promise((resolve) => (arrive = () => resolve({ connect: () => order.push("connect") })))),
  )
  const controller = controllerFor(mountRoot())
  const consoleError = console.error
  console.error = () => {}

  try {
    controller.connect()
    await controller.featuresReady // timed out: the root carried on
    loading.then(() => order.push("reaction queued while waiting"))
    arrive()
    await sleep(0)
  } finally {
    console.error = consoleError
    document.head.innerHTML = ""
  }

  expect(order).toEqual(["reaction queued while waiting", "connect"])
})

test("a late feature does not connect on a root that has disconnected", async () => {
  setFeatureTimeout(20)
  const { log, settle } = twoFeatures()
  const controller = controllerFor(mountRoot())
  const consoleError = console.error
  console.error = () => {}

  try {
    controller.connect()
    settle.second.resolve()
    await controller.featuresReady
    controller.disconnect()
    settle.first.resolve()
    await sleep(0)
  } finally {
    console.error = consoleError
    document.head.innerHTML = ""
  }

  expect(log).toEqual(["connect second", "disconnect second"])
})

test("the timeout meta is read from <head> only and ignores junk", async () => {
  document.head.innerHTML = `<meta name="phlex-reactive-feature-timeout" content="soon">`
  const body = document.createElement("meta")
  body.setAttribute("name", "phlex-reactive-feature-timeout")
  body.setAttribute("content", "1")
  document.body.appendChild(body)
  const fake = fakeFeature()
  const root = mountRoot()
  const errors = []
  root.addEventListener("reactive:error", (event) => errors.push(event.detail.phase))
  const controller = controllerFor(root)

  try {
    controller.connect()
    await sleep(30)
    // Neither the body's 1 ms nor the junk value applied: still waiting.
    expect(errors).toEqual([])
    fake.resolve()
    await controller.featuresReady
  } finally {
    document.head.innerHTML = ""
  }

  expect(fake.log).toEqual([["connect", controller]])
})

test("disconnect clears the pending import timeout", async () => {
  setFeatureTimeout(20)
  const fake = fakeFeature()
  const root = mountRoot()
  const errors = []
  document.addEventListener("reactive:error", (event) => errors.push(event.detail.phase))
  const controller = controllerFor(root)

  try {
    controller.connect()
    controller.disconnect()
    await sleep(40)
  } finally {
    document.head.innerHTML = ""
  }

  expect(errors).toEqual([])
  expect(fake.loads()).toBe(1)
})

// --- A marker that arrives by morph ---------------------------------------------

function morph(root) {
  root.dispatchEvent(new window.CustomEvent("turbo:morph-element", { bubbles: true }))
}

test("a morph that adds a feature's marker to a connected root loads the feature", async () => {
  const fake = fakeFeature()
  const root = mountRoot({ marked: false })
  root.setAttribute("data-reactive-token-value", "tok")
  const controller = controllerFor(root)
  controller.connect()
  await controller.featuresReady
  expect(fake.loads()).toBe(0)

  root.setAttribute(MARKER, "")
  morph(root)
  expect(fake.loads()).toBe(1)
  fake.resolve()
  await controller.featuresReady

  expect(fake.log).toEqual([["connect", controller]])
})

test("a later morph does not load or connect a feature the root already has", async () => {
  const fake = fakeFeature()
  const root = mountRoot()
  root.setAttribute("data-reactive-token-value", "tok")
  const controller = controllerFor(root)
  controller.connect()
  fake.resolve()
  await controller.featuresReady

  morph(root)
  morph(root)
  await controller.featuresReady

  expect(fake.loads()).toBe(1)
  expect(fake.log).toEqual([["connect", controller]])
})

test("a morph of a descendant does not re-scan the root", async () => {
  const fake = fakeFeature()
  const root = mountRoot({ marked: false })
  root.setAttribute("data-reactive-token-value", "tok")
  const child = document.createElement("p")
  root.appendChild(child)
  const controller = controllerFor(root)
  controller.connect()

  root.setAttribute(MARKER, "")
  morph(child)

  expect(fake.loads()).toBe(0)
})

// --- Requests wait for a feature that is still loading (D1) ----------------------
//
// A feature may be about to change what a request reads (the draft restore
// writes the fields the request collects). So the core does its synchronous
// part at once — preventDefault, the guards, the queue — and the request
// itself waits for the root's features. This is the mechanism with a FAKE
// feature; spec/javascript/reactive_persist.test.js and
// spec/system/persist_feature_spec.rb exercise it with the real persist module.

function requestRig() {
  const posts = []
  globalThis.window = window
  window.Turbo = { renderStreamMessage: () => {} }
  globalThis.fetch = (_url, options) => {
    posts.push(JSON.parse(options.body))
    return Promise.resolve({
      redirected: false,
      ok: true,
      status: 200,
      headers: { get: () => "text/vnd.turbo-stream.html" },
      text: () => Promise.resolve(""),
    })
  }
  return posts
}

function triggerEvent(act, extra = {}) {
  let prevented = false
  return {
    params: { action: act, params: "{}", ...extra },
    preventDefault: () => (prevented = true),
    wasPrevented: () => prevented,
  }
}

// A marked root with one text field, whose fake feature fills the field in
// when it connects — as the draft restore does. `gates` is the feature's own
// say on whether a request must wait for it (the fourth table element).
function fieldRoot({ gates = true } = {}) {
  const root = mountRoot()
  root.setAttribute("data-reactive-token-value", "tok")
  const input = document.createElement("input")
  input.name = "note"
  root.appendChild(input)
  const pending = []
  setFeature(
    "fake",
    (el) => el.hasAttribute(MARKER),
    () => new Promise((resolve) => pending.push(() => resolve({ connect: () => (input.value = "restored") }))),
    undefined,
    gates,
  )
  const controller = controllerFor(root)
  controller.tokenValue = "tok"
  return { root, controller, arrive: () => pending.shift()() }
}

test("a live dispatch during the import is prevented at once and posts after the feature connected", async () => {
  const posts = requestRig()
  const { controller, arrive } = fieldRoot()
  controller.connect()

  const event = triggerEvent("save")
  const done = controller.dispatch(event)
  expect(event.wasPrevented()).toBe(true)
  await sleep(0)
  expect(posts).toEqual([])

  arrive()
  await done
  await controller.queue

  expect(posts.map((post) => [post.act, post.params.note])).toEqual([["save", "restored"]])
})

test("a replayed early trigger posts once, after the feature connected, with what the feature wrote", async () => {
  const posts = requestRig()
  const { root, controller, arrive } = fieldRoot()
  const button = document.createElement("button")
  const token = "click->reactive#dispatch"
  button.setAttribute("data-action", token)
  button.setAttribute("data-reactive-action-param", "save")
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

  controller.connect()
  await sleep(0)
  // Replayed inside connect() — it is in the queue — but not sent yet.
  expect(early.queue).toEqual([])
  expect(posts).toEqual([])

  arrive()
  await controller.featuresReady
  await controller.queue

  expect(posts.map((post) => [post.act, post.params.note])).toEqual([["save", "restored"]])
})

test("events during the import keep their order: the replayed one, then the live ones", async () => {
  const posts = requestRig()
  const { root, controller, arrive } = fieldRoot()
  const button = document.createElement("button")
  const token = "click->reactive#dispatch"
  button.setAttribute("data-action", token)
  button.setAttribute("data-reactive-action-param", "first")
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

  controller.connect()
  controller.dispatch(triggerEvent("second"))
  controller.dispatch(triggerEvent("third"))
  await sleep(0)
  expect(posts).toEqual([])

  arrive()
  await controller.featuresReady
  await controller.queue

  expect(posts.map((post) => post.act)).toEqual(["first", "second", "third"])
})

test("a request waits no longer than the feature timeout for a hung import", async () => {
  setFeatureTimeout(20)
  const posts = requestRig()
  const { controller } = fieldRoot()
  const consoleError = console.error
  console.error = () => {}

  try {
    controller.connect()
    await controller.dispatch(triggerEvent("save"))
    await controller.queue
  } finally {
    console.error = consoleError
    document.head.innerHTML = ""
  }

  expect(posts.map((post) => [post.act, post.params.note])).toEqual([["save", ""]])
})

test("a request queued behind a hung import is released when the root disconnects", async () => {
  const posts = requestRig()
  const { controller } = fieldRoot()
  controller.connect()
  const done = controller.dispatch(triggerEvent("save"))
  await sleep(0)
  expect(posts).toEqual([])

  // The import never settles and the 10 s timeout is far away: only the
  // disconnect can release what is waiting on it.
  controller.disconnect()
  await done
  await controller.queue

  expect(posts.map((post) => post.act)).toEqual(["save"])
})

test("after such a disconnect the same controller reconnects and posts again", async () => {
  const posts = requestRig()
  const { controller, arrive } = fieldRoot()
  controller.connect()
  controller.dispatch(triggerEvent("first"))
  controller.disconnect()

  controller.connect()
  arrive()
  await controller.featuresReady
  await controller.dispatch(triggerEvent("second"))
  await controller.queue

  expect(posts.map((post) => post.act)).toEqual(["first", "second"])
})

// --- A feature's "while loading" hook ---------------------------------------------

test("a feature's waiting hook runs while its import is pending and is undone when it connects", async () => {
  const log = []
  let arrive
  setFeature(
    "fake",
    (root) => root.hasAttribute(MARKER),
    () =>
      new Promise(
        (resolve) =>
          (arrive = () => resolve({ connect: (_controller, _core, _morphed, pending) => log.push(["connect", pending]) })),
      ),
    (root, pending) => {
      log.push(`waiting ${root.id}`)
      pending.seen = "an edit"
      return () => log.push("stopped waiting")
    },
  )
  const controller = controllerFor(mountRoot())

  controller.connect()
  expect(log).toEqual(["waiting root"])
  arrive()
  await controller.featuresReady

  // The hook is undone, then the feature connects and is handed what it recorded.
  expect(log).toEqual(["waiting root", "stopped waiting", ["connect", { seen: "an edit" }]])
})

test("a root that leaves before the feature arrives is handed to abandon() with what the hook recorded", async () => {
  const log = []
  let arrive
  setFeature(
    "fake",
    (root) => root.hasAttribute(MARKER),
    () =>
      new Promise(
        (resolve) =>
          (arrive = () =>
            resolve({
              connect: () => log.push("connect"),
              abandon: (root, pending) => log.push(["abandon", root.id, pending]),
            })),
      ),
    (_root, pending) => {
      pending.seen = "an edit"
      return () => log.push("stopped waiting")
    },
  )
  const controller = controllerFor(mountRoot())

  controller.connect()
  controller.disconnect()
  expect(log).toEqual(["stopped waiting"])
  arrive()
  await sleep(0)

  expect(log).toEqual(["stopped waiting", ["abandon", "root", { seen: "an edit" }]])
})

test("a feature without a waiting hook is not asked to abandon anything", async () => {
  const log = []
  let arrive
  setFeature(
    "fake",
    (root) => root.hasAttribute(MARKER),
    () => new Promise((resolve) => (arrive = () => resolve({ abandon: () => log.push("abandon") }))),
  )
  const controller = controllerFor(mountRoot())

  controller.connect()
  controller.disconnect()
  arrive()
  await sleep(0)

  expect(log).toEqual([])
})

test("the waiting hook is undone when the root disconnects before the feature arrives", async () => {
  const log = []
  setFeature(
    "fake",
    (root) => root.hasAttribute(MARKER),
    () => new Promise(() => {}),
    () => {
      log.push("waiting")
      return () => log.push("stopped waiting")
    },
  )
  const controller = controllerFor(mountRoot())

  controller.connect()
  controller.disconnect()
  controller.disconnect()

  expect(log).toEqual(["waiting", "stopped waiting"])
})

test("a waiting hook that throws is reported and does not stop connect()", async () => {
  const failure = new Error("hook")
  const fake = { log: [] }
  let arrive
  setFeature(
    "fake",
    (root) => root.hasAttribute(MARKER),
    () => new Promise((resolve) => (arrive = () => resolve({ connect: () => fake.log.push("connect") }))),
    () => {
      throw failure
    },
  )
  const root = mountRoot()
  const errors = []
  root.addEventListener("reactive:error", (event) => errors.push([event.detail.phase, event.detail.error]))
  const consoleError = console.error
  console.error = () => {}
  const controller = controllerFor(root)

  try {
    expect(() => controller.connect()).not.toThrow()
    arrive()
    await controller.featuresReady
  } finally {
    console.error = consoleError
  }

  expect(errors).toEqual([["detect", failure]])
  expect(fake.log).toEqual(["connect"])
})

test("once the features have connected a dispatch does not wait on them again", async () => {
  const posts = requestRig()
  const { controller, arrive } = fieldRoot()
  controller.connect()
  arrive()
  await controller.featuresReady
  // A promise that never settles: a dispatch that awaited it would hang.
  controller.featuresReady = new Promise(() => {})

  await controller.dispatch(triggerEvent("save"))
  await controller.queue

  expect(posts.map((post) => post.act)).toEqual(["save"])
})

test("a root with no feature posts in the same turn it always did", async () => {
  const posts = requestRig()
  const root = mountRoot({ marked: false })
  root.setAttribute("data-reactive-token-value", "tok")
  const controller = controllerFor(root)
  controller.tokenValue = "tok"
  controller.connect()
  controller.featuresReady = new Promise(() => {})

  await controller.dispatch(triggerEvent("save"))
  await controller.queue

  expect(posts.map((post) => post.act)).toEqual(["save"])
})

// --- Table order, without waiting for later features --------------------------------

test("a feature connects when ITS import arrives: a slower feature later in the table does not hold it back", async () => {
  const { log, settle } = twoFeatures()
  const controller = controllerFor(mountRoot())
  controller.connect()

  settle.first.resolve()
  await sleep(0)
  expect(log).toEqual(["connect first"])

  settle.second.resolve()
  await controller.featuresReady
  expect(log).toEqual(["connect first", "connect second"])
})

// --- A module that is already loaded -----------------------------------------------

test("once its module is loaded a feature connects INSIDE connect(), before the early drain", async () => {
  const fake = fakeFeature()
  const first = controllerFor(mountRoot({ id: "a" }))
  first.connect()
  fake.resolve()
  await first.featuresReady

  const root = mountRoot({ id: "b" })
  const order = []
  root.addEventListener("reactive:connect", () => order.push(`reactive:connect, feature connected: ${fake.log.length === 2}`))
  const second = controllerFor(root)
  const readyBefore = second.featuresReady
  second.connect()
  order.push("connect returned")

  expect(order).toEqual(["reactive:connect, feature connected: true", "connect returned"])
  // Nothing to wait for: no new promise, and (below) no request is held back.
  expect(second.featuresReady).toBe(readyBefore)
})

test("a root whose gating feature is already loaded posts without waiting", async () => {
  const posts = requestRig()
  const warm = fieldRoot()
  warm.controller.connect()
  warm.arrive()
  await warm.controller.featuresReady
  warm.controller.disconnect()

  warm.controller.connect()
  warm.controller.featuresReady = new Promise(() => {})
  await warm.controller.dispatch(triggerEvent("save"))
  await warm.controller.queue

  expect(posts.map((post) => [post.act, post.params.note])).toEqual([["save", "restored"]])
})

// --- Only a feature that `gates` holds a request back ---------------------------------

test("a feature that does not gate never delays a request, however slow its import", async () => {
  const posts = requestRig()
  const { controller } = fieldRoot({ gates: false })
  controller.connect()

  await controller.dispatch(triggerEvent("save"))
  await controller.queue

  // Sent while the import is still pending — with the field as it was.
  expect(posts.map((post) => [post.act, post.params.note])).toEqual([["save", ""]])
})

test("requests wait for the gating feature only, not for a slower one after it", async () => {
  const posts = requestRig()
  const root = mountRoot()
  root.setAttribute("data-reactive-token-value", "tok")
  const log = []
  let arriveGating
  setFeature("gating", (el) => el.hasAttribute(MARKER), () => new Promise((resolve) => (arriveGating = () => resolve({ connect: () => log.push("gating") }))), undefined, true)
  setFeature("slow", (el) => el.hasAttribute(MARKER), () => new Promise(() => {}))
  const controller = controllerFor(root)
  controller.tokenValue = "tok"
  controller.connect()

  const done = controller.dispatch(triggerEvent("save"))
  await sleep(0)
  expect(posts).toEqual([])
  arriveGating()
  await done
  await controller.queue

  expect(log).toEqual(["gating"])
  expect(posts.map((post) => post.act)).toEqual(["save"])
})

test("a gating feature added by a morph is not held back by a later feature that is still loading", async () => {
  const posts = requestRig()
  const root = mountRoot({ marked: false })
  root.setAttribute("data-reactive-token-value", "tok")
  root.setAttribute("data-later", "")
  const log = []
  let arriveGating
  // Table order: "gating" first, "later" second — as persist precedes defer.
  setFeature("gating", (el) => el.hasAttribute(MARKER), () => new Promise((resolve) => (arriveGating = () => resolve({ connect: () => log.push("gating") }))), undefined, true)
  setFeature("later", (el) => el.hasAttribute("data-later"), () => new Promise(() => {}))
  const controller = controllerFor(root)
  controller.tokenValue = "tok"
  controller.connect() // "later" starts loading, and never arrives

  root.setAttribute(MARKER, "")
  morph(root) // "gating" starts loading
  const done = controller.dispatch(triggerEvent("save"))
  arriveGating()
  await done
  await controller.queue

  expect(log).toEqual(["gating"])
  expect(posts.map((post) => post.act)).toEqual(["save"])
})

// --- A morph re-scan tells the feature it follows a morph ---------------------------------

test("a feature connected by a morph re-scan is told so; one connected at connect() is not", async () => {
  const seen = []
  setFeature(
    "fake",
    (root) => root.hasAttribute(MARKER),
    () => Promise.resolve({ connect: (_controller, _core, morphed) => seen.push(Boolean(morphed)) }),
  )
  const atConnect = controllerFor(mountRoot({ id: "a" }))
  atConnect.connect()
  await atConnect.featuresReady

  const root = mountRoot({ marked: false, id: "b" })
  root.setAttribute("data-reactive-token-value", "tok")
  const later = controllerFor(root)
  later.connect()
  root.setAttribute(MARKER, "")
  morph(root)
  await later.featuresReady

  expect(seen).toEqual([false, true])
})

// --- The reactive:defer stream action and the __materialize trigger -------------------
//
// Both belong to the defer feature and both can reach the core before the
// feature has loaded: a reply.defer stream on a page with no lazy root, an
// on: trigger fired (or replayed) while the import is still on its way.

function stubTurboActions() {
  globalThis.window = window
  window.Turbo = { StreamActions: {}, renderStreamMessage: () => {} }
  return window.Turbo.StreamActions
}

// A stand-in "defer" module behind an import the test settles by hand.
function fakeDefer() {
  const log = []
  let arrive
  const feature = {
    streamAction: (el) => log.push(["stream", el.getAttribute("target")]),
    materialize: (controller) => {
      log.push(["materialize", controller.element.id])
      return Promise.resolve()
    },
  }
  setFeature(
    "defer",
    (root) => root.hasAttribute("data-reactive-lazy-on"),
    () => new Promise((resolve, reject) => (arrive = { resolve: () => resolve(feature), reject })),
  )
  return { log, arrive: () => arrive.resolve(), fail: (error) => arrive.reject(error) }
}

const streamEl = (target) => ({ getAttribute: (name) => (name === "target" ? target : null) })

test("a reactive:defer stream that arrives before the feature has loaded is kept and applied when it has", async () => {
  const { registerReactiveDefer } = await import("../../app/javascript/phlex/reactive/reactive_controller.js")
  const actions = stubTurboActions()
  const defer = fakeDefer()
  registerReactiveDefer()

  actions["reactive:defer"].call(streamEl("totals"))
  actions["reactive:defer"].call(streamEl("stats"))
  expect(defer.log).toEqual([])

  defer.arrive()
  await sleep(0)
  expect(defer.log).toEqual([
    ["stream", "totals"],
    ["stream", "stats"],
  ])
})

test("once the feature is loaded a reactive:defer stream is applied in the same tick", async () => {
  const { registerReactiveDefer } = await import("../../app/javascript/phlex/reactive/reactive_controller.js")
  const actions = stubTurboActions()
  const defer = fakeDefer()
  registerReactiveDefer()
  actions["reactive:defer"].call(streamEl("first"))
  defer.arrive()
  await sleep(0)

  actions["reactive:defer"].call(streamEl("second"))

  expect(defer.log.at(-1)).toEqual(["stream", "second"])
})

function lazyOnRoot() {
  const root = mountRoot({ marked: false, id: "panel" })
  root.setAttribute("data-reactive-token-value", "tok")
  root.setAttribute("data-reactive-lazy-on", "panel:opened")
  const controller = controllerFor(root)
  controller.tokenValue = "tok"
  return { root, controller }
}

test("a __materialize trigger during the import is prevented at once and materializes once the feature connected", async () => {
  requestRig()
  const defer = fakeDefer()
  const { controller } = lazyOnRoot()
  controller.connect()

  const event = triggerEvent("__materialize")
  const done = controller.dispatch(event)
  expect(event.wasPrevented()).toBe(true)
  await sleep(0)
  expect(defer.log).toEqual([])

  defer.arrive()
  await done

  expect(defer.log).toEqual([["materialize", "panel"]])
})

test("a __materialize trigger on a connected feature goes straight to it", async () => {
  requestRig()
  const defer = fakeDefer()
  const { controller } = lazyOnRoot()
  controller.connect()
  defer.arrive()
  await controller.featuresReady

  controller.dispatch(triggerEvent("__materialize"))

  expect(defer.log).toEqual([["materialize", "panel"]])
})

test("when the defer feature cannot load, a __materialize trigger still posts the plain action", async () => {
  const posts = requestRig()
  const defer = fakeDefer()
  const { controller } = lazyOnRoot()
  const consoleError = console.error
  console.error = () => {}

  try {
    controller.connect()
    const done = controller.dispatch(triggerEvent("__materialize"))
    defer.fail(new Error("404"))
    await done
    await controller.queue
  } finally {
    console.error = consoleError
  }

  expect(defer.log).toEqual([])
  expect(posts.map((post) => post.act)).toEqual(["__materialize"])
})

// Issue #306: a reactive_lazy(on:, cache:) shell carries no identity token —
// its fragment URL is the only way it loads. When the defer feature cannot
// load, the trigger has nothing to POST: the feature's reactive:error is the
// signal (the app's empty state handles it), and no __materialize goes out.
test("when the defer feature cannot load, a tokenless cache: shell's trigger posts nothing; reactive:error says why", async () => {
  const posts = requestRig()
  const defer = fakeDefer()
  const root = mountRoot({ marked: false, id: "panel" })
  root.setAttribute("data-reactive-lazy-on", "panel:opened")
  root.setAttribute("data-reactive-defer-src", "/reactive/fragment/abc")
  const controller = controllerFor(root)
  const errors = []
  root.addEventListener("reactive:error", (event) => errors.push([event.detail.kind, event.detail.feature]))
  const consoleError = console.error
  console.error = () => {}

  try {
    controller.connect()
    const done = controller.dispatch(triggerEvent("__materialize"))
    defer.fail(new Error("404"))
    await done
    await controller.queue
  } finally {
    console.error = consoleError
  }

  expect(defer.log).toEqual([])
  expect(posts).toEqual([])
  expect(errors).toEqual([["feature", "defer"]])
})

test("a lazy shell whose defer module cannot load stops claiming to be pending", async () => {
  requestRig()
  const defer = fakeDefer()
  const { root, controller } = lazyOnRoot()
  root.setAttribute("data-reactive-defer-pending", "true")
  root.setAttribute("aria-busy", "true")
  const errors = []
  root.addEventListener("reactive:error", (event) => errors.push([event.detail.feature, event.detail.phase]))
  const consoleError = console.error
  console.error = () => {}

  try {
    controller.connect()
    defer.fail(new Error("404"))
    await controller.featuresReady
  } finally {
    console.error = consoleError
  }

  // Nothing is coming: the shimmer must not lie. The root is marked failed,
  // and only a reload can bring the module back.
  expect(errors).toEqual([["defer", "load"]])
  expect(root.hasAttribute("data-reactive-defer-pending")).toBe(false)
  expect(root.hasAttribute("aria-busy")).toBe(false)
  expect(root.getAttribute("data-reactive-error")).toBe("feature")
})

test("a slow defer module leaves the pending marker alone: it may still arrive", async () => {
  setFeatureTimeout(20)
  requestRig()
  fakeDefer()
  const { root, controller } = lazyOnRoot()
  root.setAttribute("data-reactive-defer-pending", "true")
  const consoleError = console.error
  console.error = () => {}

  try {
    controller.connect()
    await controller.featuresReady
  } finally {
    console.error = consoleError
    document.head.innerHTML = ""
  }

  expect(root.getAttribute("data-reactive-defer-pending")).toBe("true")
})
