// Unit test for #extractToken selecting THIS controller's own token (issue #46).
//
// After each action the controller stores the response's fresh token for its
// NEXT dispatch. On a collection of REACTIVE rows, an `add` response is, in body
// order:
//   1. <turbo-stream action="prepend|append" target="<container>"> whose
//      <template> root carries the NEW ROW's data-reactive-token-value, then
//   2. companions (e.g. a totals update), then
//   3. <turbo-stream action="reactive:token" target="<container>"
//      data-reactive-token-value="<fresh>"> — the CONTAINER's own fresh token.
//
// The old #extractToken grabbed the FIRST data-reactive-token-value in the body
// (the ROW's), so the list controller stored a row token. Its SECOND dispatch
// then sent a row token → failed verification → the add silently did nothing
// (add-once-only). This is the exact client mirror of the #44 server bug: "the
// token for component C is the one targeting C, not just any token in the body."
//
// The fix: #extractToken reads the token that RE-RENDERS this controller's own
// element id — preferring the dedicated reactive:token stream for it, then a
// self replace/update of it — never a child row's token at the container target.
//
// We drive two real dispatch()es: the first returns a crafted multi-stream body,
// the second must POST the CONTAINER's token, not the row's.
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll } from "bun:test"

let ReactiveController
let escapeRegExp

beforeAll(async () => {
  mock.module("@hotwired/stimulus", () => ({
    Controller: class {
      constructor() {}
    },
  }))
  const mod = await import("../../app/javascript/phlex/reactive/reactive_controller.js")
  ReactiveController = mod.default
  escapeRegExp = mod.escapeRegExp
})

// A reactive root faithful enough for #perform's needs: an id, an empty field
// walk (querySelectorAll -> []), and the attribute toggles. getAttribute returns
// the element's own live data-reactive-token-value when asked (so the DOM-reread
// fallback path, if any, sees the truth).
function fakeRoot(id) {
  const attrs = {}
  return {
    id,
    querySelectorAll: () => [],
    setAttribute: (name, value) => {
      attrs[name] = value
    },
    removeAttribute: (name) => {
      delete attrs[name]
    },
    getAttribute: (name) => attrs[name] ?? null,
  }
}

function buildController(rootEl, initialToken) {
  const controller = new ReactiveController()
  controller.element = rootEl
  controller.tokenValue = initialToken
  return controller
}

function stubEnv() {
  globalThis.document = {
    querySelector: (sel) => {
      if (sel.includes("action-path")) return { content: "/reactive/actions" }
      if (sel.includes("csrf-token")) return { content: "csrf-abc" }
      return null
    },
    dispatchEvent: () => {},
  }
  globalThis.window = { Turbo: { renderStreamMessage: () => {} } }
}

// Drive one dispatch whose fetch returns `body`; capture the JSON payload POSTed.
function stubFetchReturning(body, captured) {
  globalThis.fetch = (path, opts) => {
    captured.push(JSON.parse(opts.body))
    return Promise.resolve({
      redirected: false,
      ok: true,
      headers: { get: () => "text/vnd.turbo-stream.html" },
      text: () => Promise.resolve(body),
    })
  }
}

// The realistic add response on a collection of reactive rows: the prepended
// ROW carries its own token FIRST, the CONTAINER's reactive:token refresh LAST.
function collectionAddBody({ container, rowToken, containerToken }) {
  return (
    `<turbo-stream action="prepend" target="${container}">` +
    `<template><li id="row_99" data-controller="reactive" data-reactive-token-value="${rowToken}">new row</li></template>` +
    `</turbo-stream>` +
    `<turbo-stream action="update" target="${container}-totals"><template>1 item</template></turbo-stream>` +
    `<turbo-stream action="reactive:token" target="${container}" data-reactive-token-value="${containerToken}"></turbo-stream>`
  )
}

test("stores the CONTAINER's reactive:token, not the prepended row's token (issue #46)", async () => {
  const root = fakeRoot("reactive-rows")
  const controller = buildController(root, "TOKEN-INITIAL")
  stubEnv()

  const captured = []
  stubFetchReturning(
    collectionAddBody({ container: "reactive-rows", rowToken: "ROW-TOKEN", containerToken: "CONTAINER-FRESH" }),
    captured,
  )

  // First add: uses the initial token, response rolls the container token forward.
  await controller.dispatch({ params: { action: "add", params: "{}" }, preventDefault: () => {} })
  expect(captured[0].token).toBe("TOKEN-INITIAL")

  // Second add: MUST use the container's fresh token — NOT the row's (the bug).
  await controller.dispatch({ params: { action: "add", params: "{}" }, preventDefault: () => {} })
  expect(captured[1].token).toBe("CONTAINER-FRESH")
  expect(captured[1].token).not.toBe("ROW-TOKEN")
})

test("a self replace/update of this element supplies the next token", async () => {
  // The normal (non-collection) case: the action re-renders THIS root, and the
  // template root carries the fresh token. #extractToken must still pick it up.
  const root = fakeRoot("counter")
  const controller = buildController(root, "TOKEN-INITIAL")
  stubEnv()

  const body =
    `<turbo-stream action="replace" target="counter">` +
    `<template><div id="counter" data-controller="reactive" data-reactive-token-value="SELF-FRESH">1</div></template>` +
    `</turbo-stream>`

  const captured = []
  stubFetchReturning(body, captured)

  await controller.dispatch({ params: { action: "increment", params: "{}" }, preventDefault: () => {} })
  await controller.dispatch({ params: { action: "increment", params: "{}" }, preventDefault: () => {} })

  expect(captured[1].token).toBe("SELF-FRESH")
})

test("reads the self token from a morph replace (method before action attribute order)", async () => {
  // Response.morph emits `<turbo-stream method="morph" action="replace" target="id">`
  // — `method` sits BEFORE `action`. The self-stream match must still find it.
  const root = fakeRoot("counter")
  const controller = buildController(root, "TOKEN-INITIAL")
  stubEnv()

  const body =
    `<turbo-stream method="morph" action="replace" target="counter">` +
    `<template><div id="counter" data-controller="reactive" data-reactive-token-value="MORPH-FRESH">1</div></template>` +
    `</turbo-stream>`

  const captured = []
  stubFetchReturning(body, captured)

  await controller.dispatch({ params: { action: "increment", params: "{}" }, preventDefault: () => {} })
  await controller.dispatch({ params: { action: "increment", params: "{}" }, preventDefault: () => {} })

  expect(captured[1].token).toBe("MORPH-FRESH")
})

test("ignores a sibling component's token that targets a DIFFERENT id", async () => {
  // A partial reply may include ANOTHER reactive component's stream (carrying its
  // own token at a different target). That must NOT become our next token — only
  // a stream re-rendering OUR id counts. With no self-stream present, we keep the
  // existing token.
  const root = fakeRoot("my-id")
  const controller = buildController(root, "TOKEN-INITIAL")
  stubEnv()

  const body =
    `<turbo-stream action="replace" target="other-id">` +
    `<template><div id="other-id" data-reactive-token-value="OTHER-TOKEN">sibling</div></template>` +
    `</turbo-stream>`

  const captured = []
  stubFetchReturning(body, captured)

  await controller.dispatch({ params: { action: "ping", params: "{}" }, preventDefault: () => {} })
  await controller.dispatch({ params: { action: "ping", params: "{}" }, preventDefault: () => {} })

  // No stream re-rendered OUR id → keep the existing token, never adopt the sibling's.
  expect(captured[1].token).toBe("TOKEN-INITIAL")
  expect(captured[1].token).not.toBe("OTHER-TOKEN")
})

test("does NOT match a target whose id merely PREFIXES ours (exact id, not substring)", async () => {
  // Our id is "row"; a row component appended at target="row_99" carries its own
  // token. The regex anchors on target="row" + the closing quote, so target="row_99"
  // can't satisfy it — otherwise a sibling/child id that prefixes ours would leak.
  const root = fakeRoot("row")
  const controller = buildController(root, "TOKEN-INITIAL")
  stubEnv()

  const body =
    `<turbo-stream action="reactive:token" target="row_99" data-reactive-token-value="PREFIX-TOKEN"></turbo-stream>`

  const captured = []
  stubFetchReturning(body, captured)

  await controller.dispatch({ params: { action: "go", params: "{}" }, preventDefault: () => {} })
  await controller.dispatch({ params: { action: "go", params: "{}" }, preventDefault: () => {} })

  expect(captured[1].token).toBe("TOKEN-INITIAL")
  expect(captured[1].token).not.toBe("PREFIX-TOKEN")
})

test("matches an id containing regex metacharacters (escapeRegExp)", async () => {
  // A dom id can contain regex metacharacters (e.g. a dotted/namespaced id).
  // escapeRegExp keeps the target match literal so the self-token is still found.
  const id = "list.items:42"
  const root = fakeRoot(id)
  const controller = buildController(root, "TOKEN-INITIAL")
  stubEnv()

  const body =
    `<turbo-stream action="reactive:token" target="${id}" data-reactive-token-value="DOTTED-FRESH"></turbo-stream>`

  const captured = []
  stubFetchReturning(body, captured)

  await controller.dispatch({ params: { action: "go", params: "{}" }, preventDefault: () => {} })
  await controller.dispatch({ params: { action: "go", params: "{}" }, preventDefault: () => {} })

  expect(captured[1].token).toBe("DOTTED-FRESH")
})

test("re-render under a NEW id self-matches the new id — memoized regexes never serve stale (issue #118)", async () => {
  // #extractToken compiles two per-id RegExps (the reactive:token and the self
  // replace/update matchers). They're memoized on the instance keyed on
  // this.element.id (issue #118) — so a stable id compiles them ONCE across many
  // responses. The correctness guard: if the root's id CHANGES (a re-render that
  // re-identifies the element), the memo MUST rebuild for the new id, or the next
  // extraction would scan for the OLD target and miss the new self-token,
  // freezing the token forever. A memo keyed on nothing (regex cached once,
  // ignoring the id) makes this test RED: the beta dispatch keeps ALPHA's token.
  const root = fakeRoot("alpha")
  const controller = buildController(root, "TOKEN-INITIAL")
  stubEnv()

  // A mutable body holder so each dispatch can return a body targeting the id in
  // force at that moment (the file's stubFetchReturning captures a fixed body).
  let body = ""
  const captured = []
  globalThis.fetch = (path, opts) => {
    captured.push(JSON.parse(opts.body))
    return Promise.resolve({
      redirected: false,
      ok: true,
      headers: { get: () => "text/vnd.turbo-stream.html" },
      text: () => Promise.resolve(body),
    })
  }

  // First response re-renders id="alpha" and rolls its token to ALPHA-FRESH.
  // This compiles (and memoizes) the alpha-keyed regexes.
  body =
    `<turbo-stream action="replace" target="alpha">` +
    `<template><div id="alpha" data-controller="reactive" data-reactive-token-value="ALPHA-FRESH">a</div></template>` +
    `</turbo-stream>`
  await controller.dispatch({ params: { action: "go", params: "{}" }, preventDefault: () => {} })
  expect(captured[0].token).toBe("TOKEN-INITIAL")

  // The root is re-identified to "beta" (a new id lands on this.element). The next
  // response re-renders id="beta" — so #extractToken must scan for target="beta".
  // The second POST carries the FIRST response's fresh token (ALPHA-FRESH); its
  // response then rolls the token to BETA-FRESH — but ONLY if the memo rebuilt for
  // the new id. A stale (alpha-keyed) regex misses the beta-targeted stream and
  // returns undefined, freezing the token at ALPHA-FRESH.
  root.id = "beta"
  body =
    `<turbo-stream action="replace" target="beta">` +
    `<template><div id="beta" data-controller="reactive" data-reactive-token-value="BETA-FRESH">b</div></template>` +
    `</turbo-stream>`
  await controller.dispatch({ params: { action: "go", params: "{}" }, preventDefault: () => {} })
  expect(captured[1].token).toBe("ALPHA-FRESH") // second POST used the first response's fresh token

  // The THIRD POST must carry BETA-FRESH — proof the memo rebuilt for the new id.
  await controller.dispatch({ params: { action: "go", params: "{}" }, preventDefault: () => {} })
  expect(captured[2].token).toBe("BETA-FRESH")
})

test("escapeRegExp escapes regex metacharacters", () => {
  expect(escapeRegExp("a.b:c")).toBe("a\\.b:c")
  expect(escapeRegExp("x+y*z")).toBe("x\\+y\\*z")
  expect(escapeRegExp("plain")).toBe("plain")
})

// Issue #301: a morph from OUTSIDE the controller's own reply (a broadcast, a
// page refresh, a dormant morph-back) rewrites data-reactive-token-value in
// place — the element and its controller survive — so the token cached from the
// last reply must yield to the one the morph brought. Stimulus calls
// tokenValueChanged on that attribute change (and on a reconnect after one);
// Stimulus is mocked here, so this drives that callback contract by hand.
test("a token the morph brought wins over the one cached from the last reply (issue #301)", async () => {
  const root = fakeRoot("counter")
  const controller = buildController(root, "TOKEN-INITIAL")
  stubEnv()

  const body =
    `<turbo-stream action="replace" method="morph" target="counter">` +
    `<template><div id="counter" data-controller="reactive" data-reactive-token-value="REPLY-FRESH">1</div></template>` +
    `</turbo-stream>`
  const captured = []
  stubFetchReturning(body, captured)
  await controller.dispatch({ params: { action: "bump", params: "{}" }, preventDefault: () => {} })
  expect(captured[0].token).toBe("TOKEN-INITIAL")

  controller.tokenValue = "MORPHED-IN"
  controller.tokenValueChanged("MORPHED-IN", "REPLY-FRESH")

  await controller.dispatch({ params: { action: "bump", params: "{}" }, preventDefault: () => {} })
  expect(captured[1].token).toBe("MORPHED-IN")
})
