// Unit tests for the `reactive:defer` custom Turbo StreamAction (issue #165) —
// the client half of deferred reply segments. The server emits
//
//   <turbo-stream action="reactive:defer" target="<id>"
//                 data-reactive-defer-via="fetch"
//                 data-reactive-defer-token="<signed>"></turbo-stream>
//
// and the handler must:
//   * mark the target pending (data-reactive-defer-pending + aria-busy),
//   * POST the token to the defer endpoint OFF the per-controller action queue
//     (a module-level fetch — the whole point is not blocking the next action),
//   * apply the arriving turbo-stream ONLY if this defer is still current
//     (supersession: a newer directive for the same target aborts the older),
//   * clear pending on 204 (render? false — keep content),
//   * mark data-reactive-error="defer" + emit reactive:error (with retry) on
//     failure,
//   * on the push lane (via="stream"), insert a <pgbus-stream-source> whose
//     removal is the broadcast's own job (the payload carries the remove).
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll, beforeEach } from "bun:test"

let registerReactiveDefer
let resetReactiveDefers
let pendingDeferVia

beforeAll(async () => {
  mock.module("@hotwired/stimulus", () => ({
    Controller: class {
      constructor() {}
    },
  }))
  const mod = await import("../../app/javascript/phlex/reactive/reactive_controller.js")
  // The opt-in entry: it tells the shared runtime where each feature module
  // lives, which the load-up-front seam below goes through.
  await import("../../app/javascript/phlex/reactive/core.js")
  registerReactiveDefer = mod.registerReactiveDefer
  // The defer code is a feature module (issue #275). Loaded up front here, so
  // the core's `reactive:defer` stream action reaches it in the same tick — the
  // not-yet-loaded path has its own tests in reactive_features.test.js.
  const defer = await mod.__loadReactiveFeatureForTest("defer")
  resetReactiveDefers = defer.resetReactiveDefers
  pendingDeferVia = defer.pendingDeferVia
})

function getPendingDeferVia(id) {
  return pendingDeferVia(id)
}

beforeEach(() => {
  resetReactiveDefers()
  // Reset cross-test global state (bun runs all files in one process).
  delete globalThis.customElements
})

// A controllable promise, so tests decide exactly when a fetch settles.
function deferred() {
  let resolve, reject
  const promise = new Promise((res, rej) => ((resolve = res), (reject = rej)))
  return { promise, resolve, reject }
}

function makeTargetEl(id) {
  const el = {
    id,
    attrs: {},
    dispatched: [],
    setAttribute(name, value) {
      el.attrs[name] = value
    },
    removeAttribute(name) {
      delete el.attrs[name]
    },
    getAttribute(name) {
      return el.attrs[name] ?? null
    },
    dispatchEvent(event) {
      el.dispatched.push(event)
    },
  }
  return el
}

// Fake document: getElementById from a map, querySelector for metas, plus
// createElement/body.appendChild recording for the stream lane.
function stubDocument({ byId = {}, metas = {} } = {}) {
  const created = []
  const appended = []
  const listeners = {}
  globalThis.document = {
    getElementById: (id) => byId[id] ?? null,
    querySelector: (sel) => {
      const name = sel.match(/meta\[name="([^"]+)"\]/)?.[1]
      return name && metas[name] != null ? { content: metas[name] } : null
    },
    createElement: (tag) => {
      const el = makeTargetEl(null)
      el.tagName = tag
      el.removed = false
      el.remove = () => {
        el.removed = true
        if (el.id) delete byId[el.id]
      }
      created.push(el)
      return el
    },
    // Appending a source element registers it by id, so supersedeDefer can
    // re-find it (the real code no longer holds a strong ref to it).
    body: {
      appendChild: (el) => {
        appended.push(el)
        if (el.id) byId[el.id] = el
      },
    },
    addEventListener: (name, fn) => (listeners[name] = fn),
  }
  return { created, appended, listeners, byId }
}

function stubTurbo() {
  const rendered = []
  globalThis.window = {
    Turbo: {
      StreamActions: {},
      renderStreamMessage: (html) => rendered.push(html),
    },
  }
  return { actions: globalThis.window.Turbo.StreamActions, rendered }
}

function stubFetch() {
  const calls = []
  globalThis.fetch = (url, options) => {
    const gate = deferred()
    calls.push({ url, options, gate })
    return gate.promise
  }
  return calls
}

// A fake <turbo-stream action="reactive:defer"> element.
function directiveEl({ target, token = "signed-defer-token", via = "fetch", src, sinceId } = {}) {
  const attrs = { target, "data-reactive-defer-via": via }
  if (token != null) attrs["data-reactive-defer-token"] = token
  if (src != null) attrs["data-reactive-defer-src"] = src
  if (sinceId != null) attrs["data-reactive-defer-since-id"] = sinceId
  return { getAttribute: (name) => attrs[name] ?? null }
}

function okResponse(html) {
  return {
    ok: true,
    status: 200,
    headers: { get: () => "text/vnd.turbo-stream.html" },
    text: () => Promise.resolve(html),
  }
}

// Drain enough microtasks for the async fetch pipeline to advance.
async function flush(times = 6) {
  for (let i = 0; i < times; i++) await Promise.resolve()
}

test("registers reactive:defer once (idempotent)", () => {
  const { actions } = stubTurbo()
  registerReactiveDefer()
  const first = actions["reactive:defer"]
  registerReactiveDefer()
  expect(actions["reactive:defer"]).toBe(first)
  expect(typeof first).toBe("function")
})

test("fetch lane: marks pending, POSTs the token to the defer path, applies the arrival", async () => {
  const { actions, rendered } = stubTurbo()
  const el = makeTargetEl("slow-totals")
  stubDocument({ byId: { "slow-totals": el }, metas: { "csrf-token": "csrf-123" } })
  const calls = stubFetch()
  registerReactiveDefer()

  actions["reactive:defer"].call(directiveEl({ target: "slow-totals" }))

  // Pending markers land synchronously — the shimmer window opens immediately.
  expect(el.attrs["data-reactive-defer-pending"]).toBe("true")
  expect(el.attrs["aria-busy"]).toBe("true")

  expect(calls.length).toBe(1)
  expect(calls[0].url).toBe("/reactive/defer")
  expect(calls[0].options.method).toBe("POST")
  expect(calls[0].options.headers["Accept"]).toBe("text/vnd.turbo-stream.html")
  expect(calls[0].options.headers["X-CSRF-Token"]).toBe("csrf-123")
  expect(JSON.parse(calls[0].options.body)).toEqual({ token: "signed-defer-token" })

  calls[0].gate.resolve(okResponse("<turbo-stream><template>real</template></turbo-stream>"))
  await flush()

  expect(rendered).toEqual(["<turbo-stream><template>real</template></turbo-stream>"])
  expect(el.attrs["data-reactive-defer-pending"]).toBeUndefined()
  expect(el.attrs["aria-busy"]).toBeUndefined()
})

test("honors a <meta name=\"phlex-reactive-defer-path\"> override", () => {
  const { actions } = stubTurbo()
  const el = makeTargetEl("slow-totals")
  stubDocument({ byId: { "slow-totals": el }, metas: { "phlex-reactive-defer-path": "/custom/defer" } })
  const calls = stubFetch()
  registerReactiveDefer()

  actions["reactive:defer"].call(directiveEl({ target: "slow-totals" }))
  expect(calls[0].url).toBe("/custom/defer")
})

test("a missing target is a warn-and-skip (no fetch)", () => {
  const { actions } = stubTurbo()
  stubDocument({ byId: {} })
  const calls = stubFetch()
  registerReactiveDefer()

  actions["reactive:defer"].call(directiveEl({ target: "ghost" }))
  expect(calls.length).toBe(0)
})

test("supersession: a newer directive for the SAME target aborts the older fetch and its late arrival is discarded", async () => {
  const { actions, rendered } = stubTurbo()
  const el = makeTargetEl("slow-totals")
  stubDocument({ byId: { "slow-totals": el } })
  const calls = stubFetch()
  registerReactiveDefer()

  actions["reactive:defer"].call(directiveEl({ target: "slow-totals", token: "first" }))
  actions["reactive:defer"].call(directiveEl({ target: "slow-totals", token: "second" }))

  expect(calls.length).toBe(2)
  expect(calls[0].options.signal.aborted).toBe(true)
  expect(calls[1].options.signal.aborted).toBe(false)

  // The FIRST (stale) response resolving late must never paint.
  calls[0].gate.resolve(okResponse("<turbo-stream><template>stale</template></turbo-stream>"))
  await flush()
  expect(rendered).toEqual([])

  calls[1].gate.resolve(okResponse("<turbo-stream><template>fresh</template></turbo-stream>"))
  await flush()
  expect(rendered).toEqual(["<turbo-stream><template>fresh</template></turbo-stream>"])
})

test("independent targets defer in parallel — one does not supersede the other", async () => {
  const { actions, rendered } = stubTurbo()
  const totals = makeTargetEl("totals")
  const chart = makeTargetEl("chart")
  stubDocument({ byId: { totals, chart } })
  const calls = stubFetch()
  registerReactiveDefer()

  actions["reactive:defer"].call(directiveEl({ target: "totals" }))
  actions["reactive:defer"].call(directiveEl({ target: "chart" }))

  expect(calls[0].options.signal.aborted).toBe(false)
  expect(calls[1].options.signal.aborted).toBe(false)

  calls[0].gate.resolve(okResponse("<t1/>"))
  calls[1].gate.resolve(okResponse("<t2/>"))
  await flush()
  expect(rendered).toEqual(["<t1/>", "<t2/>"])
})

test("204 (render? false) clears pending and applies nothing", async () => {
  const { actions, rendered } = stubTurbo()
  const el = makeTargetEl("slow-totals")
  stubDocument({ byId: { "slow-totals": el } })
  const calls = stubFetch()
  registerReactiveDefer()

  actions["reactive:defer"].call(directiveEl({ target: "slow-totals" }))
  calls[0].gate.resolve({ ok: true, status: 204, headers: { get: () => "" }, text: () => Promise.resolve("") })
  await flush()

  expect(rendered).toEqual([])
  expect(el.attrs["data-reactive-defer-pending"]).toBeUndefined()
  expect(el.attrs["aria-busy"]).toBeUndefined()
})

test("an HTTP failure marks the target and emits reactive:error kind=defer with a retry", async () => {
  const { actions } = stubTurbo()
  const el = makeTargetEl("slow-totals")
  stubDocument({ byId: { "slow-totals": el } })
  const calls = stubFetch()
  registerReactiveDefer()

  actions["reactive:defer"].call(directiveEl({ target: "slow-totals" }))
  calls[0].gate.resolve({ ok: false, status: 400, headers: { get: () => "" }, text: () => Promise.resolve("nope") })
  await flush()

  expect(el.attrs["data-reactive-defer-pending"]).toBeUndefined()
  expect(el.attrs["data-reactive-error"]).toBe("defer")
  expect(el.dispatched.length).toBe(1)
  expect(el.dispatched[0].detail.kind).toBe("defer")
  expect(typeof el.dispatched[0].detail.retry).toBe("function")

  // retry() re-enters the defer fetch with the SAME token.
  el.dispatched[0].detail.retry()
  expect(calls.length).toBe(2)
  expect(JSON.parse(calls[1].options.body)).toEqual({ token: "signed-defer-token" })
})

test("a network failure (fetch rejects) also marks + emits, and a SUPERSEDED abort stays silent", async () => {
  const { actions } = stubTurbo()
  const el = makeTargetEl("slow-totals")
  stubDocument({ byId: { "slow-totals": el } })
  const calls = stubFetch()
  registerReactiveDefer()

  actions["reactive:defer"].call(directiveEl({ target: "slow-totals", token: "first" }))
  // Supersede — the first fetch aborts; its rejection must NOT mark an error.
  actions["reactive:defer"].call(directiveEl({ target: "slow-totals", token: "second" }))
  const abortError = new Error("aborted")
  abortError.name = "AbortError"
  calls[0].gate.reject(abortError)
  await flush()
  expect(el.attrs["data-reactive-error"]).toBeUndefined()
  expect(el.dispatched.length).toBe(0)

  // A REAL network failure on the current defer marks + emits.
  calls[1].gate.reject(new TypeError("network down"))
  await flush()
  expect(el.attrs["data-reactive-error"]).toBe("defer")
  expect(el.dispatched.length).toBe(1)
})

test("the timeout aborts a stalled BODY read, not just the headers (marks error, clears pending)", async () => {
  // Regression: clearTimeout used to fire the instant headers arrived, leaving
  // response.text() unbounded. With a tiny timeout meta, a response whose
  // headers resolve but whose body hangs must still abort → error + pending
  // cleared. The fetch here honors the AbortSignal for BOTH the fetch and the
  // body read, so if the fix regressed (timer cleared early) this test hangs
  // and fails instead of aborting.
  const { actions } = stubTurbo()
  const el = makeTargetEl("slow-totals")
  stubDocument({ byId: { "slow-totals": el }, metas: { "phlex-reactive-timeout": "20" } })

  globalThis.fetch = (_url, options) =>
    Promise.resolve({
      ok: true,
      status: 200,
      headers: { get: () => "text/vnd.turbo-stream.html" },
      // Body that NEVER settles on its own — only the abort signal ends it.
      text: () =>
        new Promise((_res, rej) => {
          if (options.signal.aborted) return rej(named("AbortError"))
          options.signal.addEventListener("abort", () => rej(named("AbortError")))
        }),
    })
  registerReactiveDefer()

  actions["reactive:defer"].call(directiveEl({ target: "slow-totals" }))
  // Wait past the 20ms timeout for the abort to fire and the body read to reject.
  await new Promise((r) => setTimeout(r, 60))

  expect(el.attrs["data-reactive-defer-pending"]).toBeUndefined()
  expect(el.attrs["data-reactive-error"]).toBe("defer")
})

function named(name) {
  const e = new Error(name)
  e.name = name
  return e
}

test("stream lane: inserts a pgbus-stream-source with the deterministic id, src and since-id", () => {
  const { actions } = stubTurbo()
  const el = makeTargetEl("slow-totals")
  const { appended } = stubDocument({ byId: { "slow-totals": el } })
  globalThis.customElements = { get: (name) => (name === "pgbus-stream-source" ? class {} : undefined) }
  registerReactiveDefer()

  actions["reactive:defer"].call(
    directiveEl({ target: "slow-totals", via: "stream", token: null, src: "/pgbus/streams/signed", sinceId: "0" }),
  )

  expect(el.attrs["data-reactive-defer-pending"]).toBe("true")
  expect(appended.length).toBe(1)
  const source = appended[0]
  expect(source.tagName).toBe("pgbus-stream-source")
  expect(source.id).toBe("reactive-defer-src-slow-totals")
  expect(source.attrs["src"]).toBe("/pgbus/streams/signed")
  expect(source.attrs["since-id"]).toBe("0")
})

test("stream lane: a newer stream directive removes the older source element (unsubscribe = supersede)", () => {
  const { actions } = stubTurbo()
  const el = makeTargetEl("slow-totals")
  const { appended } = stubDocument({ byId: { "slow-totals": el } })
  globalThis.customElements = { get: () => class {} }
  registerReactiveDefer()

  const directive = (src) =>
    directiveEl({ target: "slow-totals", via: "stream", token: null, src, sinceId: "0" })
  actions["reactive:defer"].call(directive("/pgbus/streams/one"))
  actions["reactive:defer"].call(directive("/pgbus/streams/two"))

  expect(appended.length).toBe(2)
  expect(appended[0].removed).toBe(true)
  expect(appended[1].removed).toBe(false)
})

test("stream lane: the arriving broadcast settles the pendingDefers entry (no detached-node leak)", () => {
  // Regression for the re-review finding: the stream-lane Map entry used to
  // hold a strong ref to the source element and was never removed on arrival,
  // leaking a detached node per target. Now: no srcEl ref, and the job's
  // removal of the source element (every job broadcast ends with it) settles
  // the entry.
  const { actions } = stubTurbo()
  const el = makeTargetEl("slow-totals")
  const { listeners } = stubDocument({ byId: { "slow-totals": el } })
  globalThis.customElements = { get: () => class {} }
  registerReactiveDefer()

  actions["reactive:defer"].call(
    directiveEl({ target: "slow-totals", via: "stream", token: null, src: "/pgbus/streams/one" }),
  )
  expect(getPendingDeferVia("slow-totals")).toBe("stream")

  listeners["turbo:before-stream-render"]?.(streamRender("reactive-defer-src-slow-totals", "remove"))

  expect(getPendingDeferVia("slow-totals")).toBeUndefined()
})

test("stream lane: an unrelated stream to the target does NOT settle the entry (#292)", () => {
  // An `update` of #slow-totals from elsewhere (another broadcast, an action
  // reply) between the enqueue and the job's broadcast is not the delivery:
  // only the removal of reactive-defer-src-<target> is.
  const { actions } = stubTurbo()
  const el = makeTargetEl("slow-totals")
  const { listeners } = stubDocument({ byId: { "slow-totals": el } })
  globalThis.customElements = { get: () => class {} }
  registerReactiveDefer()

  actions["reactive:defer"].call(
    directiveEl({ target: "slow-totals", via: "stream", token: null, src: "/pgbus/streams/one" }),
  )
  listeners["turbo:before-stream-render"]?.(streamRender("slow-totals", "update"))
  expect(getPendingDeferVia("slow-totals")).toBe("stream")

  listeners["turbo:before-stream-render"]?.(streamRender("reactive-defer-src-slow-totals", "remove"))
  expect(getPendingDeferVia("slow-totals")).toBeUndefined()
})

// The turbo:before-stream-render event Turbo dispatches on a <turbo-stream>.
function streamRender(target, action) {
  return { target: { getAttribute: (n) => ({ target, action })[n] ?? null } }
}

test("lazy mount: connect() probes data-reactive-defer-token on the root and enters the fetch path", async () => {
  const { rendered } = stubTurbo()
  const mod = await import("../../app/javascript/phlex/reactive/reactive_controller.js")
  const Controller = mod.default

  const root = makeTargetEl("lazy-stats")
  root.attrs["data-reactive-defer-token"] = "lazy-token"
  // The server-rendered shell always carries the pending marker; the probe
  // gates on it (so a re-probe of a resolved root is a no-op).
  root.attrs["data-reactive-defer-pending"] = "true"
  // connect() touches these on every root — minimal stubs, like the other
  // controller unit tests.
  root.querySelectorAll = () => []
  root.addEventListener = () => {}
  stubDocument({ byId: { "lazy-stats": root } })
  const calls = stubFetch()

  const controller = new Controller()
  controller.element = root
  controller.connect()

  expect(calls.length).toBe(1)
  expect(calls[0].url).toBe("/reactive/defer")
  expect(JSON.parse(calls[0].options.body)).toEqual({ token: "lazy-token" })
  expect(root.attrs["data-reactive-defer-pending"]).toBe("true")

  calls[0].gate.resolve(okResponse("<turbo-stream><template>stats</template></turbo-stream>"))
  await flush()
  expect(rendered).toEqual(["<turbo-stream><template>stats</template></turbo-stream>"])
})

test("lazy mount: a turbo:morph-element re-showing the shell RE-FIRES the fetch (connect-only would hang)", async () => {
  // Regression: the probe ran only in connect(); a Turbo page-refresh morph
  // re-shows the shell while keeping the element connected (no re-connect), so
  // a connect-only probe left the morphed-in shell shimmering forever. The
  // probe is now also attached to turbo:morph-element.
  stubTurbo()
  const mod = await import("../../app/javascript/phlex/reactive/reactive_controller.js")
  const Controller = mod.default

  const root = makeTargetEl("lazy-stats")
  root.attrs["data-reactive-defer-token"] = "lazy-token"
  root.attrs["data-reactive-defer-pending"] = "true"
  const listeners = {}
  root.addEventListener = (name, fn) => (listeners[name] = fn)
  root.removeEventListener = () => {}
  root.querySelectorAll = () => []
  stubDocument({ byId: { "lazy-stats": root } })
  const calls = stubFetch()

  const controller = new Controller()
  controller.element = root
  controller.connect()
  expect(calls.length).toBe(1) // connect fired once
  calls[0].gate.resolve(okResponse("<t/>"))
  await flush()

  // A Turbo morph re-shows the shell (token + pending marker present again).
  root.attrs["data-reactive-defer-token"] = "lazy-token-2"
  root.attrs["data-reactive-defer-pending"] = "true"
  listeners["turbo:morph-element"]?.({ target: root })
  expect(calls.length).toBe(2) // re-fired on morph
  expect(JSON.parse(calls[1].options.body)).toEqual({ token: "lazy-token-2" })
})

test("lazy mount: a bubbling turbo:morph-element from a DESCENDANT does not re-probe the shell (#294)", async () => {
  // turbo:morph-element bubbles: a morphed skeleton child (or a nested root)
  // reaches the shell's listener too. Re-probing on it would supersede — abort
  // and re-issue — the shell's in-flight fetch on every descendant morph.
  stubTurbo()
  const mod = await import("../../app/javascript/phlex/reactive/reactive_controller.js")
  const Controller = mod.default

  const root = makeTargetEl("lazy-stats")
  root.attrs["data-reactive-defer-token"] = "lazy-token"
  root.attrs["data-reactive-defer-pending"] = "true"
  const listeners = {}
  root.addEventListener = (name, fn) => (listeners[name] = fn)
  root.removeEventListener = () => {}
  root.querySelectorAll = () => []
  stubDocument({ byId: { "lazy-stats": root } })
  const calls = stubFetch() // never resolved: the fetch stays in flight

  const controller = new Controller()
  controller.element = root
  controller.connect()
  expect(calls.length).toBe(1)

  listeners["turbo:morph-element"]?.({ target: makeTargetEl("skeleton-row") })
  expect(calls.length).toBe(1)
  expect(calls[0].options.signal.aborted).toBe(false)

  // A morph of the root itself still re-probes.
  listeners["turbo:morph-element"]?.({ target: root })
  expect(calls.length).toBe(2)
})

test("lazy mount: a re-probe of a RESOLVED root (no pending marker) is a no-op", async () => {
  stubTurbo()
  const mod = await import("../../app/javascript/phlex/reactive/reactive_controller.js")
  const Controller = mod.default

  const root = makeTargetEl("lazy-stats")
  // Resolved: real content replaced the shell — no token, no pending marker.
  const listeners = {}
  root.addEventListener = (name, fn) => (listeners[name] = fn)
  root.removeEventListener = () => {}
  root.querySelectorAll = () => []
  stubDocument({ byId: { "lazy-stats": root } })
  const calls = stubFetch()

  const controller = new Controller()
  controller.element = root
  controller.connect()
  listeners["turbo:morph-element"]?.({ target: root })
  expect(calls.length).toBe(0)
})

test("connect() without the token attribute never touches the defer path", async () => {
  stubTurbo()
  const mod = await import("../../app/javascript/phlex/reactive/reactive_controller.js")
  const Controller = mod.default

  const root = makeTargetEl("plain")
  root.querySelectorAll = () => []
  root.addEventListener = () => {}
  stubDocument({ byId: { plain: root } })
  const calls = stubFetch()

  const controller = new Controller()
  controller.element = root
  controller.connect()

  expect(calls.length).toBe(0)
})

test("stream lane: an unregistered pgbus element FALLS BACK to the fetch lane when a fallback token is present", () => {
  // The server chose push on server-side capability alone; if the pgbus client
  // isn't loaded here, a stream directive would dead-end (shimmer forever). The
  // directive carries a fallback token so the client degrades to the fetch lane.
  const { actions } = stubTurbo()
  const el = makeTargetEl("slow-totals")
  const { appended } = stubDocument({ byId: { "slow-totals": el } })
  const calls = stubFetch()
  globalThis.customElements = { get: () => undefined }
  registerReactiveDefer()

  actions["reactive:defer"].call(
    directiveEl({
      target: "slow-totals",
      via: "stream",
      token: "fallback-token",
      src: "/pgbus/streams/signed",
    }),
  )

  expect(appended.length).toBe(0) // no source element inserted
  expect(calls.length).toBe(1) // fell back to the fetch lane
  expect(calls[0].url).toBe("/reactive/defer")
  expect(JSON.parse(calls[0].options.body)).toEqual({ token: "fallback-token" })
  expect(el.attrs["data-reactive-defer-pending"]).toBe("true")
})

test("stream lane: an unregistered pgbus element with NO fallback token is a loud no-op", () => {
  const { actions } = stubTurbo()
  const el = makeTargetEl("slow-totals")
  const { appended } = stubDocument({ byId: { "slow-totals": el } })
  const calls = stubFetch()
  globalThis.customElements = { get: () => undefined }
  registerReactiveDefer()

  actions["reactive:defer"].call(
    directiveEl({ target: "slow-totals", via: "stream", token: null, src: "/pgbus/streams/signed" }),
  )
  expect(appended.length).toBe(0)
  expect(calls.length).toBe(0)
})
