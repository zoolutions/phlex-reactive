// Unit tests for reactive effects (issue #215): the document-level
// turbo:before-stream-render interceptor that animates enter (append/prepend),
// exit (remove) and update (replace/update) stream renders. Wire contract:
// per-call data-reactive-effect on the <turbo-stream> ("off" suppresses) beats
// the carrier element's data-reactive-effect-<hook>; named effects map to
// reactive-fx--<name>-<hook> classes; "["-prefixed values are custom
// [during, from, to] class legs. Exit DELAYS Turbo's render until the effect
// settles (animationend/transitionend or the timeout fallback) — and a ZERO
// computed duration (no effects CSS loaded) must skip the wait entirely so a
// missing stylesheet never freezes a removal.
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeEach, afterEach } from "bun:test"
import { Window } from "happy-dom"

let registerReactiveEffects
let __resetReactiveStreamRenderForTest
let registerReactiveDismiss

let window

// Fake timers (the dismiss-test pattern): capture callbacks, advance virtual
// time with drainTimers. The settle fallback and dismiss scheduling both ride
// setTimeout, so tests never really wait.
const realSetTimeout = globalThis.setTimeout
const realClearTimeout = globalThis.clearTimeout
let pending = []
let nextTimerId = 0
function installFakeTimers() {
  pending = []
  globalThis.setTimeout = (fn, ms) => {
    const id = ++nextTimerId
    pending.push({ fn, ms, id })
    return id
  }
  globalThis.clearTimeout = (id) => {
    pending = pending.filter((t) => t.id !== id)
  }
}
function drainTimers(uptoMs) {
  for (;;) {
    const due = pending.filter((t) => t.ms <= uptoMs)
    if (due.length === 0) break
    pending = pending.filter((t) => t.ms > uptoMs)
    due.forEach((t) => t.fn())
  }
}

// console.warn spy (unknown-effect default-deny assertions).
const realWarn = console.warn
let warns = []

beforeEach(async () => {
  mock.module("@hotwired/stimulus", () => ({ Controller: class {} }))
  ;({
    registerReactiveEffects,
    __resetReactiveStreamRenderForTest,
    registerReactiveDismiss,
  } = await import("../../app/javascript/phlex/reactive/reactive_controller.js"))

  window = new Window()
  globalThis.document = window.document
  globalThis.CustomEvent = window.CustomEvent
  // Synchronous rAF: the legs choreography awaits one frame between from→to.
  globalThis.requestAnimationFrame = (fn) => {
    fn()
    return 0
  }
  // Per-element computed style: elements opt into an animation duration via a
  // test attribute, mirroring "the effects CSS gives this class a duration".
  globalThis.getComputedStyle = (el) => ({
    animationDuration: el.getAttribute?.("data-test-duration") ?? "0s",
    animationDelay: "0s",
    transitionDuration: "0s",
    transitionDelay: "0s",
  })
  globalThis.matchMedia = () => ({ matches: false })
  warns = []
  console.warn = (...args) => warns.push(args.join(" "))
  installFakeTimers()
  __resetReactiveStreamRenderForTest()
  registerReactiveEffects()
})

afterEach(() => {
  globalThis.setTimeout = realSetTimeout
  globalThis.clearTimeout = realClearTimeout
  delete globalThis.cancelAnimationFrame
  console.warn = realWarn
})

// Build a <turbo-stream> element. `content` becomes the <template> innerHTML.
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

// Fire turbo:before-stream-render the way Turbo does (detail.newStream + a
// detail.render the interceptor may wrap), then hand back the detail so the
// test invokes the (possibly wrapped) render like Turbo would. The ONE
// listener always adds the dismiss wrapper; a stream the effects left alone
// is one whose render carries no __reactiveEffectsWrapped marker.
function fire(stream, render) {
  const detail = { render, newStream: stream }
  document.dispatchEvent(new window.CustomEvent("turbo:before-stream-render", { detail }))
  return detail
}

function addTarget(id, attrs = {}) {
  const el = document.createElement("div")
  el.id = id
  for (const [name, value] of Object.entries(attrs)) el.setAttribute(name, value)
  document.body.appendChild(el)
  return el
}

test("exit: delays Turbo's render until animationend, with the effect class applied", async () => {
  const el = addTarget("row", { "data-reactive-effect-exit": "fade", "data-test-duration": "0.2s" })
  let removed = false
  const detail = fire(makeStream("remove", "row"), async () => {
    removed = true
    el.remove()
  })

  const done = detail.render(detail.newStream)
  expect(el.classList.contains("reactive-fx--fade-exit")).toBe(true)
  expect(removed).toBe(false) // still animating — removal must wait

  el.dispatchEvent(new window.Event("animationend"))
  await done
  expect(removed).toBe(true)
})

test("exit: the timeout fallback still removes when animationend never fires", async () => {
  addTarget("row", { "data-reactive-effect-exit": "fade", "data-test-duration": "0.2s" })
  let removed = false
  const detail = fire(makeStream("remove", "row"), async () => {
    removed = true
  })

  const done = detail.render(detail.newStream)
  expect(removed).toBe(false)
  drainTimers(2000) // no animationend — the fallback timer settles it
  await done
  expect(removed).toBe(true)
})

test("exit: zero computed duration (no effects CSS) renders immediately — no dead wait", async () => {
  const el = addTarget("row", { "data-reactive-effect-exit": "fade" }) // no data-test-duration → 0s
  let removed = false
  const detail = fire(makeStream("remove", "row"), async () => {
    removed = true
  })

  await detail.render(detail.newStream) // resolves without any timer draining
  expect(removed).toBe(true)
  expect(el.classList.contains("reactive-fx--fade-exit")).toBe(false) // cleaned up
})

test("per-call data-reactive-effect beats the carrier's declared hook", async () => {
  const el = addTarget("row", { "data-reactive-effect-exit": "fade", "data-test-duration": "0.2s" })
  const detail = fire(makeStream("remove", "row", { effect: "shake" }), async () => {})

  const done = detail.render(detail.newStream)
  expect(el.classList.contains("reactive-fx--shake-exit")).toBe(true)
  expect(el.classList.contains("reactive-fx--fade-exit")).toBe(false)
  drainTimers(2000)
  await done
})

test('per-call "off" suppresses a declared effect (render untouched)', () => {
  addTarget("row", { "data-reactive-effect-exit": "fade", "data-test-duration": "0.2s" })
  const render = async () => {}
  const detail = fire(makeStream("remove", "row", { effect: "off" }), render)
  expect(detail.render.__reactiveEffectsWrapped).toBeUndefined() // never wrapped
})

test("enter: the inserted clone gets the class post-render and the marker is cleared", async () => {
  const container = addTarget("list")
  const stream = makeStream("append", "list", {
    content: '<li id="item_1" data-reactive-effect-enter="slide" data-test-duration="0.3s">x</li>',
  })
  // Turbo-faithful stub: clone the template content into the target.
  const detail = fire(stream, async () => {
    container.appendChild(stream.querySelector("template").content.cloneNode(true))
  })

  await detail.render(stream)
  const inserted = container.querySelector("#item_1")
  expect(inserted.classList.contains("reactive-fx--slide-enter")).toBe(true)
  expect(inserted.hasAttribute("data-reactive-fx-pending")).toBe(false)

  inserted.dispatchEvent(new window.Event("animationend"))
  await Promise.resolve() // let the settle .then run
  expect(inserted.classList.contains("reactive-fx--slide-enter")).toBe(false)
})

test("update: the target flashes post-render and a re-application restarts it", async () => {
  const el = addTarget("card", {
    "data-reactive-effect-update": "highlight",
    "data-test-duration": "0.4s",
  })
  const detail = fire(makeStream("replace", "card"), async () => {})
  await detail.render(detail.newStream)
  expect(el.classList.contains("reactive-fx--highlight-update")).toBe(true)

  // A second update while the first is still animating restarts, not stacks.
  const second = fire(makeStream("replace", "card"), async () => {})
  await second.render(second.newStream)
  expect(el.classList.contains("reactive-fx--highlight-update")).toBe(true)
})

test("legs: exit runs during+from → to, settles, and cleans every leg up", async () => {
  const el = addTarget("row", { "data-test-duration": "0.2s" })
  const legs = JSON.stringify(["fx-during", "fx-from", "fx-to"])
  let removed = false
  const detail = fire(makeStream("remove", "row", { effect: legs }), async () => {
    removed = true
  })

  const done = detail.render(detail.newStream)
  // The frame await resolves synchronously (stubbed rAF) but its continuation
  // is a microtask — flush with a real macrotask before asserting mid-flight.
  await new Promise((resolve) => realSetTimeout(resolve, 0))
  expect(el.classList.contains("fx-during")).toBe(true)
  expect(el.classList.contains("fx-from")).toBe(false)
  expect(el.classList.contains("fx-to")).toBe(true)
  expect(removed).toBe(false)

  el.dispatchEvent(new window.Event("transitionend"))
  await done
  expect(removed).toBe(true)
  expect(el.classList.contains("fx-during")).toBe(false)
  expect(el.classList.contains("fx-to")).toBe(false)
})

test("legs: a rapid re-application restarts — a stale settle can't strip the newer run's classes", async () => {
  const el = addTarget("card", { "data-test-duration": "0.2s" })
  const legs = JSON.stringify(["fx-during", "fx-from", "fx-to"])
  const tick = () => new Promise((resolve) => realSetTimeout(resolve, 0))

  // Manual frame control for THIS test: capture rAF callbacks so each run can
  // be frozen mid-choreography (the suite default invokes them synchronously).
  const frames = []
  globalThis.requestAnimationFrame = (fn) => frames.push(fn)

  // Run 1: applies during+from, suspends awaiting its frame.
  const first = fire(makeStream("replace", "card", { effect: legs }), async () => {})
  await first.render(first.newStream)
  frames.shift()() // frame 1 → run 1 swaps from→to and registers its settle listeners
  await tick()
  expect(el.classList.contains("fx-to")).toBe(true)

  // Run 2: takes the token, clears run 1's classes, re-applies during+from,
  // and suspends at ITS frame — settle listeners NOT yet registered.
  const second = fire(makeStream("replace", "card", { effect: legs }), async () => {})
  await second.render(second.newStream)
  expect(el.classList.contains("fx-from")).toBe(true)

  // This transitionend settles ONLY the stale run 1 — whose cleanup must now
  // be a no-op (the token guard), leaving run 2's mid-flight classes alone.
  el.dispatchEvent(new window.Event("transitionend"))
  await tick()
  expect(el.classList.contains("fx-during")).toBe(true)
  expect(el.classList.contains("fx-from")).toBe(true)

  // Let run 2 finish normally: its frame swaps from→to, its settle cleans up.
  frames.shift()()
  await tick()
  el.dispatchEvent(new window.Event("transitionend"))
  await tick()
  expect(el.classList.contains("fx-during")).toBe(false)
  expect(el.classList.contains("fx-to")).toBe(false)
})

test('"random" resolves to one of the shipped built-ins', () => {
  const el = addTarget("row", { "data-test-duration": "0.2s" })
  const detail = fire(makeStream("remove", "row", { effect: "random" }), async () => {})
  detail.render(detail.newStream)
  const applied = Array.from(el.classList).filter((cls) => cls.startsWith("reactive-fx--"))
  expect(applied.length).toBe(1)
  expect(applied[0]).toMatch(/^reactive-fx--(fade|slide|scale|highlight|shake)-exit$/)
  drainTimers(2000)
})

test("prefers-reduced-motion disables everything (render untouched)", () => {
  globalThis.matchMedia = () => ({ matches: true })
  addTarget("row", { "data-reactive-effect-exit": "fade", "data-test-duration": "0.2s" })
  const render = async () => {}
  const detail = fire(makeStream("remove", "row"), render)
  expect(detail.render.__reactiveEffectsWrapped).toBeUndefined()
})

test("unknown effect name warns and skips (client-side default-deny)", () => {
  addTarget("row", { "data-test-duration": "0.2s" })
  const render = async () => {}
  const detail = fire(makeStream("remove", "row", { effect: "sparkle" }), render)
  expect(detail.render.__reactiveEffectsWrapped).toBeUndefined()
  expect(warns.join(" ")).toContain("sparkle")
})

test("malformed legs JSON warns and skips", () => {
  addTarget("row", { "data-test-duration": "0.2s" })
  const render = async () => {}
  const detail = fire(makeStream("remove", "row", { effect: "[broken" }), render)
  expect(detail.render.__reactiveEffectsWrapped).toBeUndefined()
  expect(warns.join(" ")).toContain("legs")
})

test("reactive:* and unknown actions are never wrapped", () => {
  addTarget("row", { "data-reactive-effect-exit": "fade", "data-test-duration": "0.2s" })
  const render = async () => {}
  expect(fire(makeStream("reactive:token", "row"), render).render.__reactiveEffectsWrapped).toBeUndefined()
  expect(fire(makeStream("reactive:js", "row"), render).render.__reactiveEffectsWrapped).toBeUndefined()
})

test("a stream with no per-call attr and no carrier declaration passes through", () => {
  addTarget("plain")
  const render = async () => {}
  const detail = fire(makeStream("replace", "plain"), render)
  expect(detail.render.__reactiveEffectsWrapped).toBeUndefined()
})

test("chains with the dismiss wrapper — both run on one stream render", async () => {
  // (One listener serves both since issue #275; beforeEach registered it.)
  const el = addTarget("card", {
    "data-reactive-effect-update": "highlight",
    "data-test-duration": "0.2s",
  })
  const flash = document.createElement("div")
  flash.setAttribute("data-reactive-dismiss-after", "3000")
  document.body.appendChild(flash)

  const detail = fire(makeStream("replace", "card"), async () => {})
  await detail.render(detail.newStream)
  drainTimers(0) // the dismiss scan defers with setTimeout(0) on stub paths

  expect(el.classList.contains("reactive-fx--highlight-update")).toBe(true)
  expect(flash.hasAttribute("data-reactive-dismiss-scheduled")).toBe(true)
})

test("registerReactiveEffects is idempotent (one listener)", () => {
  // A second call must not double-wrap: fire once and count how many times the
  // render identity changes. With a single listener the wrap happens once and
  // carries the wrapped marker, so a duplicate listener would be a no-op too —
  // assert via the marker instead of listener internals.
  registerReactiveEffects()
  addTarget("row", { "data-reactive-effect-exit": "fade", "data-test-duration": "0.2s" })
  const detail = fire(makeStream("remove", "row"), async () => {})
  expect(detail.render.__reactiveEffectsWrapped).toBe(true)
})

test("legs exit in a background tab: a frame that never comes can't hold the removal (#295)", async () => {
  addTarget("row", { "data-test-duration": "0.2s" })
  globalThis.requestAnimationFrame = () => 0 // a hidden tab: rAF never fires
  const tick = () => new Promise((resolve) => realSetTimeout(resolve, 0))
  let removed = false
  const legs = JSON.stringify(["fx-during", "fx-from", "fx-to"])
  const detail = fire(makeStream("remove", "row", { effect: legs }), async () => {
    removed = true
  })

  const done = detail.render(detail.newStream)
  drainTimers(1000) // the frame wait's fallback
  await tick()
  drainTimers(1000) // the settle fallback
  await tick()
  expect(removed).toBe(true) // asserted before awaiting, so RED fails fast instead of hanging
  await done
})

test("legs: the frame wait's fallback never beats a pending frame in a visible tab (#295)", async () => {
  const el = addTarget("row", { "data-test-duration": "0.2s" })
  globalThis.requestAnimationFrame = () => 0 // a frame is pending, not yet run
  const legs = JSON.stringify(["fx-during", "fx-from", "fx-to"])
  const detail = fire(makeStream("remove", "row", { effect: legs }), async () => {})

  detail.render(detail.newStream)
  drainTimers(999) // a short fallback would swap from→to before `from` paints
  await new Promise((resolve) => realSetTimeout(resolve, 0))
  expect(el.classList.contains("fx-from")).toBe(true)
  expect(el.classList.contains("fx-to")).toBe(false)
})

test("legs: a frame that runs clears the frame wait's fallback timer (#295)", async () => {
  addTarget("row", { "data-test-duration": "0.2s" })
  const legs = JSON.stringify(["fx-during", "fx-from", "fx-to"])
  const detail = fire(makeStream("replace", "row", { effect: legs }), async () => {})

  await detail.render(detail.newStream) // the suite's rAF runs synchronously
  await new Promise((resolve) => realSetTimeout(resolve, 0))
  expect(pending.some((t) => t.ms === 1000)).toBe(false) // only the 250ms settle timer remains
})

test("legs: a fallback that wins cancels the frame still pending (#295)", async () => {
  addTarget("row", { "data-test-duration": "0.2s" })
  globalThis.requestAnimationFrame = () => 42 // a hidden tab: rAF never fires
  const canceled = []
  globalThis.cancelAnimationFrame = (id) => canceled.push(id)
  const legs = JSON.stringify(["fx-during", "fx-from", "fx-to"])
  const detail = fire(makeStream("replace", "row", { effect: legs }), async () => {})

  await detail.render(detail.newStream)
  drainTimers(1000) // the frame wait's fallback
  expect(canceled).toEqual([42])
})

test("update: a descendant's bubbling transitionend doesn't settle the container's effect (#296)", async () => {
  const el = addTarget("card", { "data-reactive-effect-update": "highlight", "data-test-duration": "0.4s" })
  const child = document.createElement("span")
  el.appendChild(child)
  const detail = fire(makeStream("replace", "card"), async () => {})
  await detail.render(detail.newStream)
  expect(el.classList.contains("reactive-fx--highlight-update")).toBe(true)

  child.dispatchEvent(new window.Event("transitionend", { bubbles: true }))
  await Promise.resolve()
  expect(el.classList.contains("reactive-fx--highlight-update")).toBe(true) // the child's, not ours

  el.dispatchEvent(new window.Event("animationend"))
  await Promise.resolve()
  expect(el.classList.contains("reactive-fx--highlight-update")).toBe(false)
})

test("a settled effect leaves neither end listener behind (#296)", async () => {
  const el = addTarget("card", { "data-reactive-effect-update": "highlight", "data-test-duration": "0.4s" })
  const live = new Set()
  const add = el.addEventListener.bind(el)
  const remove = el.removeEventListener.bind(el)
  el.addEventListener = (type, fn, opts) => {
    live.add(`${type}`)
    add(type, fn, opts)
  }
  el.removeEventListener = (type, fn, opts) => {
    live.delete(`${type}`)
    remove(type, fn, opts)
  }
  const detail = fire(makeStream("replace", "card"), async () => {})
  await detail.render(detail.newStream)
  expect(live.size).toBe(2)

  el.dispatchEvent(new window.Event("animationend"))
  await Promise.resolve()
  expect(el.classList.contains("reactive-fx--highlight-update")).toBe(false)
  expect([...live]).toEqual([])
})
