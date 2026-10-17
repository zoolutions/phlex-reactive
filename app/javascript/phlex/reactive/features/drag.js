// phlex/reactive/features/drag — move and resize a box, or move a point,
// inside a frame, with the result in fields as fractions of the frame (issue
// #416). One of the feature modules the core imports on demand (issue #275);
// in the default client it is part of the one file.
//
// The markup is the Ruby helpers' (Phlex::Reactive::Component::Drag):
//
//   data-reactive-frame                     the coordinate space: its padding box
//   data-reactive-box='{"x":"crop[x]",…}'   a box and the names of its fields
//     -min / -ratio / -aspect / -action / -busy / -messages
//   data-reactive-box-handle="se"           an edge or corner (inside the box)
//   data-reactive-point='{"x":…,"y":…}'     a point (its centre)
//     -within / -action / -busy / -messages
//
// and what it sets while a pointer drag is on, for the app's CSS:
//
//   data-reactive-frame-active   on the frame
//   data-reactive-dragging       on the pressed box, handle or point
//
// Where an element is lives in its own inline style — left/top/width/height
// in percent, rendered by the server and written here — so a morph that
// renders new values moves it, and nothing is cached between drags. Each
// field's .value is the same number as a fraction, rounded to 4 decimals and
// written as set_value writes (core.setValue: a bubbling `input` when it
// moved), at most once a frame while a pointer drags; one `change` follows on
// release. A box's x/y/width/height are fractions of the frame; a point's x/y
// of the element it sits in that matches its -within selector, else of the
// frame.
//
// Input is pointer events: mouse, pen and touch behave the same (the helpers
// render touch-action: none, so a finger drag does not scroll), and a drag
// starts after a 4 px move. The keyboard moves the focused box or point
// directly — arrows 1%, Shift 10%, Alt resizes — and the key's release is
// the release. A declared action is sent once per release through the
// root's own pipeline (core.proceed).
//
// This module never imports the core: it reaches a controller through the
// `core` handle (core.owns, core.proceed, core.setValue).

const FRAME = "[data-reactive-frame]"
const BOX = "[data-reactive-box]"
const POINT = "[data-reactive-point]"
const HANDLE = "[data-reactive-box-handle]"
const GRIP = `${HANDLE},${POINT},${BOX}`
const ROOT = '[data-controller~="reactive"]'
const FIELD = "input,textarea,select,[contenteditable]"
const DRAGGING = "data-reactive-dragging"
const ACTIVE = "data-reactive-frame-active"
const THRESHOLD = 4 // px a press must move before it is a drag
const EDGE = 40 // px from the window's top or bottom where auto-scroll starts
const SPEED = 12 // px auto-scroll moves per frame
const ARROWS = { ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1] }
const STYLE = { x: "left", y: "top", width: "width", height: "height" }

// controller -> the removals of what connect() added.
const wired = new WeakMap()
// reactive root element -> its core handle, for a morph of a box in it.
const cores = new WeakMap()
// The one drag on the page, by pointer or keyboard, or null.
let drag = null
// The page's live region (re-created after a Turbo visit replaced <body>),
// and the frame that will write its next words.
let live
let speaking
let morphs = false

export function connect(controller, core) {
  const root = controller.element
  cores.set(root, core)
  // Empty on the page before anything is announced (a screen reader often
  // ignores a region that arrives already holding words).
  liveRegion()
  holdMorphs()
  const on = [
    ["pointerdown", (event) => pointerDown(event, core, root)],
    ["keydown", (event) => keyDown(event, core, root)],
    ["keyup", (event) => drag?.keyboard && event.target === drag.grip && ARROWS[event.key] && release()],
    ["focusout", (event) => drag?.keyboard && event.target === drag.grip && release()],
    ["input", (event) => aspectChanged(event, core, root)],
    ["change", (event) => aspectChanged(event, core, root)],
  ]
  for (const [type, fn] of on) root.addEventListener(type, fn)
  wired.set(controller, () => {
    for (const [type, fn] of on) root.removeEventListener(type, fn)
  })
}

export function disconnect(controller) {
  wired.get(controller)?.()
  wired.delete(controller)
  cores.delete(controller.element)
  // A root that leaves mid-drag (a replace, a navigation) ends its drag.
  if (drag?.root === controller.element) settle(drag)
}

// --- Geometry: fractions, 0..1 on each axis --------------------------------------
const clamp = (value, low, high) => Math.min(Math.max(value, low), high)

export const round = (value) => Math.round(value * 1e4) / 1e4

// A position as the fields will hold it: each number rounded to 4 decimals,
// a box's x/y then pulled in so it still ends inside the frame (rounded
// apart, 0.45545 + 0.54455 is 0.4555 + 0.5446 = 1.0001).
export function snap(value) {
  const out = { x: round(value.x), y: round(value.y) }
  if (value.width != null) {
    out.width = round(value.width)
    out.height = round(value.height)
    out.x = Math.min(out.x, round(1 - out.width))
    out.y = Math.min(out.y, round(1 - out.height))
  }
  return out
}

export function moveBox(b, dx, dy) {
  return { x: clamp(b.x + dx, 0, 1 - b.width), y: clamp(b.y + dy, 0, 1 - b.height), width: b.width, height: b.height }
}

export function movePoint(p, dx, dy) {
  return { x: clamp(p.x + dx, 0, 1), y: clamp(p.y + dy, 0, 1) }
}

// Resize from `edge` (a handle: n, se, …) by (dx, dy), the opposite side
// staying put, inside the frame and never below `min`. `ratio` is the locked
// width over height IN FRACTIONS (0: free): on a corner the axis the pointer
// moved more drives, on an edge the other axis grows around the box's centre.
export function resizeBox(b, edge, dx, dy, min, ratio) {
  const [n, e, s, w] = ["n", "e", "s", "w"].map((side) => edge.includes(side))
  const right = b.x + b.width
  const bottom = b.y + b.height
  const cx = b.x + b.width / 2
  const cy = b.y + b.height / 2
  // From the side that stays to the frame's edge (an axis no handle drives,
  // with a ratio: around its centre).
  const roomW = e ? 1 - b.x : w ? right : ratio ? 2 * Math.min(cx, 1 - cx) : 1
  const roomH = s ? 1 - b.y : n ? bottom : ratio ? 2 * Math.min(cy, 1 - cy) : 1
  let width = b.width + (e ? dx : w ? -dx : 0)
  let height = b.height + (s ? dy : n ? -dy : 0)
  if (ratio) {
    const byWidth = (e || w) && (!(n || s) || Math.abs(width - b.width) >= Math.abs(height - b.height) * ratio)
    const high = Math.min(roomW, roomH * ratio)
    width = clamp(byWidth ? width : height * ratio, Math.min(Math.max(min, min * ratio), high), high)
    height = width / ratio
  } else {
    if (e || w) width = clamp(width, Math.min(min, roomW), roomW)
    if (n || s) height = clamp(height, Math.min(min, roomH), roomH)
  }
  return { x: w ? right - width : e ? b.x : cx - width / 2, y: n ? bottom - height : s ? b.y : cy - height / 2, width, height }
}

// The box at a new `ratio` (fractions): the same area, centred where it was,
// inside the frame and no smaller than `min`.
export function fitBox(b, ratio, min) {
  const high = Math.min(1, ratio)
  const width = clamp(Math.sqrt(b.width * b.height * ratio), Math.min(Math.max(min, min * ratio), high), high)
  const height = width / ratio
  return {
    x: clamp(b.x + b.width / 2 - width / 2, 0, 1 - width),
    y: clamp(b.y + b.height / 2 - height / 2, 0, 1 - height),
    width,
    height,
  }
}

// "16:9", "1.5" or "" (free): width over height, or 0 for free.
export function parseRatio(text) {
  const [width, height = 1, extra] = String(text ?? "").split(":").map(Number)
  const ratio = extra === undefined ? width / height : 0
  return ratio > 0 && Number.isFinite(ratio) ? ratio : 0
}

// --- Reading and writing an element ------------------------------------------------
const attr = (el, name) => el?.getAttribute?.(`data-reactive-${name}`)
const json = (value, fallback) => {
  try {
    return value == null ? fallback : JSON.parse(value)
  } catch {
    return fallback
  }
}
const kind = (el) => (el.matches(POINT) ? "point" : "box")
const keysOf = (el) => (kind(el) === "point" ? ["x", "y"] : ["x", "y", "width", "height"])

function read(el) {
  const value = {}
  for (const key of keysOf(el)) value[key] = (parseFloat(el.style[STYLE[key]]) || 0) / 100
  return value
}

function write(el, value) {
  for (const key of keysOf(el)) el.style[STYLE[key]] = `${Math.round(value[key] * 1e4) / 100}%`
}

// An element's padding box in viewport px: what CSS % on a child resolves against.
function paddingBox(el) {
  const rect = el.getBoundingClientRect()
  return {
    left: rect.left + (el.clientLeft || 0),
    top: rect.top + (el.clientTop || 0),
    width: el.clientWidth || rect.width,
    height: el.clientHeight || rect.height,
  }
}

// A point's bounds: the element it sits in that matches -within, else its frame.
function boundsOf(el, frame) {
  try {
    return el.parentElement.closest(attr(el, "point-within") || FRAME) ?? frame
  } catch {
    return frame // an invalid selector
  }
}

// The root's own fields of these names (a nested root's are its own, issue #15).
function named(root, core, name) {
  return [...root.querySelectorAll("[name]")].filter((field) => field.name === name && core.owns(field))
}

function fieldsOf(el, root, core) {
  const names = json(attr(el, kind(el)), {})
  const fields = {}
  for (const key of keysOf(el)) {
    const [field] = named(root, core, names[key])
    if (field) fields[key] = field
  }
  return fields
}

// The locked ratio in fractions (the pixel ratio over the frame's), or 0.
function ratioOf(box, frame, root, core) {
  const name = attr(box, "box-aspect")
  const field = name && named(root, core, name).find((f) => !/^(radio|checkbox)$/.test(f.type) || f.checked)
  const ratio = name ? parseRatio(field?.value) : Number(attr(box, "box-ratio")) || 0
  const { width, height } = paddingBox(frame)
  return ratio && width && height ? (ratio * height) / width : 0
}

// What a drag (or a key, or a re-fit) works on, read off the element now.
function begin(core, root, grip, keyboard) {
  const el = grip.matches(HANDLE) ? grip.closest(BOX) : grip
  const frame = el?.closest(FRAME)
  if (!frame) return null
  const value = read(el)
  const fields = fieldsOf(el, root, core)
  const point = kind(el) === "point"
  return {
    core,
    root,
    grip,
    el,
    frame,
    keyboard,
    bounds: point ? boundsOf(el, frame) : frame,
    edge: attr(grip, "box-handle"),
    start: value,
    value,
    ratio: point ? 0 : ratioOf(el, frame, root, core),
    min: Number(attr(el, "box-min")) || 0,
    fields,
    before: Object.fromEntries(Object.entries(fields).map(([key, field]) => [key, field.value])),
  }
}

// Write the fields now (set_value's write: `input` on each that moved).
function flush(record) {
  cancelAnimationFrame(record.writing)
  record.writing = 0
  for (const [key, field] of Object.entries(record.fields)) record.core.setValue(field, String(round(record.value[key])))
}

// --- Pointer --------------------------------------------------------------------------
function pointerDown(event, core, root) {
  forgetRemoved()
  if (drag || event.button > 0 || event.isPrimary === false || event.target.closest?.(FIELD)) return
  const grip = event.target.closest?.(GRIP)
  const record = grip && core.owns(grip) && begin(core, root, grip, false)
  if (!record) return
  const x0 = event.clientX
  const y0 = event.clientY
  const bounds = paddingBox(record.bounds)
  record.p0 = [(x0 - bounds.left) / bounds.width, (y0 - bounds.top) / bounds.height]
  // Only the pointer that pressed drives the drag: a second finger is not it.
  const mine = (e) => e.pointerId === event.pointerId
  const move = (e) => {
    // (A drag that ended before the release — its element left — stays over.)
    if (!mine(e) || record.over) return
    if (drag) return follow(e.clientX, e.clientY)
    if (Math.abs(e.clientX - x0) <= THRESHOLD && Math.abs(e.clientY - y0) <= THRESHOLD) return
    start(record)
    follow(e.clientX, e.clientY)
  }
  const up = (e) => {
    if (!mine(e)) return
    end()
    if (drag) suppressClick(), release()
  }
  const abort = (e) => {
    if (e.type === "pointercancel" && !mine(e)) return
    end()
    if (drag) cancel()
  }
  const escape = (e) => e.key === "Escape" && drag && (e.preventDefault(), abort(e))
  const on = [
    ["pointermove", move],
    ["pointerup", up],
    ["pointercancel", abort],
    ["keydown", escape],
  ]
  for (const [type, fn] of on) document.addEventListener(type, fn)
  function end() {
    for (const [type, fn] of on) document.removeEventListener(type, fn)
  }
}

// The click a pointer drag ends with is not one.
function suppressClick() {
  const stop = (event) => (event.preventDefault(), event.stopPropagation())
  window.addEventListener("click", stop, { capture: true, once: true })
  setTimeout(() => window.removeEventListener("click", stop, { capture: true }))
}

function start(record) {
  drag = record
  record.grip.setAttribute(DRAGGING, "")
  record.frame.setAttribute(ACTIVE, "")
  record.select = document.documentElement.style.userSelect
  document.documentElement.style.userSelect = "none"
}

// The pointer is at (x, y): the element goes where the pointer's move since
// the press puts it, measured in its bounds as they are NOW (a scroll moved them).
function follow(x, y) {
  const record = drag
  // A morph or a stream took the element away: the drag is over.
  if (!record.el.isConnected) return settle(record)
  record.x = x
  record.y = y
  const bounds = paddingBox(record.bounds)
  const dx = (x - bounds.left) / bounds.width - record.p0[0]
  const dy = (y - bounds.top) / bounds.height - record.p0[1]
  const { start: from, edge } = record
  record.value = snap(
    kind(record.el) === "point"
      ? movePoint(from, dx, dy)
      : edge
        ? resizeBox(from, edge, dx, dy, record.min, record.ratio)
        : moveBox(from, dx, dy),
  )
  write(record.el, record.value)
  record.writing ||= requestAnimationFrame(() => flush(record))
  scroll(y)
}

// Near the window's top or bottom edge, scroll one step a frame until the
// pointer leaves the edge (a frame taller than the window).
function scroll(y) {
  drag.wy = y < EDGE ? -SPEED : y > window.innerHeight - EDGE ? SPEED : 0
  if (drag.wy && !drag.raf) {
    const step = () => {
      if (!drag?.wy) return drag && (drag.raf = 0)
      window.scrollBy(0, drag.wy)
      follow(drag.x, drag.y)
      if (drag) drag.raf = requestAnimationFrame(step)
    }
    drag.raf = requestAnimationFrame(step)
  }
}

// A drag whose element left the page (a stream replaced it while an arrow
// was held: no keyup or focusout reaches it) is over, not in the way.
function forgetRemoved() {
  if (drag && !drag.el.isConnected) settle(drag)
}

// --- Keyboard --------------------------------------------------------------------------
// A focused box, handle or point: the arrows move it (Shift: ten times as
// far), Alt+arrows resize a box from the focused handle or the bottom-right
// corner, Escape puts it back. The key's release ends the step (`change`, the
// action); each step is announced in the element's own words.
function keyDown(event, core, root) {
  forgetRemoved()
  const grip = event.target
  // (A pointer drag, or a key held on another element, owns the drag.)
  if (!grip?.matches?.(GRIP) || !core.owns(grip) || (drag && (!drag.keyboard || drag.grip !== grip))) return
  if (event.key === "Escape") return drag && (event.preventDefault(), cancel())
  const arrow = ARROWS[event.key]
  if (!arrow) return
  event.preventDefault()
  drag ??= begin(core, root, grip, true)
  if (!drag) return
  const [dx, dy] = arrow.map((d) => d * (event.shiftKey ? 0.1 : 0.01))
  const resize = event.altKey && kind(drag.el) === "box"
  const now = drag.value
  drag.value = snap(
    kind(drag.el) === "point"
      ? movePoint(now, dx, dy)
      : resize
        ? resizeBox(now, drag.edge ?? "se", dx, dy, drag.min, drag.ratio)
        : moveBox(now, dx, dy),
  )
  write(drag.el, drag.value)
  flush(drag)
  announce(drag, resize ? "resized" : "moved")
}

function liveRegion() {
  if (!live?.isConnected) {
    live = document.createElement("div")
    live.setAttribute("aria-live", "polite")
    live.setAttribute("data-reactive-drag-live", "")
    live.style.cssText = "position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap"
    document.body.append(live)
  }
  return live
}

// Clear the region now and write the words on the next frame, so a change is
// heard even when the words are the same as the last ones.
function announce(record, name) {
  let words = json(attr(record.el, `${kind(record.el)}-messages`), {})[name] ?? ""
  for (const key of keysOf(record.el)) words = words.replaceAll(`{${key}}`, Math.round(record.value[key] * 100))
  const region = liveRegion()
  region.textContent = ""
  cancelAnimationFrame(speaking)
  speaking = requestAnimationFrame(() => (region.textContent = words))
}

// --- Aspect ---------------------------------------------------------------------------
// The field a box reads its ratio from changed (a preset radio was picked):
// the box re-fits to it around its centre, inside the frame — a committed
// change, like a release. A box already at that ratio stays as it is.
function aspectChanged(event, core, root) {
  const name = event.target?.name
  if (!name) return
  for (const box of root.querySelectorAll("[data-reactive-box-aspect]")) {
    if (attr(box, "box-aspect") !== name || box === drag?.el || !core.owns(box)) continue
    const record = begin(core, root, box, true)
    const { ratio, start: b } = record ?? {}
    if (!ratio || Math.abs(b.width / b.height / ratio - 1) < 0.005) continue
    record.value = snap(fitBox(b, ratio, record.min))
    write(box, record.value)
    flush(record)
    commit(record)
  }
}

// --- Release / cancel ---------------------------------------------------------------
function release() {
  const record = drag
  flush(record)
  settle(record)
  commit(record)
}

// One `change` on each field the drag moved, and the action, once, when the
// element ended somewhere new.
function commit(record) {
  for (const [key, field] of Object.entries(record.fields)) {
    if (field.value !== record.before[key]) field.dispatchEvent(new Event("change", { bubbles: true }))
  }
  const name = kind(record.el)
  const action = attr(record.el, `${name}-action`)
  const params = {}
  for (const key of keysOf(record.el)) params[key] = round(record.value[key])
  if (!action || keysOf(record.el).every((key) => params[key] === round(record.start[key]))) return
  record.core.proceed(record.el, action, JSON.stringify(params), json(attr(record.el, `${name}-busy`)))
}

function cancel() {
  const record = drag
  record.value = record.start
  write(record.el, record.start)
  flush(record)
  if (record.keyboard) announce(record, "cancelled")
  settle(record)
}

// Undo everything the drag set: the markers, the frame loops, the text selection.
function settle(record) {
  drag = null
  record.over = true
  cancelAnimationFrame(record.raf)
  cancelAnimationFrame(record.writing)
  record.grip.removeAttribute(DRAGGING)
  record.frame.removeAttribute(ACTIVE)
  if (!record.keyboard) document.documentElement.style.userSelect = record.select ?? ""
}

// --- Morphs ----------------------------------------------------------------------------
// A morph that arrives mid-drag (a reply, a broadcast) does not move the
// dragged element, write its fields or drop the markers: the drag wins until
// release. A morph that moved a box or point outside a drag brings its fields
// along — they may sit outside what the morph rendered.
function holdMorphs() {
  if (morphs) return
  morphs = true
  document.addEventListener("turbo:before-morph-attribute", (event) => {
    const el = event.target
    const name = event.detail?.attributeName
    if (!drag) return
    const held =
      (el === drag.el && name === "style") ||
      (el === drag.grip && name === DRAGGING) ||
      (el === drag.frame && name === ACTIVE) ||
      (name === "value" && Object.values(drag.fields).includes(el))
    if (held) event.preventDefault()
  })
  // (Every morphed element fires this: the cheap check first.)
  document.addEventListener("turbo:morph-element", (event) => {
    const el = event.target
    if (el === drag?.el || !el.matches?.(`${BOX},${POINT}`)) return
    const root = el.closest(ROOT)
    const core = cores.get(root)
    if (!core?.owns(el)) return
    const value = read(el)
    for (const [key, field] of Object.entries(fieldsOf(el, root, core))) {
      if (round(Number(field.value)) !== round(value[key])) core.setValue(field, String(round(value[key])))
    }
  })
}
