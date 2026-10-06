// Unit tests for the feature modules of issue #275, phase 4 — effects (with
// dismissing flashes), form (dirty tracking, the unsaved guard, the paste
// gate) and dev (the latency simulator) — on the OPT-IN split client, where
// a module may not be loaded when it is first needed.
//
// What each must not lose in that window:
//
//   effects   a stream that introduces the page's first effect or dismissing
//             flash still gets it: its render waits for the module — and so
//             does every stream behind it, so two streams to one target keep
//             their order. The wait is bounded (1 s); then streams render
//             plain and a module that arrives later sweeps up the flashes.
//   form      an edit made before the module arrived is counted when it
//             connects (it scans the whole root).
//   dev       a request made while a delay is stored is delayed, even the
//             first one (it waits for the module).
//
// The default entry (every module handed over up front) is covered by each
// feature's own test file; a section at the end checks the per-root cost
// rule: a loaded feature with nothing to do per root has no marker read.
//
// Run with: bun test spec/javascript
import { test as anyTest, expect, mock, beforeAll, beforeEach, afterEach, afterAll, describe as anyDescribe } from "bun:test"

// The opt-in entry's loader (issue #275). The shipped default entry has none
// (issue #305: built with __SPLIT__ false), so under
// `bun test --define __SPLIT__=false` there is nothing here to test.
const test = anyTest.skipIf(!__SPLIT__)
const describe = anyDescribe.skipIf(!__SPLIT__)
import { Window } from "happy-dom"

const window = new Window()
let mod
let ReactiveController
let setFeature
let resetFeatures
let effectsModule
let formModule
let devModule
let resetStreamHold

const SOURCE = "../../app/javascript/phlex/reactive"

beforeAll(async () => {
  globalThis.document = window.document
  globalThis.CustomEvent = window.CustomEvent
  mock.module("@hotwired/stimulus", () => ({ Controller: class {} }))
  mod = await import(`${SOURCE}/reactive_controller.js`)
  // The opt-in entry: it tells the shared runtime where each feature module lives.
  ;({ __resetReactiveStreamHoldForTest: resetStreamHold } = await import(`${SOURCE}/core.js`))
  ReactiveController = mod.default
  setFeature = mod.__setReactiveFeatureForTest
  resetFeatures = mod.__resetReactiveFeaturesForTest
  effectsModule = await import(`${SOURCE}/features/effects.js`)
  formModule = await import(`${SOURCE}/features/form.js`)
  devModule = await import(`${SOURCE}/features/devtools.js`)
  // One stream-render listener on THIS file's document: registered once here
  // (a registration per test would stack listeners), after clearing the
  // runtime's guard (another file registered on its own document).
  mod.__resetReactiveStreamRenderForTest()
  mod.registerReactiveStreamRender()
})

const realSetTimeout = globalThis.setTimeout
const realConsole = globalThis.console
const ORIGINALS = {
  sessionStorage: globalThis.sessionStorage,
  window: globalThis.window,
  fetch: globalThis.fetch,
  navigator: globalThis.navigator,
}
let timers
let errors
let warns

// Captured timers: a test advances virtual time with runTimers(ms).
function installFakeTimers() {
  timers = []
  globalThis.setTimeout = (fn, ms) => {
    timers.push({ fn, ms })
    return timers.length
  }
}
function runTimers(uptoMs) {
  const due = timers.filter((timer) => timer.ms <= uptoMs)
  timers = timers.filter((timer) => timer.ms > uptoMs)
  for (const timer of due) timer.fn()
}

const settle = () => new Promise((resolve) => realSetTimeout(resolve, 0))

beforeEach(() => {
  globalThis.document = window.document
  globalThis.CustomEvent = window.CustomEvent
  globalThis.Event = window.Event
  document.head.innerHTML = ""
  document.body.innerHTML = ""
  globalThis.getComputedStyle = (el) => ({
    animationDuration: el.getAttribute?.("data-test-duration") ?? "0s",
    animationDelay: "0s",
    transitionDuration: "0s",
    transitionDelay: "0s",
  })
  globalThis.matchMedia = () => ({ matches: false })
  errors = []
  warns = []
  globalThis.console = { ...realConsole, error: (...args) => errors.push(args.join(" ")), warn: (...args) => warns.push(args.join(" ")) }
  // Cold: the state of a page that imported phlex/reactive/core.
  resetFeatures(true)
  resetStreamHold()
})

afterEach(() => {
  globalThis.setTimeout = realSetTimeout
  globalThis.console = realConsole
  for (const [name, value] of Object.entries(ORIGINALS)) {
    if (value === undefined) delete globalThis[name]
    else globalThis[name] = value
  }
})

afterAll(() => {
  resetFeatures()
  mod.__resetReactiveStreamRenderForTest()
})

// Put a feature behind an import the test settles by hand; `needs` as shipped
// unless given.
function slowFeature(name, module, needs) {
  let arrive
  let fail
  let loads = 0
  const shipped = mod.__reactiveFeatureEntryForTest(name)
  setFeature(name, needs === undefined ? shipped[0] : needs, () => {
    loads++
    return new Promise((resolve, reject) => {
      arrive = () => resolve(module)
      fail = reject
    })
  })
  return { arrive: () => arrive(), fail: (error) => fail(error), loads: () => loads }
}

function addTarget(id, attrs = {}) {
  const el = document.createElement("div")
  el.id = id
  for (const [name, value] of Object.entries(attrs)) el.setAttribute(name, value)
  document.body.appendChild(el)
  return el
}

function makeStream(action, target, { effect = null, content = null } = {}) {
  const stream = document.createElement("turbo-stream")
  stream.setAttribute("action", action)
  if (target) stream.setAttribute("target", target)
  if (effect) stream.setAttribute("data-reactive-effect", effect)
  if (content !== null) {
    const template = document.createElement("template")
    template.innerHTML = content
    stream.appendChild(template)
  }
  return stream
}

// Fire turbo:before-stream-render as Turbo does and return the detail whose
// (possibly wrapped) render Turbo would then await.
function fire(stream, render) {
  const detail = { render, newStream: stream }
  document.dispatchEvent(new window.CustomEvent("turbo:before-stream-render", { detail }))
  return detail
}

// What Turbo's own append does, enough for these tests.
const appendInto = (target) => async (stream) => {
  target.appendChild(stream.querySelector("template").content.cloneNode(true))
}

describe("effects: a stream that needs the module before it is loaded", () => {
  test("a plain stream on a page with nothing to animate is left alone and imports nothing", () => {
    const effects = slowFeature("effects", effectsModule)
    addTarget("list")
    const render = async () => {}

    const detail = fire(makeStream("append", "list", { content: "<p>row</p>" }), render)

    expect(detail.render).toBe(render)
    expect(effects.loads()).toBe(0)
  })

  test("an exit effect on the target holds the removal until the module is here, then animates it", async () => {
    const effects = slowFeature("effects", effectsModule)
    const row = addTarget("row", { "data-reactive-effect-exit": "fade", "data-test-duration": "0.2s" })
    let removed = false
    const detail = fire(makeStream("remove", "row"), async () => {
      removed = true
      row.remove()
    })
    expect(effects.loads()).toBe(1)

    const done = detail.render(detail.newStream)
    await settle()
    expect(removed).toBe(false) // waiting for the module, not removed plain

    effects.arrive()
    await settle()
    expect(row.classList.contains("reactive-fx--fade-exit")).toBe(true)
    expect(removed).toBe(false) // now animating

    row.dispatchEvent(new window.Event("animationend"))
    await done
    expect(removed).toBe(true)
  })

  test("a per-call effect on the stream itself is enough to load the module", async () => {
    const effects = slowFeature("effects", effectsModule)
    const list = addTarget("list")
    const stream = makeStream("append", "list", { effect: "fade", content: `<p id="new">row</p>` })
    const detail = fire(stream, appendInto(list))

    const done = detail.render(stream)
    effects.arrive()
    await done

    expect(effects.loads()).toBe(1)
    expect(document.getElementById("new")).not.toBeNull()
  })

  test("a stream BEHIND the waiting one waits too: two streams to one target render in order", async () => {
    const effects = slowFeature("effects", effectsModule)
    const list = addTarget("list")
    const order = []
    const first = makeStream("append", "list", { content: `<p data-reactive-effect-enter="fade">one</p>` })
    const second = makeStream("append", "list", { content: "<p>two</p>" })
    const one = fire(first, async (stream) => {
      order.push("one")
      await appendInto(list)(stream)
    })
    const two = fire(second, async (stream) => {
      order.push("two")
      await appendInto(list)(stream)
    })

    // Turbo calls each stream's render in arrival order and awaits each on its
    // own: without the hold on BOTH, the plain second stream would render at
    // once, ahead of the first.
    const done = [one.render(first), two.render(second)]
    await settle()
    expect(order).toEqual([])

    effects.arrive()
    await Promise.all(done)

    expect(order).toEqual(["one", "two"])
    expect(list.textContent).toBe("onetwo")
  })

  test("a dismissing flash that arrives by stream is scheduled when it has RENDERED, from the render", async () => {
    installFakeTimers()
    const effects = slowFeature("effects", effectsModule)
    const flash = addTarget("flash")
    const stream = makeStream("append", "flash", { content: `<p id="notice" data-reactive-dismiss-after="3000">Saved</p>` })
    const detail = fire(stream, appendInto(flash))
    const done = detail.render(stream)
    await settle()
    expect(document.getElementById("notice")).toBeNull() // render is waiting

    effects.arrive()
    await done

    const notice = document.getElementById("notice")
    expect(notice.hasAttribute("data-reactive-dismiss-scheduled")).toBe(true)
    // One removal timer, for the full 3 s, set after the render.
    expect(timers.filter((timer) => timer.ms === 3000)).toHaveLength(1)
    runTimers(3000)
    expect(document.getElementById("notice")).toBeNull()
  })

  test("a flash already on the page makes the next stream load the module, and it is scheduled", async () => {
    installFakeTimers()
    const effects = slowFeature("effects", effectsModule)
    const notice = addTarget("notice", { "data-reactive-dismiss-after": "500" })
    const list = addTarget("list")
    const stream = makeStream("append", "list", { content: "<p>row</p>" })
    const detail = fire(stream, appendInto(list))

    const done = detail.render(stream)
    effects.arrive()
    await done

    expect(effects.loads()).toBe(1)
    expect(notice.hasAttribute("data-reactive-dismiss-scheduled")).toBe(true)
  })

  test("the wait is bounded: after 1 s the streams render plain, in order", async () => {
    installFakeTimers()
    const effects = slowFeature("effects", effectsModule)
    const row = addTarget("row", { "data-reactive-effect-exit": "fade", "data-test-duration": "0.2s" })
    const order = []
    const first = fire(makeStream("remove", "row"), async () => order.push("remove"))
    const second = fire(makeStream("append", "row", { content: "<i>x</i>" }), async () => order.push("append"))
    const done = [first.render(first.newStream), second.render(second.newStream)]
    await settle()
    expect(order).toEqual([])

    runTimers(1000)
    await Promise.all(done)

    expect(order).toEqual(["remove", "append"])
    expect(row.classList.contains("reactive-fx--fade-exit")).toBe(false)
    expect(effects.loads()).toBe(1)
  })

  test("a module that arrives after the wait sweeps up the flashes rendered meanwhile", async () => {
    installFakeTimers()
    const effects = slowFeature("effects", effectsModule)
    const flash = addTarget("flash")
    const stream = makeStream("append", "flash", { content: `<p id="notice" data-reactive-dismiss-after="3000">Saved</p>` })
    const detail = fire(stream, appendInto(flash))
    const done = detail.render(stream)
    runTimers(1000)
    await done
    const notice = document.getElementById("notice")
    expect(notice.hasAttribute("data-reactive-dismiss-scheduled")).toBe(false)

    effects.arrive()
    await settle()

    expect(notice.hasAttribute("data-reactive-dismiss-scheduled")).toBe(true)
  })

  test("a module that cannot be imported: the stream renders plain and the failure is logged once", async () => {
    const effects = slowFeature("effects", effectsModule)
    const row = addTarget("row", { "data-reactive-effect-exit": "fade" })
    let removed = 0
    const first = fire(makeStream("remove", "row"), async () => removed++)
    const done = first.render(first.newStream)

    effects.fail(new Error("404"))
    await done
    const second = fire(makeStream("remove", "row"), async () => removed++)
    await second.render(second.newStream)

    expect(removed).toBe(2)
    expect(errors.filter((line) => line.includes('the "effects" feature module'))).toHaveLength(1)
  })

  test("once the module is loaded a stream is wrapped when its event fires, with no wait", async () => {
    const effects = slowFeature("effects", effectsModule)
    const row = addTarget("row", { "data-reactive-effect-exit": "fade", "data-test-duration": "0.2s" })
    const first = fire(makeStream("remove", "row"), async () => {})
    const waiting = first.render(first.newStream)
    effects.arrive()
    await settle()
    row.dispatchEvent(new window.Event("animationend"))
    await waiting

    const detail = fire(makeStream("remove", "row"), async () => {})
    const done = detail.render(detail.newStream)

    // Synchronously inside render(): the class is on before any await.
    expect(row.classList.contains("reactive-fx--fade-exit")).toBe(true)
    row.dispatchEvent(new window.Event("animationend"))
    await done
  })

  test("a root that DECLARES an effect starts the import when it connects", () => {
    const effects = slowFeature("effects", effectsModule)
    const root = addTarget("card", { "data-reactive-effect-update": "highlight" })
    const controller = new ReactiveController()
    controller.element = root

    controller.connect()

    expect(effects.loads()).toBe(1)
    controller.disconnect()
  })
})

describe("form: edits made before the module arrived", () => {
  function dirtyRoot() {
    const root = addTarget("profile", { "data-controller": "reactive", "data-reactive-warn-unsaved": "true" })
    root.innerHTML = `<input type="text" name="name" value="Ada" data-action="input->reactive#trackDirty">`
    const controller = new ReactiveController()
    controller.element = root
    return { root, controller, input: root.querySelector("input") }
  }

  test("an edit in the window is counted when the module connects", async () => {
    const form = slowFeature("form", formModule)
    const { root, controller, input } = dirtyRoot()

    controller.connect()
    input.value = "Grace"
    controller.trackDirty() // the action fires; the module is not here yet
    expect(root.hasAttribute("data-reactive-dirty")).toBe(false)

    form.arrive()
    await controller.featuresReady

    expect(root.getAttribute("data-reactive-dirty")).toBe("1")
    expect(input.getAttribute("data-reactive-dirty")).toBe("true")
    controller.disconnect()
  })

  test("the navigate-away guard is armed when the module connects, not before (the documented window)", async () => {
    const form = slowFeature("form", formModule)
    const { controller, input } = dirtyRoot()
    const guarded = []
    globalThis.window = {
      addEventListener: (name) => guarded.push(name),
      removeEventListener: () => {},
      confirm: () => false,
    }

    controller.connect()
    input.value = "Grace"
    expect(guarded).toEqual([])

    form.arrive()
    await controller.featuresReady

    expect(guarded).toEqual(["beforeunload", "turbo:before-visit"])
    controller.disconnect()
  })

  test("a paste trigger is revealed when the module connects", async () => {
    const form = slowFeature("form", formModule)
    globalThis.navigator = { clipboard: { readText: async () => "" } }
    const root = addTarget("otp", { "data-controller": "reactive" })
    root.innerHTML = `<button data-reactive-clipboard="true" hidden>Paste</button>`
    const controller = new ReactiveController()
    controller.element = root

    controller.connect()
    expect(root.querySelector("button").hidden).toBe(true)

    form.arrive()
    await controller.featuresReady

    expect(root.querySelector("button").hidden).toBe(false)
    controller.disconnect()
  })

  test("a draft restored AFTER the dirty baseline was taken is counted (the late restore re-runs the scan)", async () => {
    const persistModule = await import(`${SOURCE}/features/persist.js`)
    const persist = slowFeature("persist", persistModule)
    mod.registerReactiveFeature("form", formModule) // the form module is here; the draft module is not
    const store = new Map([["phlex-reactive:persist:profile", JSON.stringify({ v: 1, savedAt: Date.now(), fields: { name: "Grace" } })]])
    globalThis.localStorage = {
      getItem: (key) => store.get(key) ?? null,
      setItem: (key, value) => store.set(key, String(value)),
      removeItem: (key) => store.delete(key),
    }
    const root = addTarget("profile", { "data-controller": "reactive", "data-reactive-token-value": "tok" })
    root.innerHTML = `<input type="text" name="name" value="Ada" data-action="input->reactive#trackDirty">`
    const controller = new ReactiveController()
    controller.element = root

    try {
      controller.connect() // the form module connects here: baseline taken
      expect(root.hasAttribute("data-reactive-dirty")).toBe(false) // server value, clean

      // A morph turns the root into a persisted one; its draft module is slow.
      root.setAttribute("data-reactive-persist", JSON.stringify({ key: "profile", ttl: 3600, restore: "always" }))
      root.dispatchEvent(new window.Event("turbo:morph-element", { bubbles: true }))
      persist.arrive()
      await controller.featuresReady

      expect(root.querySelector("input").value).toBe("Grace")
      expect(root.getAttribute("data-reactive-dirty")).toBe("1")
    } finally {
      controller.disconnect()
      delete globalThis.localStorage
    }
  })

  // Issue #312: a tokenless `cache:` shell (#306) morphed, still connected,
  // into a draft-keeping root imports the draft module then and restores.
  test("a tokenless cache: shell morphed into a draft-keeping root imports the module and restores", async () => {
    const persistModule = await import(`${SOURCE}/features/persist.js`)
    const persist = slowFeature("persist", persistModule)
    mod.registerReactiveFeature("defer", await import(`${SOURCE}/features/defer.js`))
    const store = new Map([["phlex-reactive:persist:panel", JSON.stringify({ v: 1, savedAt: Date.now(), fields: { name: "Grace" } })]])
    globalThis.localStorage = {
      getItem: (key) => store.get(key) ?? null,
      setItem: (key, value) => store.set(key, String(value)),
      removeItem: (key) => store.delete(key),
    }
    const root = addTarget("panel", {
      "data-controller": "reactive",
      "data-reactive-lazy-on": "panel:opened",
      "data-reactive-defer-src": "/reactive/fragment/abc?v=1",
    })
    const controller = new ReactiveController()
    controller.element = root

    try {
      controller.connect()
      expect(persist.loads()).toBe(0)

      root.removeAttribute("data-reactive-lazy-on")
      root.removeAttribute("data-reactive-defer-src")
      root.setAttribute("data-reactive-persist", JSON.stringify({ key: "panel", ttl: 3600 }))
      root.innerHTML = `<input type="text" name="name">`
      root.dispatchEvent(new window.Event("turbo:morph-element", { bubbles: true }))
      expect(persist.loads()).toBe(1)
      persist.arrive()
      await controller.featuresReady

      expect(root.querySelector("input").value).toBe("Grace")
    } finally {
      controller.disconnect()
      delete globalThis.localStorage
    }
  })

  test("a root with neither marker never asks for the module", () => {
    const form = slowFeature("form", formModule)
    const root = addTarget("plain")
    root.innerHTML = `<input type="text" name="name">`
    const controller = new ReactiveController()
    controller.element = root

    controller.connect()

    expect(form.loads()).toBe(0)
    controller.disconnect()
  })
})

describe("dev: the latency simulator before its module is loaded", () => {
  // The module warns once per page that the sim is on; forget that here.
  beforeEach(() => devModule.resetLatencySim())

  function storage(initial = {}) {
    const map = new Map(Object.entries(initial))
    return {
      getItem: (key) => (map.has(key) ? map.get(key) : null),
      setItem: (key, value) => map.set(key, String(value)),
      removeItem: (key) => map.delete(key),
    }
  }

  function meta(name, content) {
    const el = document.createElement("meta")
    el.setAttribute("name", name)
    el.setAttribute("content", content)
    document.head.appendChild(el)
  }

  test("the runtime's own registration, before the entry has run, asks for nothing and caches no failure", async () => {
    const dev = slowFeature("devtools", devModule)
    globalThis.sessionStorage = storage()
    globalThis.window = { Turbo: undefined }
    meta("phlex-reactive-env", "development")
    // What the runtime's table holds before core.js has registered the loader.
    mod.__setReactiveFeatureForTest("devtools", null, null)

    mod.registerReactiveActions()
    await settle()
    expect(errors).toEqual([])

    // The entry then supplies the loader and registers again: the module loads.
    mod.__setReactiveFeatureForTest("devtools", null, () => Promise.resolve(devModule))
    mod.registerReactiveDev()
    await settle()
    expect(typeof globalThis.window.PhlexReactive?.enableLatencySim).toBe("function")
    expect(dev.loads()).toBe(0)
  })

  test("no development meta and no stored delay: registration imports nothing", () => {
    const dev = slowFeature("devtools", devModule)
    globalThis.sessionStorage = storage()
    globalThis.window = { ...window, Turbo: undefined }

    mod.registerReactiveActions()

    expect(dev.loads()).toBe(0)
  })

  test("the development meta imports the module at registration and attaches the console handle", async () => {
    const dev = slowFeature("devtools", devModule)
    globalThis.sessionStorage = storage()
    const fakeWindow = { Turbo: undefined }
    globalThis.window = fakeWindow
    meta("phlex-reactive-env", "development")

    mod.registerReactiveActions()
    expect(dev.loads()).toBe(1)
    expect(fakeWindow.PhlexReactive).toBeUndefined()

    dev.arrive()
    await settle()

    expect(typeof fakeWindow.PhlexReactive.enableLatencySim).toBe("function")
  })

  test("a stored delay imports the module at registration but attaches no handle without the meta", async () => {
    const dev = slowFeature("devtools", devModule)
    globalThis.sessionStorage = storage({ "phlex-reactive:latency": "400" })
    const fakeWindow = { Turbo: undefined }
    globalThis.window = fakeWindow

    mod.registerReactiveActions()
    dev.arrive()
    await settle()

    expect(dev.loads()).toBe(1)
    expect(fakeWindow.PhlexReactive).toBeUndefined()
  })

  test("the first request made while a delay is stored waits for the module, then for the delay", async () => {
    installFakeTimers()
    const dev = slowFeature("devtools", devModule)
    globalThis.sessionStorage = storage({ "phlex-reactive:latency": "400" })
    let fetched = 0
    globalThis.fetch = () => {
      fetched++
      return Promise.resolve({ redirected: false, ok: true, status: 200, headers: { get: () => "text/vnd.turbo-stream.html" }, text: () => Promise.resolve("") })
    }
    globalThis.window = { Turbo: { renderStreamMessage: () => {} } }
    const root = addTarget("counter")
    const controller = new ReactiveController()
    controller.element = root
    controller.tokenValue = "tok"

    const done = controller.dispatch({ params: { action: "go", params: "{}" }, preventDefault: () => {} })
    await settle()
    expect(fetched).toBe(0) // waiting for the module

    dev.arrive()
    await settle()
    expect(fetched).toBe(0) // now waiting for the 400 ms
    expect(timers.some((timer) => timer.ms === 400)).toBe(true)

    runTimers(400)
    await done
    expect(fetched).toBe(1)
    expect(warns.some((line) => line.includes("latency simulator ACTIVE"))).toBe(true)
  })

  test("with no delay stored a request neither imports the module nor waits", async () => {
    const dev = slowFeature("devtools", devModule)
    globalThis.sessionStorage = storage()
    let fetched = 0
    globalThis.fetch = () => {
      fetched++
      return Promise.resolve({ redirected: false, ok: true, status: 200, headers: { get: () => "text/vnd.turbo-stream.html" }, text: () => Promise.resolve("") })
    }
    globalThis.window = { Turbo: { renderStreamMessage: () => {} } }
    const root = addTarget("counter")
    const controller = new ReactiveController()
    controller.element = root
    controller.tokenValue = "tok"

    await controller.dispatch({ params: { action: "go", params: "{}" }, preventDefault: () => {} })

    expect(fetched).toBe(1)
    expect(dev.loads()).toBe(0)
  })
})

describe("per-root cost: a loaded feature with nothing to do per root", () => {
  test("its marker check is not run once the module is loaded", () => {
    let reads = 0
    setFeature(
      "effects",
      () => {
        reads++
        return false
      },
      () => Promise.resolve(effectsModule),
    )
    mod.registerReactiveFeature("effects", effectsModule)
    const controller = new ReactiveController()
    controller.element = addTarget("plain")

    controller.connect()

    expect(reads).toBe(0)
    controller.disconnect()
  })

  test("a feature that connects per root still has its marker read", () => {
    let reads = 0
    setFeature(
      "form",
      () => {
        reads++
        return false
      },
      () => Promise.resolve(formModule),
    )
    mod.registerReactiveFeature("form", formModule)
    const controller = new ReactiveController()
    controller.element = addTarget("plain")

    controller.connect()

    expect(reads).toBe(1)
    controller.disconnect()
  })
})
