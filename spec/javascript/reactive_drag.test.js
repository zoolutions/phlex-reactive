// Draggable regions (issue #416), in features/drag.js:
//
//   data-reactive-frame                    the coordinate space (its padding box)
//   data-reactive-box='{"x":"r[x]",…}'     a box and the fields that hold it
//     -min / -ratio / -aspect / -action / -busy / -messages
//   data-reactive-box-handle="se"          an edge or corner to resize from
//   data-reactive-point='{"x":…,"y":…}'    a point (-within / -action / …)
//
// happy-dom has no layout: the frame gets a stubbed getBoundingClientRect
// (400 × 200 px at 100, 100) and every box a rect computed from its own inline
// percentages, so a moved box is where its style says. The request goes
// through the real controller's pipeline to a scripted fetch.
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll, beforeEach, afterEach, describe } from "bun:test"
import { Window } from "happy-dom"

const window = new Window()
let ReactiveController
let drag
const SAVED = {}
const GLOBALS = ["document", "window", "Event", "CustomEvent", "MutationObserver", "fetch", "navigator", "requestAnimationFrame", "cancelAnimationFrame"]

beforeAll(async () => {
  mock.module("@hotwired/stimulus", () => ({ Controller: class {} }))
  ReactiveController = (await import("../../app/javascript/phlex/reactive/reactive_controller.js")).default
  drag = await import("../../app/javascript/phlex/reactive/features/drag.js")
})

let requests
let controllers
let frames

beforeEach(() => {
  for (const key of GLOBALS) SAVED[key] = globalThis[key]
  globalThis.document = window.document
  globalThis.window = window
  globalThis.Event = window.Event
  globalThis.CustomEvent = window.CustomEvent
  globalThis.MutationObserver = window.MutationObserver
  // A frame is a macrotask here; `frames` counts the ones that ran.
  frames = 0
  globalThis.requestAnimationFrame = (callback) => setTimeout(() => (frames++, callback()), 0)
  globalThis.cancelAnimationFrame = (id) => clearTimeout(id)
  window.Turbo = { renderStreamMessage: () => {} }
  requests = []
  globalThis.fetch = (_url, init) => {
    requests.push(JSON.parse(init.body))
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
  document.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }))
  for (const controller of controllers) controller.disconnect?.()
  for (const [key, value] of Object.entries(SAVED)) globalThis[key] = value
})

const flush = async () => {
  for (let i = 0; i < 5; i++) await new Promise((resolve) => setTimeout(resolve, 0))
}

const json = (value) => JSON.stringify(value).replaceAll('"', "&quot;")
const MESSAGES = json({ moved: "Moved to {x}%, {y}%", resized: "Resized to {width}% by {height}%", cancelled: "Cancelled" })
const BOX_FIELDS = json({ x: "r[x]", y: "r[y]", width: "r[width]", height: "r[height]" })
const HANDLES = ["nw", "n", "ne", "e", "se", "s", "sw", "w"]

const style = ({ x, y, width, height }) =>
  `position: absolute; box-sizing: border-box; left: ${x * 100}%; top: ${y * 100}%; width: ${width * 100}%; height: ${height * 100}%; touch-action: none;`

// `scale` (issue #428): the fields render on it, as the app renders them, and
// the box carries data-reactive-box-scale.
function picker({ value = { x: 0.1, y: 0.1, width: 0.5, height: 0.4 }, attrs = "", inside = "", beside = "", outside = "", token = "tok", scale = 1 } = {}) {
  const fields = Object.entries(value)
    .map(([key, v]) => `<input type="hidden" name="r[${key}]" value="${scale === 1 ? v : drag.scaled(v, scale)}">`)
    .join("")
  return `<div id="picker" data-controller="reactive" ${token ? `data-reactive-token-value="${token}"` : ""}>
    <div data-reactive-frame>
      <div id="box" tabindex="0" style="${style(value)}" data-reactive-box="${BOX_FIELDS}" data-reactive-box-min="0.05"
           data-reactive-box-messages="${MESSAGES}" ${scale === 1 ? "" : `data-reactive-box-scale="${scale}"`} ${attrs}>
        ${HANDLES.map((edge) => `<span tabindex="-1" data-reactive-box-handle="${edge}" id="h-${edge}"></span>`).join("")}
        ${inside}
      </div>${beside}
    </div>
    ${fields}${outside}
  </div>`
}

const rect = (left, top, width, height) => ({ left, top, width, height, right: left + width, bottom: top + height, x: left, y: top })
const FRAME = rect(100, 100, 400, 200)

// Lay the frame out at FRAME; every box, handle and point inside it gets the
// rect its own percentages give against its offset parent's rect.
function layout() {
  const frame = document.querySelector("[data-reactive-frame]")
  frame.getBoundingClientRect = () => FRAME
  const place = (el, parent) => {
    el.getBoundingClientRect = () => {
      const p = parent.getBoundingClientRect()
      const pct = (name) => (parseFloat(el.style[name]) || 0) / 100
      const width = el.matches("[data-reactive-box]") ? pct("width") * p.width : 10
      const height = el.matches("[data-reactive-box]") ? pct("height") * p.height : 10
      const left = p.left + pct("left") * p.width - (el.matches("[data-reactive-box]") ? 0 : 5)
      const top = p.top + pct("top") * p.height - (el.matches("[data-reactive-box]") ? 0 : 5)
      return rect(left, top, width, height)
    }
    for (const child of el.children) place(child, el)
  }
  for (const child of frame.children) place(child, frame)
}

function mount(html) {
  document.body.innerHTML = html
  layout()
  for (const root of document.querySelectorAll("[data-controller~='reactive']")) {
    const controller = new ReactiveController()
    controller.element = root
    controller.tokenValue = root.getAttribute("data-reactive-token-value") ?? ""
    controller.connect()
    controllers.push(controller)
  }
}

const field = (name) => document.querySelector(`[name="${name}"]`)
const values = (prefix = "r") =>
  Object.fromEntries([...document.querySelectorAll(`[name^="${prefix}["]`)].map((el) => [el.name.slice(prefix.length + 1, -1), Number(el.value)]))
const box = () => document.getElementById("box")
const at = (el) => {
  const r = el.getBoundingClientRect()
  return [r.left + r.width / 2, r.top + r.height / 2]
}

function pointer(type, el, x, y, options = {}) {
  const event = new window.PointerEvent(type, { bubbles: true, cancelable: true, clientX: x, clientY: y, button: 0, isPrimary: true, pointerType: "mouse", pointerId: 1, ...options })
  el.dispatchEvent(event)
  return event
}

// Press on `el`, move by (dx, dy) px in two steps, optionally release.
function dragBy(el, dx, dy, { release = true, ...options } = {}) {
  const [x0, y0] = at(el)
  pointer("pointerdown", el, x0, y0, options)
  pointer("pointermove", document, x0 + dx / 2, y0 + dy / 2, options)
  pointer("pointermove", document, x0 + dx, y0 + dy, options)
  if (release) pointer("pointerup", document, x0 + dx, y0 + dy, options)
}

function key(el, name, options = {}, type = "keydown") {
  const event = new window.KeyboardEvent(type, { key: name, bubbles: true, cancelable: true, ...options })
  el.dispatchEvent(event)
  return event
}

const press = (el, name, options) => (key(el, name, options), key(el, name, options, "keyup"))

function listen(type) {
  const seen = []
  document.addEventListener(type, (event) => seen.push(event.target.name))
  return seen
}

const live = () => document.querySelector("[data-reactive-drag-live]")?.textContent

// --- Geometry ----------------------------------------------------------------
describe("geometry", () => {
  const b = { x: 0.1, y: 0.1, width: 0.5, height: 0.4 }
  const close = (actual, expected) => {
    for (const [k, v] of Object.entries(expected)) expect(actual[k]).toBeCloseTo(v, 6)
  }

  test("a move is clamped to the frame", () => {
    close(drag.moveBox(b, 0.2, 0.1), { x: 0.3, y: 0.2, width: 0.5, height: 0.4 })
    close(drag.moveBox(b, 0.9, -0.5), { x: 0.5, y: 0 })
    close(drag.movePoint({ x: 0.5, y: 0.5 }, 0.7, -0.6), { x: 1, y: 0 })
  })

  test("a free resize moves only the dragged edges, clamped to the frame and min:", () => {
    close(drag.resizeBox(b, "se", 0.1, 0.1, 0.05, 0), { x: 0.1, y: 0.1, width: 0.6, height: 0.5 })
    close(drag.resizeBox(b, "se", 0.9, 0.9, 0.05, 0), { width: 0.9, height: 0.9 })
    close(drag.resizeBox(b, "e", -0.9, 0.3, 0.05, 0), { x: 0.1, width: 0.05, height: 0.4 })
    // nw: the right/bottom edges stay where they are
    close(drag.resizeBox(b, "nw", 0.1, 0.1, 0.05, 0), { x: 0.2, y: 0.2, width: 0.4, height: 0.3 })
    close(drag.resizeBox(b, "nw", -0.5, -0.5, 0.05, 0), { x: 0, y: 0, width: 0.6, height: 0.5 })
    close(drag.resizeBox(b, "nw", 0.9, 0.9, 0.05, 0), { x: 0.55, y: 0.45, width: 0.05, height: 0.05 })
    close(drag.resizeBox(b, "n", 0.3, -0.05, 0.05, 0), { x: 0.1, y: 0.05, width: 0.5, height: 0.45 })
  })

  test("a locked resize keeps the ratio: the axis moved more drives a corner", () => {
    const square = { x: 0.1, y: 0.1, width: 0.4, height: 0.4 }
    close(drag.resizeBox(square, "se", 0.2, 0.05, 0.05, 1), { x: 0.1, y: 0.1, width: 0.6, height: 0.6 })
    close(drag.resizeBox(square, "se", 0.02, -0.1, 0.05, 1), { width: 0.3, height: 0.3 })
    // past the frame: the box stops at the edge it reaches first
    close(drag.resizeBox(square, "se", 0.9, 0, 0.05, 1), { width: 0.9, height: 0.9 })
    close(drag.resizeBox(square, "sw", 0.9, 0, 0.05, 1), { x: 0.45, y: 0.1, width: 0.05, height: 0.05 })
    // ratio 2 (twice as wide as tall, in frame fractions)
    close(drag.resizeBox(square, "se", 0.2, 0, 0.05, 2), { width: 0.6, height: 0.3 })
  })

  test("a locked edge resize grows the other axis around the box's centre", () => {
    const square = { x: 0.3, y: 0.3, width: 0.4, height: 0.4 } // centre (0.5, 0.5)
    close(drag.resizeBox(square, "e", 0.1, 0, 0.05, 1), { x: 0.3, y: 0.25, width: 0.5, height: 0.5 })
    close(drag.resizeBox(square, "s", 0, 0.1, 0.05, 1), { x: 0.25, y: 0.3, width: 0.5, height: 0.5 })
    // the vertical room around the centre (1.0) caps it, though the right has 0.7
    close(drag.resizeBox(square, "e", 0.6, 0, 0.05, 1), { width: 0.7, height: 0.7 })
    const low = { x: 0.1, y: 0.7, width: 0.2, height: 0.2 } // centre y 0.8: 0.4 of room
    close(drag.resizeBox(low, "e", 0.5, 0, 0.05, 1), { y: 0.6, width: 0.4, height: 0.4 })
  })

  test("min: holds on both axes of a locked resize", () => {
    const square = { x: 0.1, y: 0.1, width: 0.4, height: 0.4 }
    close(drag.resizeBox(square, "se", -0.9, -0.9, 0.1, 2), { width: 0.2, height: 0.1 })
  })

  test("a re-fit keeps the area at the new ratio, centred, inside the frame", () => {
    close(drag.fitBox({ x: 0.3, y: 0.3, width: 0.4, height: 0.4 }, 4, 0.05), { x: 0.1, y: 0.4, width: 0.8, height: 0.2 })
    // too wide for the frame: as wide as it can be, then pushed inside
    close(drag.fitBox({ x: 0.6, y: 0.6, width: 0.4, height: 0.4 }, 16, 0.05), { x: 0, width: 1, height: 1 / 16 })
    close(drag.fitBox({ x: 0.7, y: 0.7, width: 0.3, height: 0.3 }, 1, 0.05), { x: 0.7, y: 0.7, width: 0.3, height: 0.3 })
  })

  test("a ratio reads W:H, a decimal, or nothing (free)", () => {
    expect(drag.parseRatio("16:9")).toBeCloseTo(16 / 9, 9)
    expect(drag.parseRatio(" 4 : 3 ")).toBeCloseTo(4 / 3, 9)
    expect(drag.parseRatio("1.5")).toBe(1.5)
    for (const free of ["", "free", "0", "16:0", "1:2:3", null, undefined]) expect(drag.parseRatio(free)).toBe(0)
  })

  test("fields hold fractions rounded to 4 decimals", () => {
    expect(drag.round(0.123456)).toBe(0.1235)
    expect(drag.round(0.1 + 0.2)).toBe(0.3)
  })
})

// --- Pointer -------------------------------------------------------------------
describe("pointer", () => {
  test("a press on the box moves it: style and fields follow, clamped to the frame", async () => {
    mount(picker())
    dragBy(box(), 40, 20) // 0.1 of the frame each way
    await flush()
    expect(values()).toEqual({ x: 0.2, y: 0.2, width: 0.5, height: 0.4 })
    expect(box().style.left).toBe("20%")
    expect(box().style.top).toBe("20%")
    dragBy(box(), 1000, 1000)
    await flush()
    expect(values()).toEqual({ x: 0.5, y: 0.6, width: 0.5, height: 0.4 })
  })

  test("a press on a handle resizes from that edge, never below min:", async () => {
    mount(picker())
    dragBy(document.getElementById("h-se"), 40, 20)
    await flush()
    expect(values()).toEqual({ x: 0.1, y: 0.1, width: 0.6, height: 0.5 })
    dragBy(document.getElementById("h-nw"), 1000, 1000)
    await flush()
    expect(values()).toEqual({ x: 0.65, y: 0.55, width: 0.05, height: 0.05 })
  })

  test("rounding to 4 decimals never takes the box past the frame's edge", async () => {
    // A box against the right edge, resized from the left: x = 1 - width. Rounded
    // apart, 0.45545 + 0.54455 becomes 0.4555 + 0.5446 = 1.0001 — past the edge,
    // which the server's re-render refuses.
    mount(picker({ value: { x: 0.5, y: 0.1, width: 0.5, height: 0.4 }, attrs: 'data-reactive-box-action="crop"' }))
    dragBy(document.getElementById("h-w"), -17.82, 0)
    await flush()
    const { x, width } = values()
    expect(x + width).toBeLessThanOrEqual(1 + 1e-9)
    expect(requests[0].params.x + requests[0].params.width).toBeLessThanOrEqual(1 + 1e-9)
    expect(parseFloat(box().style.left) + parseFloat(box().style.width)).toBeLessThanOrEqual(100 + 1e-9)
  })

  test("a move under 4 px is not a drag; a press on the frame outside the box does nothing", async () => {
    mount(picker())
    const changes = listen("change")
    dragBy(box(), 3, 3)
    const frame = document.querySelector("[data-reactive-frame]")
    pointer("pointerdown", frame, 490, 290)
    pointer("pointermove", document, 400, 200)
    pointer("pointerup", document, 400, 200)
    await flush()
    expect(values()).toEqual({ x: 0.1, y: 0.1, width: 0.5, height: 0.4 })
    expect(changes).toEqual([])
  })

  test("input fires as the box moves, at most once per field a frame; change once on release", async () => {
    mount(picker())
    const inputs = listen("input")
    const changes = listen("change")
    const [x0, y0] = at(box())
    pointer("pointerdown", box(), x0, y0)
    for (let i = 1; i <= 10; i++) pointer("pointermove", document, x0 + i * 4, y0)
    await flush()
    expect(inputs).toEqual(["r[x]"])
    expect(frames).toBe(1)
    pointer("pointermove", document, x0 + 80, y0 + 40)
    pointer("pointerup", document, x0 + 80, y0 + 40)
    expect(inputs).toEqual(["r[x]", "r[x]", "r[y]"])
    expect(changes).toEqual(["r[x]", "r[y]"])
  })

  test("styling hooks are on while a drag is on, and off after", async () => {
    mount(picker())
    const handle = document.getElementById("h-e")
    dragBy(handle, 20, 0, { release: false })
    expect(document.querySelector("[data-reactive-frame]").hasAttribute("data-reactive-frame-active")).toBe(true)
    expect(handle.hasAttribute("data-reactive-dragging")).toBe(true)
    pointer("pointerup", document, 0, 0)
    expect(document.querySelector("[data-reactive-frame-active], [data-reactive-dragging]")).toBeNull()
  })

  test("Escape mid-drag puts the box back where it started, with no change", async () => {
    mount(picker())
    const changes = listen("change")
    dragBy(box(), 40, 40, { release: false })
    expect(box().style.left).toBe("20%")
    key(document, "Escape")
    await flush()
    expect(box().style.left).toBe("10%")
    expect(values()).toEqual({ x: 0.1, y: 0.1, width: 0.5, height: 0.4 })
    expect(changes).toEqual([])
    expect(document.querySelector("[data-reactive-frame-active]")).toBeNull()
  })

  test("only the pointer that pressed drives the drag", async () => {
    mount(picker())
    const [x0, y0] = at(box())
    pointer("pointerdown", box(), x0, y0)
    pointer("pointermove", document, x0 + 40, y0)
    pointer("pointermove", document, x0 + 200, y0, { pointerId: 2 })
    pointer("pointerup", document, x0 + 200, y0, { pointerId: 2 })
    expect(box().style.left).toBe("20%")
    pointer("pointerup", document, x0 + 40, y0)
    expect(document.querySelector("[data-reactive-frame-active]")).toBeNull()
  })
})

// --- Aspect ---------------------------------------------------------------------
describe("aspect", () => {
  // The frame is 400 × 200 px: a 2:1 box is as many fractions wide as tall.
  const radios = (checked) =>
    ["", "2:1", "4:1"].map((v) => `<input type="radio" name="ratio" value="${v}" ${v === checked ? "checked" : ""}>`).join("")

  test("a fixed ratio holds while resizing", async () => {
    mount(picker({ value: { x: 0.1, y: 0.1, width: 0.4, height: 0.4 }, attrs: 'data-reactive-box-ratio="2"' }))
    dragBy(document.getElementById("h-se"), 80, 0)
    await flush()
    expect(values()).toEqual({ x: 0.1, y: 0.1, width: 0.6, height: 0.6 })
  })

  test("the aspect field is read at drag start; picking another re-fits the box around its centre", async () => {
    mount(picker({ value: { x: 0.3, y: 0.3, width: 0.4, height: 0.4 }, attrs: 'data-reactive-box-aspect="ratio"', outside: radios("") }))
    dragBy(document.getElementById("h-se"), 40, 0) // free
    await flush()
    expect(values()).toEqual({ x: 0.3, y: 0.3, width: 0.5, height: 0.4 })
    const changes = listen("change")
    const four = document.querySelector('[name="ratio"][value="4:1"]')
    four.checked = true
    four.dispatchEvent(new window.Event("input", { bubbles: true }))
    four.dispatchEvent(new window.Event("change", { bubbles: true }))
    await flush()
    // area 0.2 at 2 (fractions): 0.6325 × 0.3162, centred on (0.55, 0.5)
    expect(values()).toEqual({ x: 0.2338, y: 0.3419, width: 0.6325, height: 0.3162 })
    expect(changes.filter((name) => name !== "ratio")).toEqual(["r[x]", "r[y]", "r[width]", "r[height]"])
    dragBy(document.getElementById("h-e"), 40, 0) // now locked
    await flush()
    const after = values()
    expect(after.width / after.height).toBeCloseTo(2, 2)
  })

  test("picking the free preset changes nothing", async () => {
    mount(picker({ attrs: 'data-reactive-box-aspect="ratio"', outside: radios("2:1") }))
    const free = document.querySelector('[name="ratio"][value=""]')
    free.checked = true
    free.dispatchEvent(new window.Event("change", { bubbles: true }))
    await flush()
    expect(values()).toEqual({ x: 0.1, y: 0.1, width: 0.5, height: 0.4 })
  })
})

// --- Keyboard -------------------------------------------------------------------
describe("keyboard", () => {
  test("arrows move 1%, Shift+arrows 10%, each step announced", async () => {
    mount(picker())
    press(box(), "ArrowRight")
    await flush()
    expect(values().x).toBe(0.11)
    expect(live()).toBe("Moved to 11%, 10%")
    press(box(), "ArrowDown", { shiftKey: true })
    await flush()
    expect(values().y).toBe(0.2)
    expect(live()).toBe("Moved to 11%, 20%")
  })

  test("Alt+arrows resize from the bottom-right corner, or from the focused handle", async () => {
    mount(picker())
    press(box(), "ArrowRight", { altKey: true })
    await flush()
    expect(values()).toEqual({ x: 0.1, y: 0.1, width: 0.51, height: 0.4 })
    expect(live()).toBe("Resized to 51% by 40%")
    press(document.getElementById("h-nw"), "ArrowUp", { altKey: true })
    await flush()
    expect(values()).toEqual({ x: 0.1, y: 0.09, width: 0.51, height: 0.41 })
  })

  test("input on each step; change and the action once, on keyup", async () => {
    mount(picker({ attrs: 'data-reactive-box-action="crop"' }))
    const inputs = listen("input")
    const changes = listen("change")
    for (let i = 0; i < 3; i++) key(box(), "ArrowRight")
    await flush()
    expect(inputs).toEqual(["r[x]", "r[x]", "r[x]"])
    expect(changes).toEqual([])
    expect(requests).toEqual([])
    key(box(), "ArrowRight", {}, "keyup")
    await flush()
    expect(changes).toEqual(["r[x]"])
    expect(requests).toHaveLength(1)
    expect(requests[0].act).toBe("crop")
    expect(requests[0].params).toMatchObject({ x: 0.13, y: 0.1, width: 0.5, height: 0.4 })
  })

  test("Escape before the keyup puts it back", async () => {
    mount(picker())
    key(box(), "ArrowRight")
    key(box(), "ArrowRight")
    key(box(), "Escape")
    await flush()
    expect(values().x).toBe(0.1)
    expect(live()).toBe("Cancelled")
  })

  test("a box removed while an arrow is held does not lock every other drag", async () => {
    mount(picker())
    key(box(), "ArrowRight") // held: no keyup
    const old = box()
    old.remove() // a stream replaced it; no focusout, no keyup reaches it
    document.querySelector("[data-reactive-frame]").append(old.cloneNode(true))
    layout()
    press(box(), "ArrowDown")
    await flush()
    expect(box().style.top).toBe("11%")
  })

  test("a step at the frame's edge stays there", async () => {
    mount(picker({ value: { x: 0.5, y: 0, width: 0.5, height: 0.4 } }))
    press(box(), "ArrowRight")
    press(box(), "ArrowUp")
    await flush()
    expect(values()).toEqual({ x: 0.5, y: 0, width: 0.5, height: 0.4 })
  })
})

// --- Points ---------------------------------------------------------------------
describe("point", () => {
  const POINT_FIELDS = json({ x: "f[x]", y: "f[y]" })
  const point = (within = "") =>
    `<span id="point" tabindex="0" style="position: absolute; left: 50%; top: 50%;" data-reactive-point="${POINT_FIELDS}"
       data-reactive-point-messages="${MESSAGES}" ${within}></span>`
  const pointFields = '<input type="hidden" name="f[x]" value="0.5"><input type="hidden" name="f[y]" value="0.5">'

  test("a point moves inside the frame, its fields fractions of the frame", async () => {
    mount(picker({ beside: point(), outside: pointFields }))
    dragBy(document.getElementById("point"), 100, 1000)
    await flush()
    expect(values("f")).toEqual({ x: 0.75, y: 1 })
  })

  test("within: a point inside the box moves within it, its fields fractions of the box", async () => {
    mount(picker({ inside: point('data-reactive-point-within="[data-reactive-box]"'), outside: pointFields }))
    // the box is 200 × 80 px: 20 px right is 0.1 of it, 8 px down 0.1
    dragBy(document.getElementById("point"), 20, 8)
    await flush()
    expect(values("f")).toEqual({ x: 0.6, y: 0.6 })
    dragBy(document.getElementById("point"), -1000, 0)
    await flush()
    expect(values("f")).toEqual({ x: 0, y: 0.6 })
    // moving the box leaves the point's fractions alone
    dragBy(box(), 40, 0)
    await flush()
    expect(values("f")).toEqual({ x: 0, y: 0.6 })
  })

  test("a point's arrows move it 1% of its bounds", async () => {
    mount(picker({ inside: point('data-reactive-point-within="[data-reactive-box]"'), outside: pointFields }))
    press(document.getElementById("point"), "ArrowLeft", { shiftKey: true })
    await flush()
    expect(values("f")).toEqual({ x: 0.4, y: 0.5 })
    expect(live()).toBe("Moved to 40%, 50%")
  })
})

// --- action: ------------------------------------------------------------------------
describe("action:", () => {
  test("is sent once on release, with x/y/width/height", async () => {
    mount(picker({ attrs: 'data-reactive-box-action="crop"' }))
    dragBy(box(), 40, 20)
    await flush()
    expect(requests).toHaveLength(1)
    expect(requests[0].act).toBe("crop")
    expect(requests[0].params).toMatchObject({ x: 0.2, y: 0.2, width: 0.5, height: 0.4 })
  })

  test("is not sent for a drag that ends where it started, nor without action:", async () => {
    mount(picker({ attrs: 'data-reactive-box-action="crop"' }))
    const [x0, y0] = at(box())
    dragBy(box(), 40, 0, { release: false })
    pointer("pointermove", document, x0, y0)
    pointer("pointerup", document, x0, y0)
    await flush()
    expect(requests).toEqual([])
    document.body.innerHTML = ""
    mount(picker())
    dragBy(box(), 40, 20)
    await flush()
    expect(requests).toEqual([])
  })

  test("works on a client-only root without action: (no token, nothing sent)", async () => {
    mount(picker({ token: "" }))
    dragBy(box(), 40, 20)
    await flush()
    expect(values().x).toBe(0.2)
    expect(requests).toEqual([])
  })
})

// --- Morphs ---------------------------------------------------------------------
describe("morphs", () => {
  const morphAttribute = (el, attributeName) => {
    const event = new window.CustomEvent("turbo:before-morph-attribute", { bubbles: true, cancelable: true, detail: { attributeName, mutationType: "update" } })
    el.dispatchEvent(event)
    return event.defaultPrevented
  }

  test("a morph during a drag cannot move the box, the fields or the hooks", () => {
    mount(picker())
    dragBy(box(), 40, 0, { release: false })
    expect(morphAttribute(box(), "style")).toBe(true)
    expect(morphAttribute(field("r[x]"), "value")).toBe(true)
    expect(morphAttribute(document.querySelector("[data-reactive-frame]"), "data-reactive-frame-active")).toBe(true)
    expect(morphAttribute(box(), "class")).toBe(false)
    pointer("pointerup", document, 0, 0)
    expect(morphAttribute(box(), "style")).toBe(false)
  })

  test("a morph that moved the box brings fields outside it along", async () => {
    mount(picker())
    box().style.left = "30%"
    box().dispatchEvent(new window.CustomEvent("turbo:morph-element", { bubbles: true }))
    await flush()
    expect(values().x).toBe(0.3)
  })

  test("a box removed mid-drag ends the drag, for good", async () => {
    mount(picker())
    dragBy(box(), 40, 0, { release: false })
    const frame = document.querySelector("[data-reactive-frame]")
    const marks = []
    new window.MutationObserver((records) => marks.push(...records)).observe(frame, { attributeFilter: ["data-reactive-frame-active"] })
    box().remove()
    pointer("pointermove", document, 400, 200)
    // The pointer moving on does not pick the old box up again.
    pointer("pointermove", document, 450, 250)
    await flush()
    expect(frame.hasAttribute("data-reactive-frame-active")).toBe(false)
    expect(marks).toHaveLength(1)
  })

  test("a release after a morph removed the box sends nothing over what the morph rendered", async () => {
    mount(picker({ attrs: 'data-reactive-box-action="crop"' }))
    dragBy(box(), 40, 20, { release: false })
    let changes = 0
    document.addEventListener("change", () => changes++)
    box().remove()
    pointer("pointerup", document, 0, 0)
    await flush()
    expect(changes).toBe(0)
    expect(requests).toEqual([])
    expect(document.querySelector("[data-reactive-frame]").hasAttribute("data-reactive-frame-active")).toBe(false)
  })
})

// --- scale: (issue #428) ------------------------------------------------------------
describe("scale:", () => {
  const morphed = (el) => el.dispatchEvent(new window.CustomEvent("turbo:morph-element", { bubbles: true }))
  const radios = (checked) =>
    ["", "2:1", "4:1"].map((v) => `<input type="radio" name="ratio" value="${v}" ${v === checked ? "checked" : ""}>`).join("")

  test("a field on a scale holds the fraction's 4 decimals times it, exactly, with no float noise", () => {
    expect(drag.scaled(0.25, 100)).toBe("25")
    expect(drag.scaled(0.1235, 100)).toBe("12.35")
    expect(drag.scaled(0.123456, 100)).toBe("12.35")
    expect(drag.scaled(0.07, 100)).toBe("7")
    expect(drag.scaled(0.57, 100)).toBe("57")
    expect(drag.scaled(0.1235, 640)).toBe("79.04")
    expect(drag.scaled(0.1236, 1000)).toBe("123.6")
    expect(drag.scaled(0.12345678, 1e5)).toBe("12350") // rounded to 4 decimals first
    // A scale that is not a power of ten keeps every digit the fraction has.
    expect(drag.scaled(0.1235, 25)).toBe("3.0875")
    expect(drag.scaled(0.0001, 640)).toBe("0.064")
    expect(drag.scaled(1 / 3, 1000 / 3)).toBe("111.1")
    // Scale 1 (the default) is the fraction rounded to 4 decimals, as before.
    for (const v of [0.123456, 0.1 + 0.2, 0.45545, 0.54455, 1, 0]) expect(drag.scaled(v, 1)).toBe(String(drag.round(v)))
    expect(drag.scaled(0.123456)).toBe("0.1235")
  })

  test("every scale the server accepts writes a finite number, at both ends", () => {
    const tiny = 2.2250738585072014e-308 // Ruby's Float::MIN
    for (const [value, scale] of [[0, tiny], [0.5, tiny], [1, tiny], [0, Number.MAX_VALUE], [0.5, Number.MAX_VALUE], [1, Number.MAX_VALUE]]) {
      expect(Number.isFinite(Number(drag.scaled(value, scale)))).toBe(true)
    }
    expect(drag.scaled(0, tiny)).toBe("0")
    expect(Number(drag.scaled(0.5, tiny))).toBeGreaterThan(0)
    expect(drag.scaled(1, Number.MAX_VALUE)).toBe(String(Number.MAX_VALUE))
  })

  test("a box on scale 25 writes and compares every digit (3.3375, not 3.338)", async () => {
    mount(picker({ scale: 25, value: { x: 0.1235, y: 0.1, width: 0.5, height: 0.4 } }))
    const inputs = listen("input")
    press(box(), "ArrowRight") // 0.1335 of the frame
    await flush()
    expect(field("r[x]").value).toBe("3.3375")
    expect(inputs).toEqual(["r[x]"])
    morphed(box())
    await flush()
    expect(inputs).toEqual(["r[x]"])
  })

  test("a box on scale 100 writes 25 where it wrote 0.25, one change on release", async () => {
    mount(picker({ scale: 100 }))
    const changes = listen("change")
    dragBy(box(), 60, 20) // x 0.1 -> 0.25, y 0.1 -> 0.2
    await flush()
    expect(field("r[x]").value).toBe("25")
    expect(values()).toEqual({ x: 25, y: 20, width: 50, height: 40 })
    expect(box().style.left).toBe("25%")
    expect(changes).toEqual(["r[x]", "r[y]"])
  })

  test("a field already holding its number is left alone: no input, no change ('50.0' is the 50 Ruby renders)", async () => {
    mount(picker({ scale: 100 }))
    for (const [key, text] of Object.entries({ x: "10.0", y: "10.0", width: "50.0", height: "40.0" })) field(`r[${key}]`).value = text
    const inputs = listen("input")
    const changes = listen("change")
    dragBy(box(), 40, 0) // x only
    await flush()
    expect(inputs).toEqual(["r[x]"])
    expect(changes).toEqual(["r[x]"])
    expect([field("r[x]").value, field("r[width]").value]).toEqual(["20", "50.0"])
  })

  test("a field moved and brought back gets its change (its text is now the client's), but no action", async () => {
    mount(picker({ scale: 100, attrs: 'data-reactive-box-action="crop"' }))
    field("r[x]").value = "10.0"
    const changes = listen("change")
    key(box(), "ArrowRight")
    key(box(), "ArrowLeft")
    key(box(), "ArrowLeft", {}, "keyup")
    await flush()
    expect(field("r[x]").value).toBe("10")
    expect(changes).toEqual(["r[x]"])
    expect(requests).toEqual([])
  })

  test("without scale:, a drag leaves a field that holds its number in other words alone", async () => {
    mount(picker())
    field("r[y]").value = "0.10"
    const changes = listen("change")
    dragBy(box(), 40, 0) // x only
    await flush()
    expect([field("r[x]").value, field("r[y]").value]).toEqual(["0.2", "0.10"])
    expect(changes).toEqual(["r[x]"])
  })

  test("without scale:, a morph writes an empty field, even with the box at 0", async () => {
    mount(picker({ value: { x: 0, y: 0.1, width: 0.5, height: 0.4 } }))
    field("r[x]").value = ""
    morphed(box())
    await flush()
    expect(field("r[x]").value).toBe("0")
  })

  test("an empty field is written, even with the box at 0", async () => {
    mount(picker({ scale: 100, value: { x: 0, y: 0.1, width: 0.5, height: 0.4 } }))
    field("r[x]").value = ""
    press(box(), "ArrowDown")
    await flush()
    expect([field("r[x]").value, field("r[y]").value]).toEqual(["0", "11"])
  })

  test("a cancel after a move writes the start back on the scale", async () => {
    mount(picker({ scale: 100 }))
    field("r[x]").value = "10.0"
    key(box(), "ArrowRight")
    expect(field("r[x]").value).toBe("11")
    key(box(), "Escape")
    await flush()
    expect(field("r[x]").value).toBe("10")
  })

  test("action: params stay fractions", async () => {
    mount(picker({ scale: 100, attrs: 'data-reactive-box-action="crop"' }))
    dragBy(box(), 60, 20)
    await flush()
    expect(requests).toHaveLength(1)
    expect(requests[0].params).toMatchObject({ x: 0.25, y: 0.2, width: 0.5, height: 0.4 })
  })

  test("a resize writes no float noise", async () => {
    mount(picker({ scale: 100 }))
    dragBy(document.getElementById("h-se"), 40, 20)
    await flush()
    expect([field("r[width]").value, field("r[height]").value]).toEqual(["60", "50"])
  })

  test("the keyboard writes the scale; the words stay whole percents; Escape puts the scaled value back", async () => {
    mount(picker({ scale: 100 }))
    press(box(), "ArrowRight")
    await flush()
    expect(field("r[x]").value).toBe("11")
    expect(live()).toBe("Moved to 11%, 10%")
    key(box(), "ArrowDown")
    expect(field("r[y]").value).toBe("11")
    key(box(), "Escape")
    await flush()
    expect(field("r[y]").value).toBe("10")
  })

  test("a re-fit to a new aspect writes the scale", async () => {
    mount(picker({ scale: 100, value: { x: 0.3, y: 0.3, width: 0.4, height: 0.4 }, attrs: 'data-reactive-box-aspect="ratio"', outside: radios("") }))
    const four = document.querySelector('[name="ratio"][value="4:1"]')
    four.checked = true
    four.dispatchEvent(new window.Event("change", { bubbles: true }))
    await flush()
    // area 0.16 at 2 (fractions): 0.5657 × 0.2828, centred on (0.5, 0.5)
    expect(values()).toEqual({ x: 21.72, y: 35.86, width: 56.57, height: 28.28 })
  })

  test("a morph that moved a scaled box brings its fields along in the scaled unit", async () => {
    mount(picker({ scale: 100 }))
    const inputs = listen("input")
    box().style.left = "30%"
    morphed(box())
    await flush()
    expect(field("r[x]").value).toBe("30")
    expect(inputs).toEqual(["r[x]"])
  })

  test("a morph that left a scaled box where its fields say writes nothing, float noise included", async () => {
    mount(picker({ scale: 100 }))
    // What `value: @box[:x] * 100` renders in Ruby for 0.1 and 0.57.
    field("r[x]").value = "10.000000000000002"
    field("r[y]").value = "9.999999999999998"
    const inputs = listen("input")
    morphed(box())
    await flush()
    expect(inputs).toEqual([])
    expect(field("r[x]").value).toBe("10.000000000000002")
  })

  test("a point on scale 100 writes percentages; a box's scale is its own", async () => {
    const fields = json({ x: "f[x]", y: "f[y]" })
    const point = (scale) =>
      `<span id="point" tabindex="0" style="position: absolute; left: 50%; top: 50%;" data-reactive-point="${fields}"
         data-reactive-point-messages="${MESSAGES}" ${scale ? `data-reactive-point-scale="${scale}"` : ""}></span>`
    mount(picker({ beside: point(100), outside: '<input type="hidden" name="f[x]" value="50"><input type="hidden" name="f[y]" value="50">' }))
    dragBy(document.getElementById("point"), 100, 1000)
    await flush()
    expect([field("f[x]").value, field("f[y]").value]).toEqual(["75", "100"])
    document.body.innerHTML = ""
    mount(picker({ scale: 100, beside: point(), outside: '<input type="hidden" name="f[x]" value="0.5"><input type="hidden" name="f[y]" value="0.5">' }))
    dragBy(document.getElementById("point"), 100, 1000)
    await flush()
    expect([field("f[x]").value, field("f[y]").value]).toEqual(["0.75", "1"])
  })
})

test("the drag module is a feature of its own", async () => {
  const runtime = await import("../../app/javascript/phlex/reactive/runtime.js")
  expect(runtime.reactiveFeatureNames()).toContain("drag")
})
