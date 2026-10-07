// Unit tests for the last feature modules of issue #275 — bindings (show,
// on-complete, filter, tags, nested rows, the conditional confirm), compute,
// hints and devtools — on the OPT-IN split client, where a module may not be
// loaded when it is first needed.
//
// What each must not lose in that window:
//
//   hints     a request whose trigger declares an optimistic/busy hint waits
//             for the module (at most the feature timeout), then the hint is
//             applied and the request goes out — once. The busy markers cover
//             the wait. A failure after a late apply still reverts the
//             optimistic ops; settle still undoes the busy ones.
//   compute   an edit in the window is recomputed once the module is here,
//             from the inputs as the user left them; a `recompute` the window
//             dispatched has run exactly once by then. The feature gates: a
//             request waits for it.
//   bindings  typing into a show-bound field in the window is kept, and the
//             binding reflects it on arrival; a tag picked in the window is
//             added on arrival; a conditional confirm prompts once the module
//             can evaluate it. The feature gates.
//   devtools  a zero-target warning on a verbose root arrives once the module
//             has (a tick late); without the gate the module is never asked for.
//   streams   a stream that swaps in a root needing a module holds its render
//             for the import, read off the feature table — so the new root
//             connects with the module present.
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
let resetStreamHold
let bindingsModule
let computeModule
let hintsModule
let devtoolsModule
let computeSeam
let confirmSeam

const SOURCE = "../../app/javascript/phlex/reactive"

beforeAll(async () => {
  globalThis.document = window.document
  globalThis.CustomEvent = window.CustomEvent
  mock.module("@hotwired/stimulus", () => ({ Controller: class {} }))
  mod = await import(`${SOURCE}/reactive_controller.js`)
  ReactiveController = mod.default
  setFeature = mod.__setReactiveFeatureForTest
  resetFeatures = mod.__resetReactiveFeaturesForTest
  ;({ __resetReactiveStreamHoldForTest: resetStreamHold } = await import(`${SOURCE}/core.js`))
  bindingsModule = await import(`${SOURCE}/features/bindings.js`)
  computeModule = await import(`${SOURCE}/features/compute.js`)
  hintsModule = await import(`${SOURCE}/features/hints.js`)
  devtoolsModule = await import(`${SOURCE}/features/devtools.js`)
  computeSeam = await import(`${SOURCE}/compute.js`)
  confirmSeam = await import(`${SOURCE}/confirm.js`)
  // One stream-render listener on THIS file's document: registered once here
  // (a registration per test would stack listeners), after clearing the
  // runtime's guard (another file registered on its own document).
  mod.__resetReactiveStreamRenderForTest()
  mod.registerReactiveStreamRender()
})

const realConsole = globalThis.console
const ORIGINALS = { window: globalThis.window, fetch: globalThis.fetch, navigator: globalThis.navigator }
let errors
let warns
let fetched
let fetchScript

const settle = () => new Promise((resolve) => setTimeout(resolve, 0))

beforeEach(() => {
  globalThis.document = window.document
  globalThis.CustomEvent = window.CustomEvent
  globalThis.Event = window.Event
  document.head.innerHTML = ""
  document.body.innerHTML = ""
  globalThis.navigator = { onLine: true }
  globalThis.window = { Turbo: { renderStreamMessage: () => {} }, addEventListener: () => {}, removeEventListener: () => {} }
  fetched = 0
  fetchScript = {}
  globalThis.fetch = () => {
    fetched++
    if (fetchScript.reject) return Promise.reject(fetchScript.reject)
    return (fetchScript.hold ?? Promise.resolve()).then(() => ({
      redirected: false,
      ok: true,
      status: 200,
      headers: { get: () => "text/vnd.turbo-stream.html" },
      text: () => Promise.resolve(""),
    }))
  }
  errors = []
  warns = []
  globalThis.console = {
    ...realConsole,
    error: (...args) => errors.push(args.map(String).join(" ")),
    warn: (...args) => warns.push(args.map(String).join(" ")),
    groupCollapsed: (...args) => warns.push(args.join(" ")),
    log: () => {},
    groupEnd: () => {},
  }
  // Cold: the state of a page that imported phlex/reactive/core.
  resetFeatures(true)
  resetStreamHold()
  computeSeam.__resetComputeRegistryForTest?.()
})

afterEach(() => {
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

// Put a feature behind an import the test settles by hand; `needs` as shipped.
function slowFeature(name, module) {
  let arrive
  let fail
  let loads = 0
  const shipped = mod.__reactiveFeatureEntryForTest(name)
  setFeature(name, shipped[0], () => {
    loads++
    return new Promise((resolve, reject) => {
      arrive = () => resolve(module)
      fail = reject
    })
  }, shipped[2], shipped[3])
  return { arrive: () => arrive(), fail: (error) => fail(error), loads: () => loads }
}

function addRoot(id, attrs = {}, html = "") {
  const el = document.createElement("div")
  el.id = id
  el.setAttribute("data-controller", "reactive")
  el.setAttribute("data-reactive-token-value", "tok")
  for (const [name, value] of Object.entries(attrs)) el.setAttribute(name, value)
  el.innerHTML = html
  document.body.appendChild(el)
  const controller = new ReactiveController()
  controller.element = el
  controller.tokenValue = "tok"
  return { root: el, controller }
}

function clickEvent(trigger, params) {
  return {
    currentTarget: trigger,
    target: trigger,
    params: { action: "go", params: "{}", ...params },
    defaultPrevented: false,
    preventDefault() {
      this.defaultPrevented = true
    },
  }
}

describe("hints: the first click of a cold page", () => {
  const HINT = '{"add_class":["busy"]}'

  test("a root whose trigger declares a hint starts the import when it connects", () => {
    const hints = slowFeature("hints", hintsModule)
    const { controller } = addRoot("c", {}, `<button data-reactive-optimistic-param='${HINT}'>go</button>`)

    controller.connect()

    expect(hints.loads()).toBe(1)
    controller.disconnect()
  })

  test("a click before the module arrives: the request waits for it, the hint applies, ONE request goes out", async () => {
    const hints = slowFeature("hints", hintsModule)
    const { root, controller } = addRoot("c", {}, `<button data-reactive-optimistic-param='${HINT}'>go</button>`)
    const button = root.querySelector("button")
    controller.connect()

    const done = controller.dispatch(clickEvent(button, { optimistic: { add_class: ["busy"] } }))
    await settle()
    expect(fetched).toBe(0)
    expect(button.classList.contains("busy")).toBe(false)
    // The always-on busy state covers the wait.
    expect(root.getAttribute("aria-busy")).toBe("true")
    expect(root.getAttribute("data-reactive-busy")).toBe("go")

    hints.arrive()
    await done

    expect(fetched).toBe(1)
    expect(button.classList.contains("busy")).toBe(true) // success leaves an optimistic hint standing
    expect(root.hasAttribute("aria-busy")).toBe(false)
    controller.disconnect()
  })

  test("a failure after the late apply still reverts the optimistic ops", async () => {
    const hints = slowFeature("hints", hintsModule)
    fetchScript.reject = new TypeError("Failed to fetch")
    const { root, controller } = addRoot("c", {}, `<button data-reactive-optimistic-param='${HINT}'>go</button>`)
    const button = root.querySelector("button")
    controller.connect()

    const done = controller.dispatch(clickEvent(button, { optimistic: { add_class: ["busy"] } }))
    await settle()
    hints.arrive()
    await done

    expect(fetched).toBe(1)
    expect(button.classList.contains("busy")).toBe(false)
    expect(root.getAttribute("data-reactive-error")).toBe("network")
    controller.disconnect()
  })

  test("a busy hint applied late shows while the request is pending, and is undone when it settles", async () => {
    const hints = slowFeature("hints", hintsModule)
    let respond
    fetchScript.hold = new Promise((resolve) => (respond = resolve))
    const { root, controller } = addRoot("c", {}, `<button data-reactive-busy-param='{"disable":true,"text":"Saving…"}'>Save</button>`)
    const button = root.querySelector("button")
    controller.connect()

    const done = controller.dispatch(clickEvent(button, { busy: { disable: true, text: "Saving…" } }))
    await settle()
    expect(button.disabled).toBe(false) // the module is not here
    hints.arrive()
    await settle()
    // Applied once the module was here, while the request is still pending…
    expect(fetched).toBe(1)
    expect(button.disabled).toBe(true)
    expect(button.innerHTML).toBe("Saving…")

    respond()
    await done

    // …and undone on settle: label and disabled restored.
    expect(button.disabled).toBe(false)
    expect(button.innerHTML).toBe("Save")
    controller.disconnect()
  })

  test("a module that cannot load: the request still goes out once, without its hint, and the failure is logged once", async () => {
    const hints = slowFeature("hints", hintsModule)
    const { root, controller } = addRoot("c", {}, `<button data-reactive-optimistic-param='${HINT}'>go</button>`)
    const button = root.querySelector("button")
    controller.connect()

    const done = controller.dispatch(clickEvent(button, { optimistic: { add_class: ["busy"] } }))
    await settle()
    hints.fail(new Error("404"))
    await done

    expect(fetched).toBe(1)
    expect(button.classList.contains("busy")).toBe(false)
    expect(errors.filter((line) => line.includes('the "hints" feature module'))).toHaveLength(1)
    controller.disconnect()
  })

  test("a module slower than the feature timeout: the request goes out without its hint", async () => {
    const meta = document.createElement("meta")
    meta.setAttribute("name", "phlex-reactive-feature-timeout")
    meta.setAttribute("content", "30")
    document.head.appendChild(meta)
    slowFeature("hints", hintsModule) // never arrives
    const { root, controller } = addRoot("c", {}, `<button data-reactive-optimistic-param='${HINT}'>go</button>`)
    const button = root.querySelector("button")
    controller.connect()

    await controller.dispatch(clickEvent(button, { optimistic: { add_class: ["busy"] } }))

    expect(fetched).toBe(1)
    expect(button.classList.contains("busy")).toBe(false)
    controller.disconnect()
  })

  test("a replayed early click with a hint (the D1 case): one request, after the import", async () => {
    const hints = slowFeature("hints", hintsModule)
    const { root, controller } = addRoot("c", {}, `<button data-action="click->reactive#dispatch" data-reactive-action-param="go" data-reactive-params-param="{}" data-reactive-optimistic-param='${HINT}'>go</button>`)
    const button = root.querySelector("button")
    const early = (globalThis[Symbol.for("phlex-reactive.early")] ??= { queue: [], connected: new WeakSet() })
    early.queue.length = 0
    early.queue.push({
      event: new window.MouseEvent("click", { bubbles: true, cancelable: true }),
      el: button,
      root,
      descs: [{ token: "click->reactive#dispatch", type: "click", method: "dispatch", filter: "" }],
      at: performance.now(),
    })

    controller.connect() // replays the click inside connect(), with the hint still on its way
    await settle()
    expect(fetched).toBe(0)
    expect(root.getAttribute("aria-busy")).toBe("true")

    hints.arrive()
    await controller.queue

    expect(fetched).toBe(1)
    expect(button.classList.contains("busy")).toBe(true)
    controller.disconnect()
  })

  test("the wait's timer is cleared once the module arrives (no 10 s timer left per request)", async () => {
    const hints = slowFeature("hints", hintsModule)
    const realSetTimeout = globalThis.setTimeout
    const realClearTimeout = globalThis.clearTimeout
    const live = new Set()
    globalThis.setTimeout = (fn, ms) => {
      const id = realSetTimeout(fn, ms)
      if (ms >= 1000) live.add(id)
      return id
    }
    globalThis.clearTimeout = (id) => {
      live.delete(id)
      realClearTimeout(id)
    }
    try {
      const { root, controller } = addRoot("c", {}, `<button data-reactive-optimistic-param='${HINT}'>go</button>`)
      controller.connect() // the root's own wait for the module arms one timer
      const armedAtConnect = live.size
      const done = controller.dispatch(clickEvent(root.querySelector("button"), { optimistic: { add_class: ["busy"] } }))
      await settle()
      expect(live.size).toBe(armedAtConnect + 1) // the request's feature-timeout timer, armed
      hints.arrive()
      await done
      await settle()
      expect(live.size).toBe(0) // every wait's timer cleared
      controller.disconnect()
    } finally {
      globalThis.setTimeout = realSetTimeout
      globalThis.clearTimeout = realClearTimeout
    }
  })

  test("a trigger without a hint never waits for the module", async () => {
    const hints = slowFeature("hints", hintsModule)
    const { root, controller } = addRoot("c", {}, `<button>go</button>`)
    controller.connect()

    await controller.dispatch(clickEvent(root.querySelector("button"), {}))

    expect(fetched).toBe(1)
    expect(hints.loads()).toBe(0)
    controller.disconnect()
  })
})

describe("compute: the window before the module", () => {
  const ATTRS = {
    "data-reactive-compute-reducer-param": "sum",
    "data-reactive-compute-inputs-param": '["a","b"]',
    "data-reactive-compute-outputs-param": '["total"]',
    "data-reactive-compute-seed": "true",
  }
  const FORM = `<input name="a" value="1"><input name="b" value="2"><input name="total" value="3">`

  test("an edit in the window is recomputed ONCE when the module arrives, from the user's inputs", async () => {
    const compute = slowFeature("compute", computeModule)
    let calls = 0
    computeSeam.setComputeReducer("sum", ({ a, b }) => (calls++, { total: a + b }))
    const { root, controller } = addRoot("calc", ATTRS, FORM)
    controller.connect()
    const a = root.querySelector('[name="a"]')
    a.value = "5"
    a.dispatchEvent(new window.Event("input", { bubbles: true }))
    controller.recompute({ target: a }) // the action fires; the module is not here yet
    expect(root.querySelector('[name="total"]').value).toBe("3")

    compute.arrive()
    await controller.featuresReady

    expect(a.value).toBe("5") // never clobbered
    expect(root.querySelector('[name="total"]').value).toBe("7")
    expect(calls).toBe(1)
    controller.disconnect()
  })

  test("without the seed marker, an edit in the window still gets its one recompute on arrival", async () => {
    const compute = slowFeature("compute", computeModule)
    let calls = 0
    computeSeam.setComputeReducer("sum", ({ a, b }) => (calls++, { total: a + b }))
    const { "data-reactive-compute-seed": _seed, ...noSeed } = ATTRS
    const { root, controller } = addRoot("calc", noSeed, FORM)
    controller.connect()
    const b = root.querySelector('[name="b"]')
    b.value = "10"
    b.dispatchEvent(new window.Event("input", { bubbles: true }))

    compute.arrive()
    await controller.featuresReady

    expect(root.querySelector('[name="total"]').value).toBe("11")
    expect(calls).toBe(1)
    controller.disconnect()
  })

  test("without the seed marker and no edit, arrival runs nothing", async () => {
    const compute = slowFeature("compute", computeModule)
    let calls = 0
    computeSeam.setComputeReducer("sum", ({ a, b }) => (calls++, { total: a + b }))
    const { "data-reactive-compute-seed": _seed, ...noSeed } = ATTRS
    const { controller } = addRoot("calc", noSeed, FORM)
    controller.connect()

    compute.arrive()
    await controller.featuresReady

    expect(calls).toBe(0)
    controller.disconnect()
  })

  test("the feature gates: a request made in the window waits for the module", async () => {
    const compute = slowFeature("compute", computeModule)
    computeSeam.setComputeReducer("sum", ({ a, b }) => ({ total: a + b }))
    const { root, controller } = addRoot("calc", ATTRS, `${FORM}<button>save</button>`)
    controller.connect()

    const done = controller.dispatch(clickEvent(root.querySelector("button"), {}))
    await settle()
    expect(fetched).toBe(0)

    compute.arrive()
    await done
    expect(fetched).toBe(1)
    controller.disconnect()
  })

  test("a root without a compute binding never asks for the module", () => {
    const compute = slowFeature("compute", computeModule)
    const { controller } = addRoot("plain", {}, FORM)
    controller.connect()
    expect(compute.loads()).toBe(0)
    controller.disconnect()
  })
})

describe("bindings: the window before the module", () => {
  test("typing into a show-bound field in the window is kept, and the binding reflects it on arrival", async () => {
    const bindings = slowFeature("bindings", bindingsModule)
    const { root, controller } = addRoot("form", {}, `<input name="kind" value=""><div id="extra" data-reactive-show='{"any":[[{"field":"kind","equals":"other"}]]}' hidden>more</div>`)
    controller.connect()
    expect(bindings.loads()).toBe(1)
    const kind = root.querySelector('[name="kind"]')
    kind.value = "other"
    kind.dispatchEvent(new window.Event("input", { bubbles: true }))
    expect(root.querySelector("#extra").hidden).toBe(true) // the server's rendering, still

    bindings.arrive()
    await controller.featuresReady

    expect(kind.value).toBe("other")
    expect(root.querySelector("#extra").hidden).toBe(false)
    controller.disconnect()
  })

  test("a root that only declares group targets (issue #343) loads the module and drives them on arrival", async () => {
    const bindings = slowFeature("bindings", bindingsModule)
    document.body.insertAdjacentHTML("beforeend", '<span id="outside-count">0</span>')
    const targets = JSON.stringify({ "ids[]": { count: ["#outside-count"] } })
    const { controller } = addRoot("div", { "data-reactive-group-targets": targets }, '<input type="checkbox" name="ids[]" value="1" checked>')
    controller.connect()
    expect(bindings.loads()).toBe(1)

    bindings.arrive()
    await controller.featuresReady

    expect(document.getElementById("outside-count").textContent).toBe("1")
    controller.disconnect()
  })

  test("a tag picked in the window is added once the module is here", async () => {
    const bindings = slowFeature("bindings", bindingsModule)
    const { root, controller } = addRoot("tags", { "data-reactive-tags-field": "[name=tags]" }, `
      <input type="hidden" name="tags" value="">
      <ul data-reactive-tags-list></ul>
      <template data-reactive-tags-template><li><span data-reactive-tag-text></span></li></template>
      <ul><li role="option" data-reactive-tag-param="ruby">ruby</li></ul>`)
    controller.connect()
    const option = root.querySelector("[role=option]")

    const picked = controller.tagsPick(clickEvent(option, {}))
    expect(root.querySelector('[name="tags"]').value).toBe("")

    bindings.arrive()
    await picked
    await controller.featuresReady

    expect(root.querySelector('[name="tags"]').value).toBe("ruby")
    expect(root.querySelectorAll("[data-reactive-tags-list] li")).toHaveLength(1)
    controller.disconnect()
  })

  test("a conditional confirm in the window prompts once the module can evaluate it, then the request goes out", async () => {
    const bindings = slowFeature("bindings", bindingsModule)
    const asked = []
    confirmSeam.setConfirmResolver((message) => (asked.push(message), true))
    const { root, controller } = addRoot("form", {}, `<input name="total" value="0"><button data-reactive-confirm-when-param='{"message":"Zero?","groups":{"any":[[{"field":"total","equals":"0"}]]}}'>go</button>`)
    controller.connect()
    expect(bindings.loads()).toBe(1)

    const done = controller.dispatch(clickEvent(root.querySelector("button"), { confirmWhen: { message: "Zero?", groups: { any: [[{ field: "total", equals: "0" }]] } } }))
    await settle()
    expect(asked).toEqual([])
    expect(fetched).toBe(0)

    bindings.arrive()
    await done
    await controller.queue

    expect(asked).toEqual(["Zero?"])
    expect(fetched).toBe(1)
    confirmSeam.setConfirmResolver(null)
    controller.disconnect()
  })

  test("a conditional confirm whose module never comes: the request goes out at the feature timeout, with no dialog", async () => {
    const meta = document.createElement("meta")
    meta.setAttribute("name", "phlex-reactive-feature-timeout")
    meta.setAttribute("content", "30")
    document.head.appendChild(meta)
    slowFeature("bindings", bindingsModule) // never arrives
    const asked = []
    confirmSeam.setConfirmResolver((message) => (asked.push(message), true))
    const { root, controller } = addRoot("form", {}, `<input name="total" value="0"><button data-reactive-confirm-when-param='{"message":"Zero?"}'>go</button>`)
    controller.connect()

    await controller.dispatch(clickEvent(root.querySelector("button"), { confirmWhen: { message: "Zero?", groups: { any: [[{ field: "total", equals: "0" }]] } } }))
    await controller.queue

    expect(asked).toEqual([])
    expect(fetched).toBe(1)
    confirmSeam.setConfirmResolver(null)
    controller.disconnect()
  })

  test("the feature gates: a request from a show-bound form waits for the module", async () => {
    const bindings = slowFeature("bindings", bindingsModule)
    const { root, controller } = addRoot("form", {}, `<input name="kind"><div data-reactive-show-field="kind" data-reactive-show-equals="x">x</div><button>save</button>`)
    controller.connect()

    const done = controller.dispatch(clickEvent(root.querySelector("button"), {}))
    await settle()
    expect(fetched).toBe(0)

    bindings.arrive()
    await done
    expect(fetched).toBe(1)
    controller.disconnect()
  })
})

describe("devtools: the diagnostics", () => {
  test("a verbose root's zero-target warning arrives once the module has (a tick late)", async () => {
    const devtools = slowFeature("devtools", devtoolsModule)
    const { root, controller } = addRoot("ops", { "data-reactive-verbose": "true" }, `<button>x</button>`)
    controller.connect()
    expect(devtools.loads()).toBe(0) // verbose alone preloads nothing

    controller.runOps({ preventDefault() {}, target: root.querySelector("button"), currentTarget: root.querySelector("button"), params: { ops: JSON.stringify([["hide", { to: "#nope" }]]) } })
    expect(devtools.loads()).toBe(1)
    expect(warns).toEqual([])

    devtools.arrive()
    await settle()

    expect(warns.some((line) => line.includes("matched zero targets"))).toBe(true)
    controller.disconnect()
  })

  test("without the gate a zero-target op never asks for the module", () => {
    const devtools = slowFeature("devtools", devtoolsModule)
    const { root, controller } = addRoot("ops", {}, `<button>x</button>`)
    controller.connect()

    controller.runOps({ preventDefault() {}, target: root.querySelector("button"), currentTarget: root.querySelector("button"), params: { ops: JSON.stringify([["hide", { to: "#nope" }]]) } })

    expect(devtools.loads()).toBe(0)
    controller.disconnect()
  })

  test("a root in debug mode preloads the module, and its trace is logged once the module is here", async () => {
    const devtools = slowFeature("devtools", devtoolsModule)
    const { root, controller } = addRoot("dbg", { "data-reactive-debug": "true" }, `<button>go</button>`)
    controller.connect()
    expect(devtools.loads()).toBe(1)

    await controller.dispatch(clickEvent(root.querySelector("button"), {}))
    expect(fetched).toBe(1)
    expect(warns.some((line) => line.startsWith("reactive #dbg go"))).toBe(false)

    devtools.arrive()
    await settle()
    expect(warns.some((line) => line.startsWith("reactive #dbg go"))).toBe(true)
    controller.disconnect()
  })
})

describe("streams: a root a stream brings in", () => {
  function fire(stream, render) {
    const detail = { render, newStream: stream }
    document.dispatchEvent(new window.CustomEvent("turbo:before-stream-render", { detail }))
    return detail
  }

  test("a stream that swaps in a show-bound form holds its render until the bindings module is here", async () => {
    const bindings = slowFeature("bindings", bindingsModule)
    const slot = document.createElement("div")
    slot.id = "slot"
    document.body.appendChild(slot)
    const stream = document.createElement("turbo-stream")
    stream.setAttribute("action", "update")
    stream.setAttribute("target", "slot")
    const template = document.createElement("template")
    template.innerHTML = `<div id="form" data-controller="reactive" data-reactive-token-value="tok"><input name="kind"><div data-reactive-show-field="kind" data-reactive-show-equals="x">x</div></div>`
    stream.appendChild(template)
    let rendered = false
    const detail = fire(stream, async () => {
      rendered = true
    })
    expect(bindings.loads()).toBe(1) // read off the table, before any root connected

    const done = detail.render(stream)
    await settle()
    expect(rendered).toBe(false)

    bindings.arrive()
    await done
    expect(rendered).toBe(true)
  })

  test("a stream that arrives while a hold is open adds its own modules to it", async () => {
    const bindings = slowFeature("bindings", bindingsModule)
    const effectsModule = await import(`${SOURCE}/features/effects.js`)
    const effects = slowFeature("effects", effectsModule)
    const slot = document.createElement("div")
    slot.id = "slot"
    document.body.appendChild(slot)
    const row = document.createElement("div")
    row.id = "row"
    document.body.appendChild(row)
    globalThis.getComputedStyle = () => ({ animationDuration: "0.2s", animationDelay: "0s", transitionDuration: "0s", transitionDelay: "0s" })
    globalThis.matchMedia = () => ({ matches: false })
    // A: swaps in a show-bound form (needs bindings) — opens the hold.
    const first = document.createElement("turbo-stream")
    first.setAttribute("action", "update")
    first.setAttribute("target", "slot")
    const template = document.createElement("template")
    template.innerHTML = `<div data-controller="reactive" data-reactive-token-value="tok"><input name="kind"><div data-reactive-show-field="kind" data-reactive-show-equals="x">x</div></div>`
    first.appendChild(template)
    let renderedOne = false
    const one = fire(first, async () => {
      renderedOne = true
    })
    const doneOne = one.render(first)
    expect(effects.loads()).toBe(0)
    // B: removes a row with a per-call effect (needs effects) — joins the hold.
    const second = document.createElement("turbo-stream")
    second.setAttribute("action", "remove")
    second.setAttribute("target", "row")
    second.setAttribute("data-reactive-effect", "fade")
    let removed = false
    const two = fire(second, async () => {
      removed = true
    })
    const doneTwo = two.render(second)
    expect(effects.loads()).toBe(1) // B's module was asked for

    // A's module releases A (in order, it is first); B goes on waiting for ITS
    // module, which the grown hold now covers.
    bindings.arrive()
    await doneOne
    expect(renderedOne).toBe(true)
    await settle()
    expect(removed).toBe(false)

    effects.arrive()
    await settle()
    expect(row.classList.contains("reactive-fx--fade-exit")).toBe(true) // B animated with ITS module
    expect(removed).toBe(false)
    row.dispatchEvent(new window.Event("animationend"))
    await doneTwo
    expect(removed).toBe(true)
  })

  test("a stream whose content needs nothing renders at once", async () => {
    const bindings = slowFeature("bindings", bindingsModule)
    const stream = document.createElement("turbo-stream")
    stream.setAttribute("action", "update")
    stream.setAttribute("target", "slot")
    const template = document.createElement("template")
    template.innerHTML = `<p>plain</p>`
    stream.appendChild(template)
    const render = async () => {}

    const detail = fire(stream, render)

    expect(detail.render).toBe(render)
    expect(bindings.loads()).toBe(0)
  })
})
