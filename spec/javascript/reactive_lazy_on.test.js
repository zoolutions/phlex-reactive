// reactive_lazy(on:) client half (issue #276). The server renders an on:
// shell with the IDENTITY token — NO defer token — plus one of two markers:
//
//   data-reactive-lazy-on="<event>"       an event shell (it also carries the
//                                         once-bound `<event>->reactive#dispatch`
//                                         descriptor for __materialize)
//   data-reactive-lazy-visible="<margin>" a visibility shell (no descriptor)
//
// Every materialize funnels through ONE controller method, whichever way it
// starts (the Stimulus binding, the IntersectionObserver, a morph), so:
//   * connect() never fetches for a shell;
//   * a :visible shell materializes straight from the observer callback;
//   * a root showing REAL content that a Turbo morph turns back into a shell
//     re-materializes at once (it was loaded; the morph wiped it);
//   * a shell that is still unloaded after a morph (never triggered, or a
//     failed load) is re-armed — its spent `once` binding is not relied on;
//   * a morph landing mid-flight never double-requests, and a morph that
//     leaves real content real requests nothing.
//
// Every assertion below counts actual `__materialize` POSTs, not observers.
//
// Run with: bun test spec/javascript
import { test, expect, mock, describe, beforeAll, beforeEach, afterEach } from "bun:test"

let Controller
let coldFeatures

beforeAll(async () => {
  mock.module("@hotwired/stimulus", () => ({
    Controller: class {
      constructor() {}
    },
  }))
  const mod = await import("../../app/javascript/phlex/reactive/reactive_controller.js")
  // The opt-in entry: it tells the shared runtime where each feature module
  // lives. Without it a cold feature has no import to wait for.
  await import("../../app/javascript/phlex/reactive/core.js")
  Controller = mod.default
  // The defer code is a feature module (issue #275). Loaded up front, so a
  // connect or a `reactive:defer` stream reaches it in the same tick; the
  // not-yet-loaded path is covered in reactive_features.test.js.
  await mod.__loadReactiveFeatureForTest("defer")
  // Forgets every loaded feature module: the next connect() imports again.
  coldFeatures = mod.__resetReactiveFeaturesForTest
})

let observers
let posts
let nextResponse

class FakeIntersectionObserver {
  constructor(callback, options) {
    this.callback = callback
    this.options = options
    this.observed = []
    this.disconnected = false
    observers.push(this)
  }
  observe(el) {
    this.observed.push(el)
  }
  disconnect() {
    this.disconnected = true
  }
  trigger(isIntersecting) {
    if (this.disconnected) return
    this.callback([{ isIntersecting, target: this.observed[0] }])
  }
}

const okResponse = (body = "") => ({
  redirected: false,
  ok: true,
  status: 200,
  headers: { get: () => "text/vnd.turbo-stream.html" },
  text: () => Promise.resolve(body),
})

// A response the test releases later: queued duplicates would run (and POST)
// once it resolves, so "still one POST after release" proves none were queued.
function gate() {
  let release
  const promise = new Promise((resolve) => (release = () => resolve(okResponse())))
  return { promise, release }
}

// Let the queued #perform (and its finally) run to completion.
const settle = () => new Promise((resolve) => setTimeout(resolve, 0))

beforeEach(() => {
  delete globalThis[Symbol.for("phlex-reactive.early")]
  observers = []
  posts = []
  // Each POST consumes nextResponse(): a response, a rejection, or a pending gate.
  nextResponse = () => Promise.resolve(okResponse())
  globalThis.IntersectionObserver = FakeIntersectionObserver
  globalThis.window = { Turbo: { StreamActions: {}, renderStreamMessage: () => {} } }
  globalThis.document = {
    getElementById: () => null,
    querySelector: () => null,
    addEventListener: () => {},
    dispatchEvent: () => {},
  }
  globalThis.fetch = (url, options) => {
    posts.push(JSON.parse(options.body))
    return nextResponse()
  }
})

afterEach(() => {
  delete globalThis.IntersectionObserver
})

const TOKEN = "data-reactive-token-value"
const ON = "data-reactive-lazy-on"
const VISIBLE = "data-reactive-lazy-visible"

function makeRoot(attrs = {}) {
  const listeners = {}
  const el = {
    id: "lazy-root",
    isConnected: true,
    attrs: { ...attrs },
    listeners,
    getAttribute: (name) => el.attrs[name] ?? null,
    hasAttribute: (name) => name in el.attrs,
    setAttribute: (name, value) => (el.attrs[name] = value),
    removeAttribute: (name) => delete el.attrs[name],
    dispatchEvent: () => true,
    querySelectorAll: () => [],
    contains: () => true,
    // Stimulus's param reader (the early replay rebuilds event.params from it).
    get attributes() {
      return Object.entries(el.attrs).map(([name, value]) => ({ name, value }))
    },
    addEventListener: (name, fn) => (listeners[name] ??= []).push(fn),
    removeEventListener: (name, fn) => {
      listeners[name] = (listeners[name] ?? []).filter((registered) => registered !== fn)
    },
    // Fire a DOM event at the root's own listeners (the controller's, not Stimulus's).
    fire: (name, event = {}) =>
      (listeners[name] ?? []).slice().forEach((fn) => fn({ type: name, target: el, ...event })),
    // A Turbo morph rewrote the root's attributes in place, then announced it
    // (turbo:morph-element fires on the morphed element — here, the root).
    morphTo: (next) => {
      el.attrs = { ...next }
      el.fire("turbo:morph-element")
    },
    // A morph of a DESCENDANT: the same event, bubbling up to the root.
    morphChild: () => el.fire("turbo:morph-element", { target: { id: "a-child" } }),
  }
  return el
}

function connect(el) {
  const controller = new Controller()
  controller.element = el
  // Stimulus's value getter reads the live attribute.
  Object.defineProperty(controller, "tokenValue", { get: () => el.attrs[TOKEN] })
  controller.connect()
  return controller
}

// What Stimulus does when the shell's once-bound descriptor fires.
function stimulusFires(controller) {
  return controller.dispatch({
    type: "panel:opened",
    params: { action: "__materialize", params: "{}" },
    currentTarget: controller.element,
    target: controller.element,
    preventDefault: () => {},
  })
}

const visibleShell = (token = "shell-token") => ({ [TOKEN]: token, [VISIBLE]: "0px" })
const eventShell = (token = "shell-token") => ({ [TOKEN]: token, [ON]: "panel:opened" })
const realContent = (token = "real-token") => ({ [TOKEN]: token })

// --- connect ----------------------------------------------------------------

test("a visible shell observes itself with the rendered rootMargin and requests nothing", async () => {
  const el = makeRoot({ [TOKEN]: "shell-token", [VISIBLE]: "200px" })
  connect(el)
  await settle()

  expect(observers.length).toBe(1)
  expect(observers[0].options).toEqual({ rootMargin: "200px" })
  expect(observers[0].observed).toEqual([el])
  expect(posts).toEqual([])
})

test("an event shell requests nothing on connect and never observes", async () => {
  connect(makeRoot(eventShell()))
  await settle()

  expect(observers.length).toBe(0)
  expect(posts).toEqual([])
})

// --- the first materialize ----------------------------------------------------

test("intersecting POSTs __materialize once, straight from the controller, and stops observing", async () => {
  const el = makeRoot(visibleShell())
  connect(el)

  observers[0].trigger(false)
  await settle()
  expect(posts).toEqual([])

  observers[0].trigger(true)
  await settle()
  expect(posts).toEqual([{ token: "shell-token", act: "__materialize", params: {} }])
  expect(observers[0].disconnected).toBe(true)
})

test("the event shell's Stimulus binding POSTs __materialize once", async () => {
  const controller = connect(makeRoot(eventShell()))

  stimulusFires(controller)
  await settle()
  expect(posts).toEqual([{ token: "shell-token", act: "__materialize", params: {} }])
})

test("a second trigger while the first is in flight does not double-request", async () => {
  const pending = gate()
  nextResponse = () => pending.promise
  const controller = connect(makeRoot(eventShell()))

  stimulusFires(controller)
  stimulusFires(controller)
  await settle()
  expect(posts.length).toBe(1)

  pending.release()
  await settle()
  expect(posts.length).toBe(1)
})

test("without IntersectionObserver the visible shell materializes right after connect", async () => {
  delete globalThis.IntersectionObserver
  connect(makeRoot(visibleShell()))

  await settle()
  expect(posts.map((post) => post.act)).toEqual(["__materialize"])
})

test("disconnect() tears the observer down", () => {
  const controller = connect(makeRoot(visibleShell()))

  controller.disconnect()
  expect(observers[0].disconnected).toBe(true)
})

// --- real content morphed BACK into a shell (the root connected as real) -----

test("real content morphed back into a :visible shell re-materializes at once — one request", async () => {
  const el = makeRoot(realContent())
  connect(el)

  el.morphTo(visibleShell("morphed-token"))
  await settle()

  // No observer needed: it was loaded, the morph wiped it. The morphed-in
  // shell's token (server truth) is the one sent.
  expect(posts).toEqual([{ token: "morphed-token", act: "__materialize", params: {} }])
})

test("real content morphed back into an event shell re-materializes at once — one request", async () => {
  const el = makeRoot(realContent())
  connect(el)

  el.morphTo(eventShell("morphed-token"))
  await settle()

  expect(posts).toEqual([{ token: "morphed-token", act: "__materialize", params: {} }])
})

test("each morph-back costs exactly one request, even when a second morph lands mid-flight", async () => {
  const pending = gate()
  nextResponse = () => pending.promise
  const el = makeRoot(realContent())
  connect(el)

  el.morphTo(eventShell())
  el.morphTo(eventShell())
  await settle()
  expect(posts.length).toBe(1)

  pending.release()
  await settle()
  expect(posts.length).toBe(1)
})

test("a morph that leaves real content as real content requests nothing", async () => {
  const el = makeRoot(realContent())
  connect(el)

  el.morphTo(realContent("fresh-token"))
  await settle()

  expect(posts).toEqual([])
  expect(observers.length).toBe(0)
})

// --- a shell that is STILL an unloaded shell after a morph --------------------

test("a failed :visible load is retried after a morph: re-observe, then fire directly", async () => {
  nextResponse = () => Promise.reject(new Error("offline"))
  const el = makeRoot(visibleShell())
  connect(el)
  observers[0].trigger(true)
  await settle()
  expect(posts.length).toBe(1)

  // The failed shell alone never retries…
  await settle()
  expect(posts.length).toBe(1)

  // …a morph re-arms it, and the next intersection requests again.
  nextResponse = () => Promise.resolve(okResponse())
  el.morphTo(visibleShell())
  expect(observers.length).toBe(2)
  observers[1].trigger(true)
  await settle()
  expect(posts.length).toBe(2)
  expect(posts[1].act).toBe("__materialize")
})

test("a failed event load is retried after a morph: the event is accepted again", async () => {
  nextResponse = () => Promise.reject(new Error("offline"))
  const el = makeRoot(eventShell())
  const controller = connect(el)
  stimulusFires(controller)
  await settle()
  expect(posts.length).toBe(1)

  // Stimulus's `once` binding is spent; before a morph the event is dead.
  el.fire("panel:opened")
  await settle()
  expect(posts.length).toBe(1)

  nextResponse = () => Promise.resolve(okResponse())
  el.morphTo(eventShell())
  el.fire("panel:opened")
  await settle()
  expect(posts.length).toBe(2)
  expect(posts[1].act).toBe("__materialize")
})

test("a re-armed event listener is consumed by its attempt: one morph buys one retry", async () => {
  nextResponse = () => Promise.reject(new Error("offline"))
  const el = makeRoot(eventShell())
  const controller = connect(el)
  stimulusFires(controller)
  await settle()

  el.morphTo(eventShell())
  el.fire("panel:opened")
  await settle()
  expect(posts.length).toBe(2)

  // That retry failed too. Without another morph the event is dead again.
  el.fire("panel:opened")
  await settle()
  expect(posts.length).toBe(2)

  el.morphTo(eventShell())
  el.fire("panel:opened")
  await settle()
  expect(posts.length).toBe(3)
})

test("a never-triggered event shell after a morph requests once when both bindings fire", async () => {
  const pending = gate()
  nextResponse = () => pending.promise
  const el = makeRoot(eventShell())
  const controller = connect(el)

  el.morphTo(eventShell())
  await settle()
  expect(posts).toEqual([])

  // The intact Stimulus binding AND the re-armed listener both see the event.
  stimulusFires(controller)
  el.fire("panel:opened")
  await settle()
  expect(posts.length).toBe(1)

  pending.release()
  await settle()
  expect(posts.length).toBe(1)
})

test("a never-triggered :visible shell after a morph keeps ONE live observer", async () => {
  const el = makeRoot(visibleShell())
  connect(el)

  el.morphTo(visibleShell())
  const live = observers.filter((observer) => !observer.disconnected)
  expect(live.length).toBe(1)

  live[0].trigger(true)
  await settle()
  expect(posts.length).toBe(1)
})

test("a morph landing while the shell's load is in flight does not double-request", async () => {
  const pending = gate()
  nextResponse = () => pending.promise
  const el = makeRoot(visibleShell())
  connect(el)
  observers[0].trigger(true)
  await settle()
  expect(posts.length).toBe(1)

  el.morphTo(visibleShell())
  observers.forEach((observer) => observer.trigger(true))
  await settle()
  expect(posts.length).toBe(1)

  pending.release()
  await settle()
  expect(posts.length).toBe(1)
})

test("a shell morphed into real content stops observing and listening", async () => {
  const el = makeRoot(visibleShell())
  connect(el)

  el.morphTo(realContent())
  expect(observers[0].disconnected).toBe(true)
  observers[0].trigger(true)
  await settle()
  expect(posts).toEqual([])
})

// --- only a morph of the ROOT counts -------------------------------------------

test("a child morphing inside a failed shell does not re-arm it; a root morph does", async () => {
  nextResponse = () => Promise.reject(new Error("offline"))
  const el = makeRoot(eventShell())
  const controller = connect(el)
  stimulusFires(controller)
  await settle()
  expect(posts.length).toBe(1)

  // turbo:morph-element bubbles: a morphed skeleton <li> reaches the root.
  nextResponse = () => Promise.resolve(okResponse())
  el.morphChild()
  el.fire("panel:opened")
  await settle()
  expect(posts.length).toBe(1)

  el.morphTo(eventShell())
  el.fire("panel:opened")
  await settle()
  expect(posts.length).toBe(2)
})

test("a child morphing inside a failed :visible shell does not re-observe", async () => {
  nextResponse = () => Promise.reject(new Error("offline"))
  const el = makeRoot(visibleShell())
  connect(el)
  observers[0].trigger(true)
  await settle()

  el.morphChild()
  expect(observers.length).toBe(1)
})

test("a child morphing inside real content never materializes", async () => {
  const el = makeRoot(realContent())
  connect(el)

  // Even if the root's attributes changed some other way, a child's morph is
  // not the root's morph.
  el.attrs = { ...eventShell() }
  el.morphChild()
  await settle()
  expect(posts).toEqual([])
})

// --- the token sent after a morph-back ------------------------------------------

test("a morph-back sends the morphed-in shell's token, not one cached from an earlier reply", async () => {
  const el = makeRoot(realContent("page-token"))
  const controller = connect(el)

  // An action reply refreshes the token; the controller caches it.
  nextResponse = () =>
    Promise.resolve(
      okResponse('<turbo-stream action="reactive:token" target="lazy-root" data-reactive-token-value="reply-token">'),
    )
  controller.dispatch({
    type: "click",
    params: { action: "save", params: "{}" },
    currentTarget: el,
    target: el,
    preventDefault: () => {},
  })
  await settle()

  // Prove the cache is live: the next action sends the reply's token.
  nextResponse = () => Promise.resolve(okResponse())
  controller.dispatch({
    type: "click",
    params: { action: "save", params: "{}" },
    currentTarget: el,
    target: el,
    preventDefault: () => {},
  })
  await settle()
  expect(posts.map((post) => post.token)).toEqual(["page-token", "reply-token"])

  // The morph is server truth: its shell's token is the one to materialize with.
  el.morphTo(eventShell("morphed-token"))
  await settle()
  expect(posts[2]).toEqual({ token: "morphed-token", act: "__materialize", params: {} })
})

// --- cost gate ----------------------------------------------------------------

test("a tokenless (client-only) root wires no morph listener", () => {
  const el = makeRoot({})
  connect(el)

  expect(el.listeners["turbo:morph-element"] ?? []).toEqual([])
})

// --- composed with phlex/reactive/early (issue #273) ---------------------------
// early.js queues a trigger that fires BEFORE the controller connects; connect()
// replays it by calling dispatch() directly, and marks the `once` descriptor
// spent so Stimulus's still-armed listener is swallowed the one time it fires.

const EARLY = Symbol.for("phlex-reactive.early")
const DESCRIPTOR = "panel:opened->reactive#dispatch:once"

// The event shell exactly as the server renders it (descriptor + params).
const renderedEventShell = (token = "shell-token") => ({
  ...eventShell(token),
  "data-action": DESCRIPTOR,
  "data-reactive-action-param": "__materialize",
  "data-reactive-params-param": "{}",
})

// What early.js records for one `panel:opened` on the root before connect.
function queueEarly(el, count = 1) {
  globalThis[EARLY] ??= { queue: [], connected: new WeakSet() }
  for (let i = 0; i < count; i++) {
    globalThis[EARLY].queue.push({
      event: { type: "panel:opened", target: el },
      el,
      root: el,
      at: performance.now(),
      descs: [{ token: DESCRIPTOR, type: "panel:opened", filter: undefined, method: "dispatch" }],
    })
  }
}

test("an event fired before connect is replayed into exactly one __materialize", async () => {
  const pending = gate()
  nextResponse = () => pending.promise
  const el = makeRoot(renderedEventShell())
  queueEarly(el, 3)

  const controller = connect(el)
  await settle()
  expect(posts).toEqual([{ token: "shell-token", act: "__materialize", params: {} }])

  // A second event after connect: Stimulus's `once` listener is still armed
  // (the replay bypassed it). It must not start a second load.
  stimulusFires(controller)
  await settle()
  expect(posts.length).toBe(1)

  pending.release()
  await settle()
  expect(posts.length).toBe(1)
})

test("after an early replay whose load FAILED, later events stay dead until a morph re-arms", async () => {
  nextResponse = () => Promise.reject(new Error("offline"))
  const el = makeRoot(renderedEventShell())
  queueEarly(el)
  const controller = connect(el)
  await settle()
  expect(posts.length).toBe(1)

  // The armed Stimulus listener fires once (swallowed as spent), then is gone.
  stimulusFires(controller)
  el.fire("panel:opened")
  await settle()
  expect(posts.length).toBe(1)

  nextResponse = () => Promise.resolve(okResponse())
  el.morphTo(renderedEventShell())
  el.fire("panel:opened")
  await settle()
  expect(posts.length).toBe(2)
})

test("a morph re-arm and the early once-swallow do not interfere: one request for one event", async () => {
  nextResponse = () => Promise.reject(new Error("offline"))
  const el = makeRoot(renderedEventShell())
  queueEarly(el)
  const controller = connect(el)
  await settle()
  expect(posts.length).toBe(1)

  // Morph FIRST, while Stimulus's listener is still armed-but-spent: the next
  // event reaches both it (swallowed) and the re-armed listener (one request).
  const pending = gate()
  nextResponse = () => pending.promise
  el.morphTo(renderedEventShell())
  stimulusFires(controller)
  el.fire("panel:opened")
  await settle()
  expect(posts.length).toBe(2)

  pending.release()
  await settle()
  expect(posts.length).toBe(2)
})

test("after an early replay, a morph-back on the same element still gives exactly one request", async () => {
  const el = makeRoot(renderedEventShell())
  queueEarly(el)
  connect(el)
  await settle()
  expect(posts.length).toBe(1)

  // The load landed as an in-place morph to real content, then a page-refresh
  // morph turns the root back into the shell.
  el.morphTo(realContent())
  const pending = gate()
  nextResponse = () => pending.promise
  el.morphTo(renderedEventShell("morphed-token"))
  await settle()
  expect(posts.length).toBe(2)
  expect(posts[1]).toEqual({ token: "morphed-token", act: "__materialize", params: {} })

  pending.release()
  await settle()
  expect(posts.length).toBe(2)
})

// --- the defer module is itself loaded on demand (issue #275) --------------------
// reactive_lazy(on:) lives in a feature module. On the FIRST lazy root of a
// page the module is still on its way when the controller connects — and the
// shell's trigger can fire (or be replayed from before connect) in that gap.
// The core does the synchronous part at once and the load waits for the
// module: exactly one request, whatever fired, however often.

describe("while the defer module is still on its way", () => {
  // No feature module loaded — the opt-in phlex/reactive/core — and the
  // default entry's features handed back afterwards.
  beforeEach(() => coldFeatures(true))
  afterEach(() => coldFeatures())

  const moduleArrived = async (controller) => {
    await controller.featuresReady
    await settle()
  }

  test("an event fired three times before connect is replayed into exactly one request, after the import", async () => {
    const el = makeRoot(renderedEventShell())
    queueEarly(el, 3)

    const controller = connect(el)
    // Replayed inside connect() — the queue is drained — but nothing is sent yet.
    expect(globalThis[EARLY].queue).toEqual([])
    expect(posts).toEqual([])

    await moduleArrived(controller)
    expect(posts).toEqual([{ token: "shell-token", act: "__materialize", params: {} }])

    // Stimulus's `once` listener is still armed (the replay bypassed it).
    stimulusFires(controller)
    await settle()
    expect(posts.length).toBe(1)
  })

  test("a live event during the import is not lost and not duplicated", async () => {
    const pending = gate()
    nextResponse = () => pending.promise
    const controller = connect(makeRoot(renderedEventShell()))

    stimulusFires(controller)
    stimulusFires(controller)
    expect(posts).toEqual([])

    await moduleArrived(controller)
    expect(posts.length).toBe(1)
    pending.release()
    await settle()
    expect(posts.length).toBe(1)
  })

  test("a replayed event and a live one during the import still give one request", async () => {
    const el = makeRoot(renderedEventShell())
    queueEarly(el, 1)
    const controller = connect(el)
    stimulusFires(controller)

    await moduleArrived(controller)

    expect(posts.length).toBe(1)
  })

  test("a :visible shell is observed once the module arrives, and loads once", async () => {
    const el = makeRoot(visibleShell())
    const controller = connect(el)
    expect(observers.length).toBe(0)

    await moduleArrived(controller)
    expect(observers.length).toBe(1)
    observers[0].trigger(true)
    await settle()

    expect(posts.length).toBe(1)
  })

  test("a morph that turns real content into a shell loads the module and re-materializes once", async () => {
    const el = makeRoot(realContent())
    const controller = connect(el)
    await settle()
    expect(posts).toEqual([])

    el.morphTo(eventShell("morphed-token"))
    expect(posts).toEqual([])
    await moduleArrived(controller)

    expect(posts).toEqual([{ token: "morphed-token", act: "__materialize", params: {} }])
  })

  test("a morph from real content to real content imports nothing and requests nothing", async () => {
    const el = makeRoot(realContent())
    const controller = connect(el)
    const ready = controller.featuresReady

    el.morphTo(realContent("next-token"))
    await settle()

    // No scan hit: the shared, already-resolved promise is still in place.
    expect(controller.featuresReady).toBe(ready)
    expect(posts).toEqual([])
  })

  test("disconnect before the module arrives arms nothing and requests nothing", async () => {
    const el = makeRoot(visibleShell())
    const controller = connect(el)
    const ready = controller.featuresReady
    controller.disconnect()
    await ready
    await settle()

    expect(observers.length).toBe(0)
    expect(posts).toEqual([])
  })
})
