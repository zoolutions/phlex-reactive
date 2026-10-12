// Presence (issue #358), in features/presence.js:
//
//   data-reactive-presence="<signed src>"   the roster root; the module mints
//                                           its <pgbus-stream-source presence>
//   data-reactive-presence-peer="<seat>"    a tab's element
//   data-reactive-presence-member="<id>"    a person's element
//
// pgbus is not loaded here: a bare custom element stands in for
// <pgbus-stream-source>, and a test plays the transport by setting its
// connection-id and dispatching pgbus:connected. Requests go through the real
// controller's pipeline to a scripted fetch.
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll, beforeEach, afterEach } from "bun:test"
import { Window } from "happy-dom"

const window = new Window({ url: "http://localhost/" })
let ReactiveController
const SAVED = {}
const GLOBALS = ["document", "window", "Event", "CustomEvent", "MutationObserver", "fetch", "location", "customElements"]

// pgbus's element mints one seat per document and exposes it as pgbusSeat.
const SEAT = "seat-0f3a"
window.customElements.define(
  "pgbus-stream-source",
  class extends window.HTMLElement {
    get pgbusSeat() {
      return SEAT
    }
  },
)
const presenceSeat = () => SEAT

beforeAll(async () => {
  mock.module("@hotwired/stimulus", () => ({ Controller: class {} }))
  ReactiveController = (await import("../../app/javascript/phlex/reactive/reactive_controller.js")).default
})

let requests
let controllers

beforeEach(() => {
  for (const key of GLOBALS) SAVED[key] = globalThis[key]
  globalThis.document = window.document
  globalThis.window = window
  globalThis.Event = window.Event
  globalThis.CustomEvent = window.CustomEvent
  globalThis.MutationObserver = window.MutationObserver
  globalThis.location = window.location
  globalThis.customElements = window.customElements
  window.Turbo = { renderStreamMessage: () => {} }
  requests = []
  globalThis.fetch = (_url, init) => {
    requests.push({ body: JSON.parse(init.body), headers: init.headers })
    return Promise.resolve({
      redirected: false,
      ok: true,
      status: 200,
      headers: { get: () => "text/vnd.turbo-stream.html" },
      text: () => Promise.resolve(""),
    })
  }
  document.body.innerHTML = ""
  controllers = []
})

afterEach(() => {
  for (const controller of controllers) controller.disconnect?.()
  for (const [key, value] of Object.entries(SAVED)) globalThis[key] = value
})

const flush = async () => {
  for (let i = 0; i < 5; i++) await new Promise((resolve) => setTimeout(resolve, 0))
}

const peers = (list) =>
  list.map(([seat, member]) => `<span data-reactive-presence-peer="${seat}" data-reactive-presence-member="${member}"></span>`).join("")

const roster = (inner, id = "viewers") =>
  `<div id="${id}" data-controller="reactive" data-reactive-token-value="tok-${id}"
        data-reactive-presence="/pgbus/streams/signed-board">${inner}</div>`

function connect(root) {
  const controller = new ReactiveController()
  controller.element = root
  controller.tokenValue = root.getAttribute("data-reactive-token-value") ?? ""
  controller.connect()
  controllers.push(controller)
  return controller
}

function mount(html) {
  document.body.innerHTML = html
  return [...document.querySelectorAll("[data-controller~='reactive']")].map(connect)
}

const source = (id = "viewers") => document.getElementById(`reactive-presence-src-${id}`)

function connected(id = "viewers", connectionId = "conn-1") {
  source(id).setAttribute("connection-id", connectionId)
  source(id).dispatchEvent(new CustomEvent("pgbus:connected", { detail: { connectionId } }))
}

const runOps = (controller, ops) => controller.runOps({ preventDefault() {}, params: { ops: JSON.stringify(ops) } })

// Re-render the root as a morph would, then fire Turbo's event for it.
async function morph(inner, id = "viewers") {
  const root = document.getElementById(id)
  root.innerHTML = inner
  root.dispatchEvent(new CustomEvent("turbo:morph-element", { bubbles: true }))
  await flush()
}

test("a presence root mints one hidden presence source in <body> (pgbus's element adds the seat)", () => {
  mount(roster(""))
  const el = source()
  expect(el.parentElement).toBe(document.body)
  expect(el.hasAttribute("presence")).toBe(true)
  expect(el.hidden).toBe(true)
  expect(el.getAttribute("src")).toBe("/pgbus/streams/signed-board")
  expect(document.querySelectorAll("pgbus-stream-source").length).toBe(1)
})

// Real SSE (found under TRANSPORT=pgbus): the pgbus client is an async module
// script, so the reactive controller can connect BEFORE <pgbus-stream-source>
// is defined. The source must still be minted — it upgrades when pgbus's module
// defines the element — and the missing-client error waits for a grace period.
test("a root that connects before pgbus defines its element still mints the source; no error yet", () => {
  const errors = []
  const savedError = console.error
  const savedTimeout = globalThis.setTimeout
  const timers = []
  console.error = (...args) => errors.push(args.join(" "))
  globalThis.customElements = { get: () => undefined }
  globalThis.setTimeout = (fn, ms) => timers.push({ fn, ms })
  try {
    mount(roster(""))
    const el = source()
    expect(el).not.toBeNull()
    expect(el.hasAttribute("presence")).toBe(true)
    expect(el.getAttribute("src")).toBe("/pgbus/streams/signed-board")
    expect(errors).toEqual([])

    // Still undefined after the grace period: now it is a misconfiguration.
    for (const { fn } of timers) fn()
    expect(errors.length).toBe(1)
    expect(errors[0]).toContain("needs the pgbus client")
  } finally {
    console.error = savedError
    globalThis.setTimeout = savedTimeout
  }
})

test("a root whose pgbus element gets defined within the grace period logs nothing", () => {
  const errors = []
  const savedError = console.error
  const savedTimeout = globalThis.setTimeout
  const timers = []
  let defined = false
  console.error = (...args) => errors.push(args.join(" "))
  globalThis.customElements = { get: () => (defined ? class {} : undefined) }
  globalThis.setTimeout = (fn, ms) => timers.push({ fn, ms })
  try {
    mount(roster(""))
    defined = true
    for (const { fn } of timers) fn()
    expect(errors).toEqual([])
  } finally {
    console.error = savedError
    globalThis.setTimeout = savedTimeout
  }
})

test("on connect it announces the tab: presence_set with {}, sent on the presence connection", async () => {
  // The app's own stream source comes first on the page.
  document.body.innerHTML = '<pgbus-stream-source id="app" connection-id="app-conn"></pgbus-stream-source>'
  document.body.insertAdjacentHTML("beforeend", roster(""))
  connect(document.getElementById("viewers"))
  await flush()
  expect(requests.length).toBe(0)

  connected("viewers", "presence-conn")
  await flush()

  expect(requests.length).toBe(1)
  expect(requests[0].body.act).toBe("presence_set")
  expect(requests[0].body.params).toEqual({})
  expect(requests[0].headers["X-Reactive-Presence"]).toBe("presence-conn")
  expect(requests[0].headers["X-Pgbus-Connection"]).toBe("app-conn")
})

test("js.presence waits for the connection, then sends the merged state; a reconnect sends it again", async () => {
  const [controller] = mount(roster(""))
  runOps(controller, [["presence", { to: "@root", state: { selected: 7 } }]])
  await flush()
  expect(requests.length).toBe(0)

  connected()
  await flush()
  expect(requests.at(-1).body.params).toEqual({ selected: 7 })

  runOps(controller, [["presence", { to: "@root", state: { typing: true } }]])
  await flush()
  expect(requests.at(-1).body.params).toEqual({ selected: 7, typing: true })

  connected("viewers", "conn-2")
  await flush()
  expect(requests.at(-1).body.params).toEqual({ selected: 7, typing: true })
  expect(requests.at(-1).headers["X-Reactive-Presence"]).toBe("conn-2")
})

// pgbus >= 0.18 fires pgbus:connected only after the tab's seat has joined
// (zoolutions/pgbus#523), so ONE announce lands on the row. A tab that still
// never appears on its roster has no identity (no streams_authorize, or one
// that returns true): the module says so once.
function withTimers(fn) {
  const timers = []
  const savedTimeout = globalThis.setTimeout
  const savedClear = globalThis.clearTimeout
  globalThis.setTimeout = (cb, ms) => {
    if (!ms) return savedTimeout(cb, 0)
    timers.push(cb)
    return timers.length
  }
  globalThis.clearTimeout = (id) => {
    if (typeof id === "number" && id <= timers.length && timers[id - 1]) timers[id - 1] = null
    else savedClear(id)
  }
  const fire = async () => {
    const pending = timers.splice(0).filter(Boolean)
    for (const cb of pending) cb()
    await flush()
  }
  return fn(fire).finally(() => {
    globalThis.setTimeout = savedTimeout
    globalThis.clearTimeout = savedClear
  })
}

test("on connect the tab announces once, even before the roster shows it", () =>
  withTimers(async (fire) => {
    mount(roster(""))
    connected()
    await flush()
    expect(requests.length).toBe(1)

    await morph(peers([["other-seat", "u2"]]))
    for (let i = 0; i < 4; i++) await fire()
    expect(requests.length).toBe(1)
  }))

test("a tab on its roster after connect logs nothing", () =>
  withTimers(async (fire) => {
    const warns = []
    const saved = console.warn
    console.warn = (...args) => warns.push(args.join(" "))
    try {
      mount(roster(peers([[presenceSeat(), "u1"]])))
      connected()
      await flush()
      await fire()
      expect(warns).toEqual([])
    } finally {
      console.warn = saved
    }
  }))

test("a tab that never appears on its roster warns once that it has no identity", () =>
  withTimers(async (fire) => {
    const warns = []
    const saved = console.warn
    console.warn = (...args) => warns.push(args.join(" "))
    try {
      mount(roster(""))
      connected()
      await flush()
      for (let i = 0; i < 4; i++) await fire()
      expect(requests.length).toBe(1)
      expect(warns.length).toBe(1)
      expect(warns[0]).toContain("streams_authorize")
    } finally {
      console.warn = saved
    }
  }))

test("js.presence outside a presence root warns and sends nothing", async () => {
  const warn = mock(() => {})
  const saved = console.warn
  console.warn = warn
  try {
    const [controller] = mount('<div id="plain" data-controller="reactive" data-reactive-token-value="t"></div>')
    runOps(controller, [["presence", { to: "@root", state: { selected: 1 } }]])
    await flush()
    expect(requests.length).toBe(0)
    expect(warn.mock.calls.flat().join(" ")).toContain("js.presence")
  } finally {
    console.warn = saved
  }
})

test("it marks this tab's peer as me and this person's other elements as same-member", () => {
  const me = presenceSeat()
  mount(roster(`<b data-reactive-presence-member="7"></b>${peers([[me, "7"], ["other-tab", "7"], ["bob-tab", "9"]])}`))
  const at = (selector) => document.querySelector(selector)
  expect(at(`[data-reactive-presence-peer="${me}"]`).hasAttribute("data-reactive-presence-me")).toBe(true)
  expect(at('[data-reactive-presence-peer="other-tab"]').hasAttribute("data-reactive-presence-same-member")).toBe(true)
  expect(at('b[data-reactive-presence-member="7"]').hasAttribute("data-reactive-presence-same-member")).toBe(true)
  expect(at('[data-reactive-presence-peer="bob-tab"]').hasAttribute("data-reactive-presence-same-member")).toBe(false)
  expect(at('[data-reactive-presence-peer="bob-tab"]').hasAttribute("data-reactive-presence-me")).toBe(false)
})

test("after a morph it re-marks me and reports the seats that joined and left; an identical morph reports nothing", async () => {
  const me = presenceSeat()
  mount(roster(peers([["ada", "1"]])))
  const events = []
  document.getElementById("viewers").addEventListener("reactive:presence", (event) => events.push(event.detail))

  await morph(peers([["ada", "1"], [me, "2"]]))
  expect(events).toEqual([{ joined: [me], left: [], me }])
  expect(document.querySelector(`[data-reactive-presence-peer="${me}"]`).hasAttribute("data-reactive-presence-me")).toBe(true)

  await morph(peers([["ada", "1"], [me, "2"]]))
  expect(events.length).toBe(1)

  await morph(peers([[me, "2"]]))
  expect(events.at(-1)).toEqual({ joined: [], left: ["ada"], me })
})

// The root names the seats its render saw (data-reactive-presence-roster): a
// roster that shows people, not tabs, still reports joins and leaves.
const setRoster = (seats, id = "viewers") => document.getElementById(id).setAttribute("data-reactive-presence-roster", seats)

test("joins and leaves come from the root's seat list when the template renders no element per tab", async () => {
  mount(roster(""))
  setRoster("")
  const events = []
  document.getElementById("viewers").addEventListener("reactive:presence", (event) => events.push(event.detail))
  // Re-read the starting seats from the attribute.
  await morph("")
  events.length = 0

  setRoster("ada bob")
  await morph('<li data-reactive-presence-member="u1"></li>')
  expect(events).toEqual([{ joined: ["ada", "bob"], left: [], me: presenceSeat() }])

  setRoster("bob")
  await morph('<li data-reactive-presence-member="u1"></li>')
  expect(events.at(-1)).toEqual({ joined: [], left: ["ada"], me: presenceSeat() })
})

test("a tab named on the root's seat list is on the roster: no warning, even with no element for it", () =>
  withTimers(async (fire) => {
    mount(roster(""))
    setRoster(presenceSeat())
    connected()
    await flush()
    await fire()
    await fire()
    expect(requests.length).toBe(1)
  }))

test("a replace of the root keeps its source; a root that goes away removes it", async () => {
  const [first] = mount(roster(""))
  const kept = source()

  // A plain replace: the old root disconnects, a new one with the same id connects.
  first.disconnect()
  controllers.splice(controllers.indexOf(first), 1)
  const fresh = document.createElement("div")
  fresh.innerHTML = roster("")
  document.getElementById("viewers").replaceWith(fresh.firstElementChild)
  connect(document.getElementById("viewers"))
  await flush()
  expect(source()).toBe(kept)

  controllers.pop().disconnect()
  await flush()
  expect(source()).toBe(null)
})
