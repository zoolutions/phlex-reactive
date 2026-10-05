// Unit tests for dismiss_after (issue #100): a flash carrying
// data-reactive-dismiss-after="<ms>" self-removes after the timeout. The
// removal is driven by a DOCUMENT-LEVEL handler (registered alongside
// registerReactiveVisit/registerReactiveToken), NOT a Stimulus controller — the
// flash container is a plain host-app div with no controller attached, so
// "the controller honors the attr" can't work. Because it's document-level and
// fires on turbo:before-stream-render, it self-cleans BOTH reply-delivered and
// broadcast-delivered flashes.
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeEach, afterEach } from "bun:test"

let registerReactiveDismiss
let __resetReactiveStreamRenderForTest

// A minimal element stub: records whether it was removed, and its own attrs.
function makeFlash(ms, { scheduled = false } = {}) {
  const attrs = { "data-reactive-dismiss-after": String(ms) }
  if (scheduled) attrs["data-reactive-dismiss-scheduled"] = ""
  const el = {
    removed: false,
    getAttribute: (name) => attrs[name] ?? null,
    setAttribute: (name, value) => (attrs[name] = String(value)),
    hasAttribute: (name) => name in attrs,
    remove: () => (el.removed = true),
  }
  return el
}

// A document stub whose querySelectorAll returns the given dismissing flashes,
// and whose addEventListener records document-level listeners so a test can fire
// turbo:before-stream-render manually. The handler WRAPS event.detail.render (the
// Turbo extension point): fire() builds an event with a stub render(), lets the
// handler wrap it, then invokes the wrapped render — mirroring how Turbo calls
// `await event.detail.render(this)` after the node is inserted. So the scan runs
// exactly once the streamed node exists.
function makeDocument(flashes) {
  const listeners = {}
  return {
    flashes,
    listeners,
    addEventListener: (name, fn) => ((listeners[name] ??= []).push(fn)),
    querySelectorAll: (sel) => (sel.includes("data-reactive-dismiss-after") ? flashes : []),
    // Returns a promise that resolves once the wrapped render (and thus the
    // scan) has run — a test awaits it before asserting.
    fire: async (name) => {
      const detail = { render: async () => {} } // Turbo's own stream render (stubbed)
      const event = { type: name, detail }
      ;(listeners[name] ?? []).forEach((fn) => fn(event))
      await detail.render() // Turbo invokes the (now-wrapped) render post-insert
    },
  }
}

// Per-test fake timers: capture scheduled callbacks so a test advances virtual
// time with drainTimers(ms) instead of a real wait. Restored in afterEach. The
// handler defers its scan with setTimeout(scan, 0); dismiss removals use
// setTimeout(remove, ms). dismissCount counts ONLY the ms>0 removal timers, so a
// test can assert "scheduled exactly once" independent of the 0ms deferral.
const realSetTimeout = globalThis.setTimeout
let pending = []
let dismissCount = 0
function installFakeTimers() {
  pending = []
  dismissCount = 0
  globalThis.setTimeout = (fn, ms) => {
    if (ms > 0) dismissCount++
    pending.push({ fn, ms })
    return pending.length
  }
}
// Run all due timers at <= uptoMs, repeatedly, so a 0ms deferral that itself
// schedules an ms>0 removal is fully drained in one call.
function drainTimers(uptoMs) {
  let ran = 0
  for (;;) {
    const due = pending.filter((t) => t.ms <= uptoMs)
    if (due.length === 0) break
    pending = pending.filter((t) => t.ms > uptoMs)
    due.forEach((t) => t.fn())
    ran += due.length
  }
  return ran
}

beforeEach(async () => {
  mock.module("@hotwired/stimulus", () => ({ Controller: class {} }))
  ;({ registerReactiveDismiss, __resetReactiveStreamRenderForTest } = await import(
    "../../app/javascript/phlex/reactive/reactive_controller.js"
  ))
  __resetReactiveStreamRenderForTest() // fresh registration per test (shared process)
  installFakeTimers()
})

afterEach(() => {
  globalThis.setTimeout = realSetTimeout
})

test("removes a dismissing flash after its timeout (fake timers)", async () => {
  const flash = makeFlash(4000)
  const doc = makeDocument([flash])
  globalThis.document = doc

  registerReactiveDismiss()
  await doc.fire("turbo:before-stream-render") // scan runs after Turbo's render resolves

  // Scheduled but not removed immediately — only after the timeout elapses.
  expect(flash.removed).toBe(false)

  expect(drainTimers(4000)).toBeGreaterThan(0)
  expect(flash.removed).toBe(true)
})

test("does NOT remove before the timeout elapses", async () => {
  const flash = makeFlash(4000)
  const doc = makeDocument([flash])
  globalThis.document = doc

  registerReactiveDismiss()
  await doc.fire("turbo:before-stream-render")

  drainTimers(3999) // one ms short
  expect(flash.removed).toBe(false)
})

test("schedules each dismissing flash exactly ONCE (idempotent across stream renders)", async () => {
  const flash = makeFlash(1000)
  const doc = makeDocument([flash])
  globalThis.document = doc

  registerReactiveDismiss()
  await doc.fire("turbo:before-stream-render")
  await doc.fire("turbo:before-stream-render") // a second stream render must NOT re-schedule
  await doc.fire("turbo:before-stream-render")

  expect(dismissCount).toBe(1)
  expect(flash.hasAttribute("data-reactive-dismiss-scheduled")).toBe(true)
})

test("skips a flash already marked scheduled (broadcast re-scan safety)", async () => {
  const flash = makeFlash(1000, { scheduled: true })
  const doc = makeDocument([flash])
  globalThis.document = doc

  registerReactiveDismiss()
  await doc.fire("turbo:before-stream-render")

  expect(dismissCount).toBe(0)
})

test("a non-numeric / zero dismiss-after is ignored (no scheduling, no removal)", async () => {
  const flash = makeFlash("nope")
  const doc = makeDocument([flash])
  globalThis.document = doc

  registerReactiveDismiss()
  await doc.fire("turbo:before-stream-render")
  drainTimers(100000)

  expect(dismissCount).toBe(0)
  expect(flash.removed).toBe(false)
})

test("registerReactiveDismiss is idempotent (a second call adds no second listener)", () => {
  const doc = makeDocument([])
  globalThis.document = doc

  registerReactiveDismiss()
  registerReactiveDismiss()

  expect(doc.listeners["turbo:before-stream-render"].length).toBe(1)
})
