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
//   failure     a failed import emits reactive:error { kind: "feature" } and
//               marks the root — never a silent dead root — and is retried by
//               the next root that needs the feature.
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

  expect(errors).toEqual([{ kind: "feature", feature: "fake", error: failure }])
  expect(root.getAttribute("data-reactive-error")).toBe("feature")
  expect(logged.length).toBe(1)
  expect(String(logged[0][0])).toContain('"fake"')
  expect(fake.log).toEqual([])
})

test("a feature whose connect throws is reported the same way; ready still resolves", async () => {
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
  console.error = () => {}
  const controller = controllerFor(root)

  try {
    controller.connect()
    await controller.ready
  } finally {
    console.error = consoleError
  }

  expect(errors).toEqual([{ kind: "feature", feature: "fake", error: failure }])
  expect(() => controller.disconnect()).not.toThrow()
})

test("a failed import is retried by the next root that needs the feature", async () => {
  const fake = fakeFeature()
  const consoleError = console.error
  console.error = () => {}
  try {
    const first = controllerFor(mountRoot({ id: "a" }))
    first.connect()
    fake.reject(new Error("offline"))
    await first.ready
  } finally {
    console.error = consoleError
  }

  const second = controllerFor(mountRoot({ id: "b" }))
  second.connect()
  fake.resolve()
  await second.ready

  expect(fake.loads()).toBe(2)
  expect(fake.log).toEqual([["connect", second]])
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
