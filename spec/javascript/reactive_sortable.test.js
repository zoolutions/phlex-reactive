// Sortable lists (issue #350), in features/sortable.js:
//
//   data-reactive-sortable="move"         a list; a drop sends `move` with
//                                         { item, position, after, from }
//   data-reactive-sortable-source="name"  a list whose rows are copied in
//   data-reactive-sortable-item='7'       a row and its JSON-typed key
//
// happy-dom has no layout, so every list and row gets a stubbed
// getBoundingClientRect (rows 40 px tall, stacked from y = 100) — the module
// reads geometry from nothing else. The request goes through the real
// controller's pipeline to a scripted fetch.
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll, beforeEach, afterEach } from "bun:test"
import { Window } from "happy-dom"

const window = new Window()
let ReactiveController
const SAVED = {}
const GLOBALS = ["document", "window", "Event", "CustomEvent", "MutationObserver", "fetch", "navigator", "requestAnimationFrame", "cancelAnimationFrame"]

beforeAll(async () => {
  mock.module("@hotwired/stimulus", () => ({ Controller: class {} }))
  ReactiveController = (await import("../../app/javascript/phlex/reactive/reactive_controller.js")).default
})

let requests
let reply
let controllers

beforeEach(() => {
  for (const key of GLOBALS) SAVED[key] = globalThis[key]
  globalThis.document = window.document
  globalThis.window = window
  globalThis.Event = window.Event
  globalThis.CustomEvent = window.CustomEvent
  globalThis.MutationObserver = window.MutationObserver
  // A frame is a macrotask here: the live region's words land on the next one.
  globalThis.requestAnimationFrame = (callback) => setTimeout(callback, 0)
  globalThis.cancelAnimationFrame = (id) => clearTimeout(id)
  window.Turbo = { renderStreamMessage: () => {} }
  requests = []
  reply = { body: '<turbo-stream action="replace" method="morph" target="tasks"><template></template></turbo-stream>' }
  globalThis.fetch = (_url, init) => {
    requests.push(JSON.parse(init.body))
    const script = typeof reply === "function" ? reply() : reply
    return Promise.resolve(script).then((r) => ({
      redirected: false,
      ok: r.ok ?? true,
      status: r.status ?? 200,
      headers: { get: () => "text/vnd.turbo-stream.html" },
      text: () => Promise.resolve(r.body ?? ""),
    }))
  }
  document.body.innerHTML = ""
  controllers = []
})

afterEach(() => {
  // A drag a test left on is ended (Escape reaches the document listener).
  document.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }))
  for (const controller of controllers) controller.disconnect?.()
  for (const [key, value] of Object.entries(SAVED)) globalThis[key] = value
})

const flush = async () => {
  for (let i = 0; i < 5; i++) await new Promise((resolve) => setTimeout(resolve, 0))
}

const MESSAGES = JSON.stringify({
  picked: "Picked up item {position} of {count}",
  moved: "Moved to position {position} of {count}",
  dropped: "Dropped",
  cancelled: "Cancelled",
}).replaceAll('"', "&quot;")

const rows = (keys, extra = "") =>
  keys.map((k) => `<li id="t${k}" tabindex="0" data-reactive-sortable-item="${k}" ${extra}><span data-drag-handle>⠿</span> Task ${k}</li>`).join("")

const list = ({ id = "tasks", attrs = "", keys = [1, 2, 3, 4], root = true } = {}) =>
  `<ul id="${id}" ${root ? `data-controller="reactive" data-reactive-token-value="tok-${id}"` : ""}
       data-reactive-sortable="move" data-reactive-sortable-messages="${MESSAGES}" ${attrs}>${rows(keys)}</ul>`

// Connect every reactive root, outermost first (as Stimulus does).
function mount(html) {
  document.body.innerHTML = html
  for (const root of document.querySelectorAll("[data-controller~='reactive']")) {
    const controller = new ReactiveController()
    controller.element = root
    controller.tokenValue = root.getAttribute("data-reactive-token-value") ?? ""
    controller.connect()
    controllers.push(controller)
  }
}

const rect = (left, top, width, height) => ({ left, top, width, height, right: left + width, bottom: top + height, x: left, y: top })

// Stack a list's rows 40 px apart from `top`, in a column at `left`.
function layout(listEl, { left = 0, top = 100 } = {}) {
  const items = [...listEl.querySelectorAll("[data-reactive-sortable-item]")]
  listEl.getBoundingClientRect = () => rect(left, top, 200, Math.max(items.length, 1) * 40)
  items.forEach((item, i) => {
    item.getBoundingClientRect = () => rect(left, top + i * 40, 200, 40)
  })
}

const order = (id = "tasks") => [...document.getElementById(id).querySelectorAll("[data-reactive-sortable-item]")].map((el) => el.id)

function pointer(type, el, x, y, options = {}) {
  const event = new window.PointerEvent(type, {
    bubbles: true,
    cancelable: true,
    clientX: x,
    clientY: y,
    button: 0,
    isPrimary: true,
    pointerType: "mouse",
    ...options,
  })
  el.dispatchEvent(event)
  return event
}

// Press on `el`, move past the threshold, then to (x, y), and release there.
function dragTo(el, x, y, options = {}) {
  const r = el.getBoundingClientRect()
  const x0 = r.left + 10
  const y0 = r.top + 10
  pointer("pointerdown", el, x0, y0, options)
  pointer("pointermove", document, x0, y0 + 10, options)
  pointer("pointermove", document, x, y, options)
  pointer("pointerup", document, x, y, options)
}

function key(el, name) {
  const event = new window.KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true })
  el.dispatchEvent(event)
  return event
}

const liveRegion = () => document.querySelector("[data-reactive-sortable-live]")
// What the live region says once its words have landed (the frame after the step).
const announced = async () => {
  await new Promise((resolve) => setTimeout(resolve, 0))
  return liveRegion()?.textContent
}

test("a pointer drop moves the row and sends the action once with item, position, after and from: self", async () => {
  mount(list())
  layout(document.getElementById("tasks"))

  dragTo(document.getElementById("t1"), 10, 225) // past t3's middle, before t4
  expect(order()).toEqual(["t2", "t3", "t1", "t4"])
  await flush()

  expect(requests).toHaveLength(1)
  expect(requests[0]).toMatchObject({ token: "tok-tasks", act: "move" })
  expect(requests[0].params).toEqual({ item: 1, position: 2, after: 3, from: "self" })
})

test("a drop to the top sends after: null", async () => {
  mount(list())
  layout(document.getElementById("tasks"))

  dragTo(document.getElementById("t3"), 10, 105)
  expect(order()).toEqual(["t3", "t1", "t2", "t4"])
  await flush()
  expect(requests[0].params).toEqual({ item: 3, position: 0, after: null, from: "self" })
})

test("while dragging: the list is active, the row is marked, a placeholder of its height marks the drop point", () => {
  mount(list())
  const listEl = document.getElementById("tasks")
  layout(listEl)
  const row = document.getElementById("t1")

  pointer("pointerdown", row, 10, 110)
  pointer("pointermove", document, 10, 120)
  pointer("pointermove", document, 10, 225)

  expect(listEl.hasAttribute("data-reactive-sortable-active")).toBe(true)
  expect(row.hasAttribute("data-reactive-sortable-dragging")).toBe(true)
  expect(row.style.position).toBe("fixed")
  const placeholder = listEl.querySelector("[data-reactive-sortable-placeholder]")
  expect(placeholder.style.height).toBe("40px")
  expect(placeholder.nextElementSibling.id).toBe("t4")

  pointer("pointerup", document, 10, 225)
  expect(listEl.hasAttribute("data-reactive-sortable-active")).toBe(false)
  expect(row.hasAttribute("data-reactive-sortable-dragging")).toBe(false)
  expect(row.getAttribute("style")).toBeNull()
  expect(listEl.querySelector("[data-reactive-sortable-placeholder]")).toBeNull()
})

test("a drop back where the row started sends nothing", async () => {
  mount(list())
  layout(document.getElementById("tasks"))
  dragTo(document.getElementById("t2"), 10, 150)
  await flush()
  expect(order()).toEqual(["t1", "t2", "t3", "t4"])
  expect(requests).toHaveLength(0)
})

test("a press without a move is a click, not a drag", async () => {
  mount(list())
  layout(document.getElementById("tasks"))
  const row = document.getElementById("t1")
  pointer("pointerdown", row, 10, 110)
  pointer("pointermove", document, 12, 112) // inside the 4 px threshold
  pointer("pointerup", document, 12, 112)
  await flush()
  expect(row.hasAttribute("data-reactive-sortable-dragging")).toBe(false)
  expect(requests).toHaveLength(0)
})

test("the row goes back to its original index when the action fails, and reactive:error fires", async () => {
  mount(list())
  layout(document.getElementById("tasks"))
  reply = { ok: false, status: 500, body: "boom" }
  const errors = []
  document.addEventListener("reactive:error", (e) => errors.push(e.detail.action))
  const quiet = console.error
  console.error = () => {}
  try {
    dragTo(document.getElementById("t1"), 10, 225)
    expect(order()).toEqual(["t2", "t3", "t1", "t4"])
    await flush()
  } finally {
    console.error = quiet
  }
  expect(order()).toEqual(["t1", "t2", "t3", "t4"])
  expect(errors).toEqual(["move"])
})

test("the row goes back when the reply does not render the list", async () => {
  mount(list())
  layout(document.getElementById("tasks"))
  reply = { body: '<turbo-stream action="append" target="flash"><template><p>hi</p></template></turbo-stream>' }
  dragTo(document.getElementById("t1"), 10, 225)
  await flush()
  expect(order()).toEqual(["t1", "t2", "t3", "t4"])
})

test("the row stays when the reply renders an ancestor of the list", async () => {
  mount(`<div id="board" data-controller="reactive" data-reactive-token-value="tok-board">${list({ id: "lane", root: false })}</div>`)
  layout(document.getElementById("lane"))
  reply = { body: '<turbo-stream action="update" target="board"><template></template></turbo-stream>' }
  dragTo(document.getElementById("t1"), 10, 225)
  await flush()
  expect(requests[0].token).toBe("tok-board")
  expect(order("lane")).toEqual(["t2", "t3", "t1", "t4"])
})

test("a vetoed dispatch (reactive:before-dispatch) puts the row back and sends nothing", async () => {
  mount(list())
  layout(document.getElementById("tasks"))
  document.addEventListener("reactive:before-dispatch", (e) => e.preventDefault(), { once: true })
  dragTo(document.getElementById("t1"), 10, 225)
  await flush()
  expect(requests).toHaveLength(0)
  expect(order()).toEqual(["t1", "t2", "t3", "t4"])
})

test("only the declared params are the action's business: the list's static params ride along", async () => {
  mount(list({ attrs: `data-reactive-sortable-params="${JSON.stringify({ lane: "doing" }).replaceAll('"', "&quot;")}"` }))
  layout(document.getElementById("tasks"))
  dragTo(document.getElementById("t1"), 10, 225)
  await flush()
  expect(requests[0].params).toEqual({ lane: "doing", item: 1, position: 2, after: 3, from: "self" })
})

test("handle: only the handle starts a drag; the rest of the row does not", async () => {
  mount(list({ attrs: 'data-reactive-sortable-handle="[data-drag-handle]"' }))
  layout(document.getElementById("tasks"))
  const row = document.getElementById("t1")

  // Pressing the row's own text: no drag.
  pointer("pointerdown", row, 10, 110)
  pointer("pointermove", document, 10, 130)
  pointer("pointermove", document, 10, 225)
  expect(row.hasAttribute("data-reactive-sortable-dragging")).toBe(false)
  pointer("pointerup", document, 10, 225)

  // Pressing the handle: a drag.
  const handle = row.querySelector("[data-drag-handle]")
  pointer("pointerdown", handle, 10, 110)
  pointer("pointermove", document, 10, 130)
  pointer("pointermove", document, 10, 225)
  pointer("pointerup", document, 10, 225)
  await flush()
  expect(requests).toHaveLength(1)
  expect(order()).toEqual(["t2", "t3", "t1", "t4"])
})

test("without a handle, a press on a form field inside a row does not start a drag", () => {
  mount(list().replace("Task 1", 'Task 1 <input id="field">'))
  layout(document.getElementById("tasks"))
  const field = document.getElementById("field")
  pointer("pointerdown", field, 10, 110)
  pointer("pointermove", document, 10, 130)
  expect(document.getElementById("t1").hasAttribute("data-reactive-sortable-dragging")).toBe(false)
  pointer("pointerup", document, 10, 130)
})

test("a disabled list, a disabled row, and a root with a request in flight refuse a drag", async () => {
  for (const html of [
    list({ attrs: 'data-reactive-sortable-disabled="true"' }),
    list().replace('<li id="t1"', '<li id="t1" data-reactive-sortable-disabled="true"'),
    list({ attrs: 'aria-busy="true"' }),
  ]) {
    mount(html)
    layout(document.getElementById("tasks"))
    const row = document.getElementById("t1")
    pointer("pointerdown", row, 10, 110)
    pointer("pointermove", document, 10, 130)
    expect(row.hasAttribute("data-reactive-sortable-dragging")).toBe(false)
    pointer("pointerup", document, 10, 225)
    key(row, " ")
    expect(row.hasAttribute("data-reactive-sortable-dragging")).toBe(false)
    for (const controller of controllers.splice(0)) controller.disconnect()
  }
  await flush()
  expect(requests).toHaveLength(0)
})

test("Escape during a pointer drag puts the row back and sends nothing", async () => {
  mount(list())
  layout(document.getElementById("tasks"))
  const row = document.getElementById("t1")
  pointer("pointerdown", row, 10, 110)
  pointer("pointermove", document, 10, 130)
  pointer("pointermove", document, 10, 225)
  key(document, "Escape")
  pointer("pointerup", document, 10, 225)
  await flush()
  expect(order()).toEqual(["t1", "t2", "t3", "t4"])
  expect(row.getAttribute("style")).toBeNull()
  expect(requests).toHaveLength(0)
})

test("touch: a finger that moves before the 200 ms press is scrolling; after the press it drags", async () => {
  mount(list())
  layout(document.getElementById("tasks"))
  const row = document.getElementById("t1")
  const touch = { pointerType: "touch" }

  pointer("pointerdown", row, 10, 110, touch)
  pointer("pointermove", document, 10, 150, touch)
  expect(row.hasAttribute("data-reactive-sortable-dragging")).toBe(false)
  pointer("pointerup", document, 10, 150, touch)

  pointer("pointerdown", row, 10, 110, touch)
  await new Promise((resolve) => setTimeout(resolve, 220))
  pointer("pointermove", document, 10, 130, touch)
  expect(row.hasAttribute("data-reactive-sortable-dragging")).toBe(true)
  // The page does not scroll under a touch drag.
  const touchmove = new window.Event("touchmove", { cancelable: true })
  document.dispatchEvent(touchmove)
  expect(touchmove.defaultPrevented).toBe(true)
  pointer("pointermove", document, 10, 225, touch)
  pointer("pointerup", document, 10, 225, touch)
  await flush()
  expect(requests[0].params).toEqual({ item: 1, position: 2, after: 3, from: "self" })
})

test("drag-in: a source row dropped into a same-group list fires the target's from: action; nothing moves", async () => {
  const from = JSON.stringify({ templates: "insert" }).replaceAll('"', "&quot;")
  mount(`
    <div id="templates" data-controller="reactive"
         data-reactive-sortable-source="templates" data-reactive-sortable-group="tasks">
      <button id="bug" type="button" tabindex="0" data-reactive-sortable-item="&quot;bug&quot;">Bug</button>
    </div>
    ${list({ attrs: `data-reactive-sortable-group="tasks" data-reactive-sortable-from="${from}"` })}`)
  const source = document.getElementById("templates")
  const target = document.getElementById("tasks")
  layout(target, { left: 300 })
  const bug = document.getElementById("bug")
  source.getBoundingClientRect = () => rect(0, 100, 200, 40)
  bug.getBoundingClientRect = () => rect(0, 100, 200, 40)

  pointer("pointerdown", bug, 10, 110)
  pointer("pointermove", document, 10, 130)
  // A clone follows the pointer; the source row stays put.
  const clone = document.body.lastElementChild
  expect(clone.hasAttribute("data-reactive-sortable-dragging")).toBe(true)
  expect(clone.hasAttribute("id")).toBe(false)
  expect(bug.parentElement).toBe(source)
  pointer("pointermove", document, 310, 135) // over the target, past t1's middle
  expect(target.querySelector("[data-reactive-sortable-placeholder]").previousElementSibling.id).toBe("t1")
  pointer("pointerup", document, 310, 135)
  await flush()

  expect(requests).toHaveLength(1)
  expect(requests[0]).toMatchObject({ token: "tok-tasks", act: "insert" })
  expect(requests[0].params).toEqual({ item: "bug", position: 1, after: 1, from: "templates" })
  expect(source.querySelectorAll("[data-reactive-sortable-item]")).toHaveLength(1)
  expect(order()).toEqual(["t1", "t2", "t3", "t4"])
  expect(document.querySelector("[data-reactive-sortable-dragging]")).toBeNull()
  expect(target.querySelector("[data-reactive-sortable-placeholder]")).toBeNull()
})

test("drag-in: without a from: mapping the target's own action is called", async () => {
  mount(`
    <div id="templates" data-controller="reactive" data-reactive-sortable-source="source" data-reactive-sortable-group="tasks">
      <button id="bug" type="button" data-reactive-sortable-item="&quot;bug&quot;">Bug</button>
    </div>
    ${list({ attrs: 'data-reactive-sortable-group="tasks"' })}`)
  layout(document.getElementById("tasks"), { left: 300 })
  document.getElementById("templates").getBoundingClientRect = () => rect(0, 100, 200, 40)
  document.getElementById("bug").getBoundingClientRect = () => rect(0, 100, 200, 40)
  dragTo(document.getElementById("bug"), 310, 105)
  await flush()
  expect(requests[0]).toMatchObject({ act: "move", params: { item: "bug", position: 0, after: null, from: "source" } })
})

test("drag-in dropped outside every target sends nothing", async () => {
  mount(`
    <div id="templates" data-controller="reactive" data-reactive-sortable-source="source" data-reactive-sortable-group="tasks">
      <button id="bug" type="button" data-reactive-sortable-item="&quot;bug&quot;">Bug</button>
    </div>
    ${list({ attrs: 'data-reactive-sortable-group="tasks"' })}`)
  layout(document.getElementById("tasks"), { left: 300 })
  document.getElementById("bug").getBoundingClientRect = () => rect(0, 100, 200, 40)
  dragTo(document.getElementById("bug"), 250, 300)
  await flush()
  expect(requests).toHaveLength(0)
  expect(document.querySelector("[data-reactive-sortable-dragging]")).toBeNull()
})

test("a move between two lists of one group reports the origin's name: as from", async () => {
  const params = (lane) => `data-reactive-sortable-params="${JSON.stringify({ lane }).replaceAll('"', "&quot;")}"`
  mount(`<div id="board" data-controller="reactive" data-reactive-token-value="tok-board">
    ${list({ id: "todo", root: false, keys: [1, 2], attrs: `data-reactive-sortable-group="cards" data-reactive-sortable-name="todo" ${params("todo")}` })}
    ${list({ id: "done", root: false, keys: [3, 4], attrs: `data-reactive-sortable-group="cards" data-reactive-sortable-name="done" ${params("done")}` })}
  </div>`)
  layout(document.getElementById("todo"))
  layout(document.getElementById("done"), { left: 300 })
  reply = { body: '<turbo-stream action="replace" method="morph" target="board"><template></template></turbo-stream>' }

  dragTo(document.getElementById("t1"), 310, 135)
  expect(order("todo")).toEqual(["t2"])
  expect(order("done")).toEqual(["t3", "t1", "t4"])
  await flush()
  expect(requests[0].params).toEqual({ lane: "done", item: 1, position: 1, after: 3, from: "todo" })
})

test("keyboard: Space picks up, arrows move, Enter drops — each step announced, then the action is sent", async () => {
  mount(list())
  const row = document.getElementById("t2")
  row.focus()

  key(row, " ")
  expect(row.hasAttribute("data-reactive-sortable-dragging")).toBe(true)
  expect(document.getElementById("tasks").hasAttribute("data-reactive-sortable-active")).toBe(true)
  expect(await announced()).toBe("Picked up item 2 of 4")

  key(row, "ArrowDown")
  expect(order()).toEqual(["t1", "t3", "t2", "t4"])
  expect(await announced()).toBe("Moved to position 3 of 4")
  key(row, "ArrowDown")
  key(row, "ArrowDown") // already last: stays
  expect(order()).toEqual(["t1", "t3", "t4", "t2"])
  key(row, "ArrowUp")
  expect(await announced()).toBe("Moved to position 3 of 4")

  key(row, "Enter")
  expect(await announced()).toBe("Dropped")
  expect(row.hasAttribute("data-reactive-sortable-dragging")).toBe(false)
  await flush()
  expect(requests[0].params).toEqual({ item: 2, position: 2, after: 3, from: "self" })
})

test("keyboard: Escape puts the row back, announces it, and sends nothing", async () => {
  mount(list())
  const row = document.getElementById("t3")
  key(row, "Enter")
  key(row, "ArrowUp")
  key(row, "ArrowUp")
  expect(order()).toEqual(["t3", "t1", "t2", "t4"])
  key(row, "Escape")
  expect(order()).toEqual(["t1", "t2", "t3", "t4"])
  expect(await announced()).toBe("Cancelled")
  await flush()
  expect(requests).toHaveLength(0)
})

test("keyboard: the app's words are used (translations)", async () => {
  const words = JSON.stringify({ picked: "Aufgenommen: {position}/{count}" }).replaceAll('"', "&quot;")
  mount(list().replace(/data-reactive-sortable-messages="[^"]*"/, `data-reactive-sortable-messages="${words}"`))
  key(document.getElementById("t1"), " ")
  expect(await announced()).toBe("Aufgenommen: 1/4")
  key(document.getElementById("t1"), "Escape")
})

test("keyboard: Space in a field inside a row types a space; it does not pick the row up", () => {
  mount(list().replace("Task 1", 'Task 1 <input id="field">'))
  const event = key(document.getElementById("field"), " ")
  expect(event.defaultPrevented).toBe(false)
  expect(document.getElementById("t1").hasAttribute("data-reactive-sortable-dragging")).toBe(false)
})

test("keyboard: ←/→ move a row into the previous/next list of its group", async () => {
  mount(`<div id="board" data-controller="reactive" data-reactive-token-value="tok-board">
    ${list({ id: "todo", root: false, keys: [1, 2], attrs: 'data-reactive-sortable-group="cards" data-reactive-sortable-name="todo"' })}
    ${list({ id: "done", root: false, keys: [3, 4], attrs: 'data-reactive-sortable-group="cards"' })}
  </div>`)
  reply = { body: '<turbo-stream action="replace" target="board"><template></template></turbo-stream>' }
  const row = document.getElementById("t2")
  key(row, " ")
  key(row, "ArrowRight")
  expect(order("done")).toEqual(["t3", "t2", "t4"])
  expect(document.getElementById("done").hasAttribute("data-reactive-sortable-active")).toBe(true)
  key(row, "ArrowRight") // no next list: stays
  key(row, " ")
  await flush()
  expect(requests[0].params).toEqual({ item: 2, position: 1, after: 3, from: "todo" })
})

test("nested roots: a row belongs to the closest sortable inside its own root", async () => {
  mount(`<div id="outer" data-controller="reactive" data-reactive-token-value="tok-outer">
    ${list({ id: "outer-list", root: false, keys: [1, 2] })}
    ${list({ id: "inner", keys: [3, 4, 5] })}
  </div>`)
  layout(document.getElementById("inner"))
  reply = { body: '<turbo-stream action="replace" target="inner"><template></template></turbo-stream>' }
  dragTo(document.getElementById("t3"), 10, 185)
  await flush()
  expect(requests).toHaveLength(1)
  expect(requests[0].token).toBe("tok-inner")
  expect(order("inner")).toEqual(["t4", "t3", "t5"])
})

test("busy: the list carries the busy marker and the busy hint while the request is pending", async () => {
  const busy = JSON.stringify({ add_class: ["opacity-50"] }).replaceAll('"', "&quot;")
  mount(list({ attrs: `data-reactive-sortable-busy="${busy}"` }))
  const listEl = document.getElementById("tasks")
  layout(listEl)
  let release
  reply = () => new Promise((resolve) => (release = () => resolve({ body: '<turbo-stream action="replace" target="tasks"><template></template></turbo-stream>' })))

  dragTo(document.getElementById("t1"), 10, 225)
  await flush()
  expect(listEl.getAttribute("data-reactive-busy")).toContain("move")
  expect(listEl.classList.contains("opacity-50")).toBe(true)
  // A drag while the request is in flight is refused.
  const row = document.getElementById("t2")
  key(row, " ")
  expect(row.hasAttribute("data-reactive-sortable-dragging")).toBe(false)

  release()
  await flush()
  expect(listEl.classList.contains("opacity-50")).toBe(false)
})

test("the live region exists, empty, as soon as a root with a sortable connects", () => {
  mount(list())
  const region = liveRegion()
  expect(region).not.toBeNull()
  expect(region.getAttribute("aria-live")).toBe("polite")
  expect(region.textContent).toBe("")
})

test("an announcement clears the region first and writes the words on the next frame", async () => {
  mount(list())
  const row = document.getElementById("t2")
  key(row, " ")
  expect(liveRegion().textContent).toBe("")
  expect(await announced()).toBe("Picked up item 2 of 4")
  key(row, "ArrowDown")
  expect(liveRegion().textContent).toBe("")
  expect(await announced()).toBe("Moved to position 3 of 4")
  key(row, "Escape")
})

test("keyboard: a move past either end of the list re-announces where the row is", async () => {
  mount(list())
  const row = document.getElementById("t4")
  key(row, " ")
  await announced()
  key(row, "ArrowDown") // already last
  expect(liveRegion().textContent).toBe("")
  expect(await announced()).toBe("Moved to position 4 of 4")
  key(row, "ArrowRight") // no other list in its group
  expect(await announced()).toBe("Moved to position 4 of 4")
  expect(order()).toEqual(["t1", "t2", "t3", "t4"])
  key(row, "Escape")
})

test("a second pointer landing mid-drag does not move or drop the row", async () => {
  mount(list())
  layout(document.getElementById("tasks"))
  const row = document.getElementById("t1")
  pointer("pointerdown", row, 10, 110, { pointerId: 1 })
  pointer("pointermove", document, 10, 120, { pointerId: 1 })
  pointer("pointermove", document, 10, 225, { pointerId: 2 }) // another finger: ignored
  expect(row.style.top).toBe("100px")
  pointer("pointerup", document, 10, 225, { pointerId: 2 })
  expect(row.hasAttribute("data-reactive-sortable-dragging")).toBe(true)
  pointer("pointermove", document, 10, 225, { pointerId: 1 })
  pointer("pointerup", document, 10, 225, { pointerId: 1 })
  await flush()
  expect(requests).toHaveLength(1)
})

test("the click a drag ends with is cancelled, not just stopped", () => {
  mount(list())
  layout(document.getElementById("tasks"))
  dragTo(document.getElementById("t1"), 10, 225)
  const click = new window.MouseEvent("click", { bubbles: true, cancelable: true })
  document.getElementById("t2").dispatchEvent(click)
  expect(click.defaultPrevented).toBe(true)
})

test("the row stays when the reply renders the list through a targets: selector", async () => {
  mount(list())
  layout(document.getElementById("tasks"))
  reply = { body: '<turbo-stream action="replace" targets=".sortable-lists"><template></template></turbo-stream>' }
  document.getElementById("tasks").classList.add("sortable-lists")
  dragTo(document.getElementById("t1"), 10, 225)
  await flush()
  expect(order()).toEqual(["t2", "t3", "t1", "t4"])
})

test("nested roots: Space on a nested list's row picks it up once (the outer root does not drop it)", () => {
  mount(`<div id="outer" data-controller="reactive" data-reactive-token-value="tok-outer">
    ${list({ id: "outer-list", root: false, keys: [1, 2] })}
    ${list({ id: "inner", keys: [3, 4, 5] })}
  </div>`)
  const row = document.getElementById("t3")
  key(row, " ")
  expect(row.hasAttribute("data-reactive-sortable-dragging")).toBe(true)
})
