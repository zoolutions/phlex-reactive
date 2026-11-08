// Unit test for the `reactive:token` custom turbo-stream action (issue #30).
// A partial update (Response.streams / reply.streams) re-renders only PART of a
// component, so there's no full-self replace to carry the next signed token. The
// server emits <turbo-stream action="reactive:token" target="<id>"
// data-reactive-token-value="<fresh>">; the client writes the fresh token onto
// the root element — a PURE ATTRIBUTE SET (no node replacement), so a focused
// <input> + caret survive.
//
// We call the exported registerReactiveToken() explicitly (same rationale as the
// reactive:visit test — bun runs all spec/javascript files in one process).
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll, beforeEach, afterAll } from "bun:test"

let registerReactiveToken
let elements
const SAVED = {}

function fakeElement() {
  const attrs = {}
  return {
    attrs,
    setAttribute: (name, value) => {
      attrs[name] = value
    },
    getAttribute: (name) => attrs[name] ?? null,
  }
}

beforeAll(() => {
  SAVED.window = globalThis.window
  SAVED.document = globalThis.document
})

// The first import of the runtime with a window and a document schedules its registration
// check (setTimeout 0). Run it here, against this file's stub, before putting the globals
// back: left pending, it fires in the next file against whatever document is current then.
afterAll(async () => {
  await new Promise((resolve) => setTimeout(resolve, 0))
  for (const key of ["window", "document"]) {
    if (SAVED[key] === undefined) delete globalThis[key]
    else globalThis[key] = SAVED[key]
  }
})

beforeEach(async () => {
  mock.module("@hotwired/stimulus", () => ({ Controller: class {} }))
  elements = {}
  globalThis.window = { Turbo: { StreamActions: {} } }
  globalThis.document = {
    getElementById: (id) => elements[id] ?? null,
    querySelectorAll: () => [],
  }
  ;({ registerReactiveToken } = await import("../../app/javascript/phlex/reactive/reactive_controller.js"))
  registerReactiveToken()
})

test("registers a reactive:token StreamAction on window.Turbo", () => {
  expect(typeof window.Turbo.StreamActions["reactive:token"]).toBe("function")
})

test("reactive:token writes the fresh token onto the targeted root element", () => {
  const root = fakeElement()
  root.setAttribute("data-reactive-token-value", "OLD")
  elements["counter"] = root

  const stream = {
    getAttribute: (name) =>
      ({ "data-reactive-token-value": "FRESH", target: "counter" }[name] ?? null),
  }
  window.Turbo.StreamActions["reactive:token"].call(stream)

  // Pure attribute set — the element object is the SAME node (focus preserved),
  // only its token attribute changed.
  expect(root.getAttribute("data-reactive-token-value")).toBe("FRESH")
})

test("reactive:token with a missing target does nothing (no throw)", () => {
  const stream = {
    getAttribute: (name) => (name === "data-reactive-token-value" ? "FRESH" : null),
  }
  expect(() => window.Turbo.StreamActions["reactive:token"].call(stream)).not.toThrow()
})

test("reactive:token with no token does nothing", () => {
  const root = fakeElement()
  root.setAttribute("data-reactive-token-value", "OLD")
  elements["counter"] = root

  const stream = { getAttribute: (name) => (name === "target" ? "counter" : null) }
  window.Turbo.StreamActions["reactive:token"].call(stream)

  expect(root.getAttribute("data-reactive-token-value")).toBe("OLD")
})
