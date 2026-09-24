// Unit tests for CONDITIONAL confirm (issue #179) — confirm: as a Hash warns
// only when field values look suspect, evaluated client-side over the SAME
// collected fields reactive_compute reads:
//
//   * Declarative { groups, message }: the reactive_show conditions fold
//     (anyOfAllsMatches) over #collectFields — matches → prompt, no match → proceed.
//   * Named { predicate, message }: a registered fn over the collected fields —
//     truthy → prompt, falsy → proceed.
//   * An UNREGISTERED predicate name → warn + PROCEED without a dialog (the
//     compute unknown-reducer posture; the real gate is server authz).
//   * The static string confirm: is unchanged (always prompts).
//
// Observed through the confirmResolver seam (does the dialog fire?) and the fetch
// spy (does the action proceed?). Run with: bun test spec/javascript
import { test, expect, mock, beforeAll, beforeEach, afterAll } from "bun:test"

let ReactiveController
let confirmModule
let predicateModule

beforeAll(async () => {
  mock.module("@hotwired/stimulus", () => ({
    Controller: class {
      constructor() {}
    },
  }))
  ReactiveController = (await import("../../app/javascript/phlex/reactive/reactive_controller.js")).default
  confirmModule = await import("../../app/javascript/phlex/reactive/confirm.js")
  predicateModule = await import("../../app/javascript/phlex/reactive/confirm_predicate.js")
})

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

function makeTarget() {
  const listeners = {}
  return {
    addEventListener: (type, fn) => ((listeners[type] ||= []).push(fn)),
    removeEventListener: (type, fn) => (listeners[type] = (listeners[type] || []).filter((f) => f !== fn)),
    fire: (type) => (listeners[type] || []).slice().forEach((fn) => fn()),
  }
}

// A named text field the root "owns" (no nested reactive root → owns() is true).
function field(name, value) {
  return { tagName: "INPUT", type: "text", name, value, closest: () => null }
}

// Root whose querySelectorAll answers #collectFields' field query with our fields.
function makeRoot(fields = []) {
  return {
    querySelectorAll: (sel) => {
      if (sel === "input[name], select[name], textarea[name]") return fields
      return [] // no nested reactive roots (ownership filter → constant true)
    },
    setAttribute: () => {},
    removeAttribute: () => {},
    getAttribute: () => null,
  }
}

function buildController(fields = []) {
  const controller = new ReactiveController()
  controller.element = makeRoot(fields)
  controller.tokenValue = "tok"
  let calls = 0
  globalThis.fetch = () => {
    calls++
    return Promise.resolve({
      redirected: false,
      ok: true,
      headers: { get: () => "text/vnd.turbo-stream.html" },
      text: () => Promise.resolve(""),
    })
  }
  globalThis.document = { querySelector: () => null, dispatchEvent: () => {} }
  globalThis.window = { Turbo: { renderStreamMessage: () => {} } }
  return { controller, calls: () => calls }
}

// Record every message the resolver is asked to show; answer `answer`.
function recordConfirm(answer) {
  const seen = []
  confirmModule.setConfirmResolver((message) => {
    seen.push(message)
    return Promise.resolve(answer)
  })
  return seen
}

// DNF wire for `{ total: 0 }` (equals) — the shape ShowConditions emits.
const EQUALS_ZERO = { any: [[{ field: "total", equals: "0" }]] }

const nativeResolver = (message) =>
  Promise.resolve(typeof globalThis.window !== "undefined" ? globalThis.window.confirm(message) : true)

beforeEach(() => {
  confirmModule.setConfirmResolver(nativeResolver)
  predicateModule.__resetConfirmPredicateRegistryForTest()
})

// bun runs every spec/javascript file in one process and shares the module
// cache, so a recording resolver left installed here leaks into later files
// (reactive_confirm.test.js stubs window.confirm and would never see it called).
afterAll(() => confirmModule.setConfirmResolver(nativeResolver))

// --- declarative (conditions language) --------------------------------------

test("declarative: condition MATCHES (total is 0) → the dialog fires with the message", async () => {
  const { controller, calls } = buildController([field("total", "0")])
  const seen = recordConfirm(true)

  await controller.dispatch({
    target: makeTarget(),
    params: { action: "save", params: "{}", confirmWhen: JSON.stringify({ groups: EQUALS_ZERO, message: "Total is 0 — continue?" }) },
    preventDefault: () => {},
  })
  await wait(0)

  expect(seen).toEqual(["Total is 0 — continue?"]) // suspect → prompted
  expect(calls()).toBe(1) // accepted → proceeds
})

test("declarative: condition does NOT match (total is 5) → proceeds with NO dialog", async () => {
  const { controller, calls } = buildController([field("total", "5")])
  const seen = recordConfirm(false) // if the dialog wrongly fired, this would block

  await controller.dispatch({
    target: makeTarget(),
    params: { action: "save", params: "{}", confirmWhen: JSON.stringify({ groups: EQUALS_ZERO, message: "Total is 0 — continue?" }) },
    preventDefault: () => {},
  })
  await wait(0)

  expect(seen).toEqual([]) // clean values → never prompted
  expect(calls()).toBe(1) // proceeds straight through
})

test("declarative: MATCHES but the user declines → the action does NOT run", async () => {
  const { controller, calls } = buildController([field("total", "0")])
  recordConfirm(false)

  await controller.dispatch({
    target: makeTarget(),
    params: { action: "save", params: "{}", confirmWhen: JSON.stringify({ groups: EQUALS_ZERO, message: "?" }) },
    preventDefault: () => {},
  })
  await wait(0)

  expect(calls()).toBe(0) // suspect + declined → blocked
})

// --- named predicate --------------------------------------------------------

test("predicate: a registered fn that returns true → the dialog fires", async () => {
  predicateModule.setConfirmPredicate("end_before_start", ({ starts_at, ends_at }) => ends_at < starts_at)
  const { controller, calls } = buildController([field("starts_at", "2026-07-10"), field("ends_at", "2026-07-01")])
  const seen = recordConfirm(true)

  await controller.dispatch({
    target: makeTarget(),
    params: { action: "save", params: "{}", confirmWhen: JSON.stringify({ predicate: "end_before_start", message: "End precedes start — continue?" }) },
    preventDefault: () => {},
  })
  await wait(0)

  expect(seen).toEqual(["End precedes start — continue?"])
  expect(calls()).toBe(1)
})

test("predicate: a registered fn that returns false → proceeds with NO dialog", async () => {
  predicateModule.setConfirmPredicate("end_before_start", ({ starts_at, ends_at }) => ends_at < starts_at)
  const { controller, calls } = buildController([field("starts_at", "2026-07-01"), field("ends_at", "2026-07-10")])
  const seen = recordConfirm(false)

  await controller.dispatch({
    target: makeTarget(),
    params: { action: "save", params: "{}", confirmWhen: JSON.stringify({ predicate: "end_before_start", message: "?" }) },
    preventDefault: () => {},
  })
  await wait(0)

  expect(seen).toEqual([])
  expect(calls()).toBe(1)
})

test("predicate: an UNREGISTERED name → warns and PROCEEDS without a dialog (server authz is the real gate)", async () => {
  const { controller, calls } = buildController([field("total", "0")])
  const seen = recordConfirm(false) // a dialog would block; it must NOT fire
  const warns = []
  const origWarn = console.warn
  console.warn = (...a) => warns.push(a.join(" "))

  try {
    await controller.dispatch({
      target: makeTarget(),
      params: { action: "save", params: "{}", confirmWhen: JSON.stringify({ predicate: "never_registered", message: "?" }) },
      preventDefault: () => {},
    })
    await wait(0)
  } finally {
    console.warn = origWarn
  }

  expect(seen).toEqual([]) // no dialog
  expect(calls()).toBe(1) // proceeded
  expect(warns.join(" ")).toContain("never_registered")
})

// --- the static string form is unchanged ------------------------------------

test("a plain string confirm: still prompts unconditionally (issue #52 unchanged)", async () => {
  const { controller, calls } = buildController()
  const seen = recordConfirm(true)

  await controller.dispatch({
    target: makeTarget(),
    params: { action: "save", params: "{}", confirm: "Sure?" },
    preventDefault: () => {},
  })
  await wait(0)

  expect(seen).toEqual(["Sure?"])
  expect(calls()).toBe(1)
})

// Regression guard: Stimulus auto-parses a JSON-object -param value, so confirmWhen
// arrives as an OBJECT in a real browser (not a JSON string). The resolver must
// accept the object directly — an early JSON.parse(object) would throw and skip
// the gate (the action would run un-warned). Drive it with a parsed object here.
test("confirmWhen arrives as a parsed OBJECT (real Stimulus) — declarative still fires", async () => {
  const { controller, calls } = buildController([field("total", "0")])
  const seen = recordConfirm(true)

  await controller.dispatch({
    target: makeTarget(),
    params: { action: "save", params: "{}", confirmWhen: { groups: EQUALS_ZERO, message: "Total is 0 — continue?" } },
    preventDefault: () => {},
  })
  await wait(0)

  expect(seen).toEqual(["Total is 0 — continue?"])
  expect(calls()).toBe(1)
})

test("confirmWhen as a parsed OBJECT — named predicate still fires", async () => {
  predicateModule.setConfirmPredicate("end_before_start", ({ starts_at, ends_at }) => ends_at < starts_at)
  const { controller, calls } = buildController([field("starts_at", "2026-07-10"), field("ends_at", "2026-07-01")])
  const seen = recordConfirm(true)

  await controller.dispatch({
    target: makeTarget(),
    params: { action: "save", params: "{}", confirmWhen: { predicate: "end_before_start", message: "End precedes start — continue?" } },
    preventDefault: () => {},
  })
  await wait(0)

  expect(seen).toEqual(["End precedes start — continue?"])
  expect(calls()).toBe(1)
})
