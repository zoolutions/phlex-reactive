// phlex/reactive/features/sortable — drag rows to reorder a list, or drag a
// row in from another list, and send ONE declared action with the row and its
// new position (issue #350). One of the feature modules the core imports on
// demand (issue #275); in the default client it is part of the one file.
//
// The markup is the Ruby helpers' (Phlex::Reactive::Component::Sortable):
//
//   data-reactive-sortable="move"          a list; the action a drop calls
//     -group / -handle / -name / -from / -params / -disabled / -busy / -messages
//   data-reactive-sortable-source="name"   a list whose rows are COPIED in
//   data-reactive-sortable-item='7'        a row and its JSON-typed key
//
// and what it sets while a drag is on, for the app's CSS:
//
//   data-reactive-sortable-active          on the list being dragged from/over
//   data-reactive-sortable-dragging        on the dragged row (or its clone)
//   data-reactive-sortable-placeholder     the gap that marks the drop point
//
// Input is pointer events, not HTML5 drag and drop: mouse, pen and touch
// behave the same, the dragged row is the real row under the pointer (no
// ghost image), and the keyboard gets the same moves. A drag starts after a
// 4 px move, or on touch after a 200 ms press, so taps, clicks and scrolling
// still work.
//
// A drop moves the row in the DOM at once (a drag-in inserts nothing: the
// target's action decides and its reply renders the row), then sends the
// action through the root's own pipeline (core.proceed): the signed token,
// the request queue, the busy state, the reply. The row goes back to where it
// was when the request fails, is vetoed, or its reply does not render the
// list. A reply that does render it (a morph) puts the rows in the server's
// order: Idiomorph matches them by id.
//
// The geometry is every element's own getBoundingClientRect() — nothing is
// cached across moves — so a test without layout stubs it per element.
//
// This module never imports the core: it reaches a controller through the
// `core` handle (core.owns, core.proceed).

const LIST = "[data-reactive-sortable]"
const SOURCE = "[data-reactive-sortable-source]"
const ITEM = "[data-reactive-sortable-item]"
const ROOT = '[data-controller~="reactive"]'
const FIELD = "input,textarea,select,[contenteditable]"
const THRESHOLD = 4 // px a press must move before it is a drag
const PRESS_MS = 200 // how long a touch is held before it picks a row up
const EDGE = 40 // px from an edge where auto-scroll starts
const SPEED = 12 // px auto-scroll moves per frame

// controller -> the removals of what connect() added.
const wired = new WeakMap()
// reactive root element -> its core handle: a drop into a list of ANOTHER root
// (a drag-in, a move between roots of one group) sends through that root.
const cores = new WeakMap()
// The one drag on the page, by pointer or keyboard, or null.
let drag = null
// The page's live region (re-created after a Turbo visit replaced <body>),
// and the frame that will write its next words.
let live
let speaking

export function connect(controller, core) {
  const root = controller.element
  cores.set(root, core)
  // The live region is on the page, empty, before anything is announced: a
  // screen reader often ignores a region that arrives already holding words.
  liveRegion()
  const press = (event) => pointerDown(event, core)
  const key = (event) => keyDown(event, core)
  root.addEventListener("pointerdown", press)
  root.addEventListener("keydown", key)
  wired.set(controller, () => {
    root.removeEventListener("pointerdown", press)
    root.removeEventListener("keydown", key)
  })
}

export function disconnect(controller) {
  wired.get(controller)?.()
  wired.delete(controller)
  cores.delete(controller.element)
  // A root that leaves mid-drag (a replace, a navigation) ends its drag.
  if (drag && rootOf(drag.origin) === controller.element) cancel()
}

const attr = (el, name = "") => el?.getAttribute?.(`data-reactive-sortable${name}`)
const json = (value, fallback) => {
  try {
    return value == null ? fallback : JSON.parse(value)
  } catch {
    return fallback
  }
}
const rootOf = (el) => el?.closest?.(ROOT)
const containerOf = (item) => item.parentElement?.closest(`${LIST},${SOURCE}`)
// A list's rows: its items whose closest list is this one (a list nested in a
// row keeps its own rows), minus the one being dragged.
const itemsOf = (list) =>
  [...list.querySelectorAll(ITEM)].filter((el) => el !== drag?.row && containerOf(el) === list)
const keyOf = (item) => json(attr(item, "-item"), null)
const disabled = (el) => attr(el, "-disabled") === "true"
const inside = (el, x, y) => {
  const rect = el.getBoundingClientRect()
  return x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom
}
// The lists a row from `origin` can be dropped into: every enabled sortable of
// its group whose root has a core, or (no group) the list itself.
const targetsFor = (origin) => {
  const group = attr(origin, "-group")
  if (!group) return origin.matches(LIST) ? [origin] : []
  return [...document.querySelectorAll(LIST)].filter(
    (list) => attr(list, "-group") === group && !disabled(list) && cores.has(rootOf(list)),
  )
}

// The row a gesture on `target` may pick up, or nothing: a row of a list this
// root owns (a nested root's rows are its own, issue #15), neither of them
// disabled, and no request of that root in flight.
function grab(target, core) {
  const item = target?.closest?.(ITEM)
  const list = item && containerOf(item)
  if (drag || !list || !core.owns(list) || disabled(list) || disabled(item)) return
  if (rootOf(list)?.getAttribute("aria-busy") === "true") return
  return { item, list }
}

// --- Pointer ----------------------------------------------------------------
function pointerDown(event, core) {
  if (event.button > 0 || event.isPrimary === false) return
  const grabbed = grab(event.target, core)
  if (!grabbed) return
  const handle = attr(grabbed.list, "-handle")
  if (handle ? !grabbed.item.contains(event.target.closest(handle)) : event.target.closest(FIELD)) return

  const x0 = event.clientX
  const y0 = event.clientY
  // Only the pointer that pressed drives the drag: a second finger is not it.
  const mine = (e) => e.pointerId === event.pointerId
  const touch = event.pointerType === "touch"
  let ready = !touch
  const timer = touch && setTimeout(() => (ready = true), PRESS_MS)
  const move = (e) => {
    if (!mine(e)) return
    if (drag) return follow(e.clientX, e.clientY)
    if (Math.abs(e.clientX - x0) <= THRESHOLD && Math.abs(e.clientY - y0) <= THRESHOLD) return
    // A finger that moves before the press is up is scrolling.
    if (!ready) return end()
    start(grabbed, core, e)
    follow(e.clientX, e.clientY)
  }
  // While a touch drag is on, the page must not scroll under it.
  const hold = (e) => drag && e.cancelable && e.preventDefault()
  const up = (e) => {
    if (!mine(e)) return
    end()
    if (drag) suppressClick(), drop()
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
    ["touchmove", hold, { passive: false }],
  ]
  for (const [type, fn, options] of on) document.addEventListener(type, fn, options)
  function end() {
    clearTimeout(timer)
    for (const [type, fn] of on) document.removeEventListener(type, fn)
  }
}

// The click a pointer drag ends with (over a button in the row) is not one.
function suppressClick() {
  const stop = (event) => (event.preventDefault(), event.stopPropagation())
  window.addEventListener("click", stop, { capture: true, once: true })
  setTimeout(() => window.removeEventListener("click", stop, { capture: true }))
}

// Lift the row (a source's row: a clone of it) under the pointer, and leave
// a placeholder of its height where it was.
function start({ item, list }, core, event) {
  const rect = item.getBoundingClientRect()
  const source = list.matches(SOURCE)
  const row = source ? item.cloneNode(true) : item
  if (source) {
    // A clone must not connect a controller or duplicate an id.
    for (const el of [row, ...row.querySelectorAll("[id],[data-controller]")]) {
      el.removeAttribute("id")
      el.removeAttribute("data-controller")
    }
    document.body.append(row)
  }
  const placeholder = document.createElement(item.tagName)
  placeholder.setAttribute("data-reactive-sortable-placeholder", "")
  placeholder.setAttribute("aria-hidden", "true")
  placeholder.style.height = `${rect.height}px`
  drag = begin({ core, item, row, origin: list, source, placeholder, style: row.getAttribute("style") })
  drag.dx = event.clientX - rect.left
  drag.dy = event.clientY - rect.top
  drag.select = document.documentElement.style.userSelect
  document.documentElement.style.userSelect = "none"
  if (!source) item.before(placeholder)
  Object.assign(row.style, {
    position: "fixed",
    left: `${rect.left}px`,
    top: `${rect.top}px`,
    width: `${rect.width}px`,
    height: `${rect.height}px`,
    margin: "0",
    boxSizing: "border-box",
    zIndex: "2147483647",
    pointerEvents: "none",
  })
}

// The drag record both inputs share; marks the row and its list.
function begin(record) {
  const { row, origin, source } = record
  record.index = itemsOf(origin).indexOf(record.item)
  record.target = source ? null : origin
  row.setAttribute("data-reactive-sortable-dragging", "")
  activate(origin, true)
  return record
}

const activate = (list, on) => list?.toggleAttribute("data-reactive-sortable-active", on)

// Put `el` at `index` among a list's rows (`items`, which leave `el` out):
// before the row there, or after the last one, or into the empty list.
function insertAt(list, items, index, el) {
  if (items[index]) items[index].before(el)
  else if (items.length) items.at(-1).after(el)
  else list.append(el)
}

function follow(x, y) {
  drag.x = x
  drag.y = y
  drag.row.style.left = `${x - drag.dx}px`
  drag.row.style.top = `${y - drag.dy}px`
  const list = targetsFor(drag.origin).find((el) => inside(el, x, y))
  if (list) place(list, x, y)
  // Off every list, a drag-in has nowhere to land; a move keeps its last spot.
  else if (drag.source) retarget(null), drag.placeholder.remove()
  scroll(x, y)
}

function retarget(list) {
  if (drag.target !== drag.origin) activate(drag.target, false)
  drag.target = list
  activate(list, true)
}

// The placeholder goes before the first row whose middle is past the pointer.
// A list whose first two rows share a top is laid out across, not down.
function place(list, x, y) {
  retarget(list)
  const items = itemsOf(list)
  const [a, b] = items.map((el) => el.getBoundingClientRect())
  const across = b && a.top === b.top && a.left !== b.left
  const index = items.findIndex((el) => {
    const rect = el.getBoundingClientRect()
    return across ? x < rect.left + rect.width / 2 : y < rect.top + rect.height / 2
  })
  insertAt(list, items, index < 0 ? items.length : index, drag.placeholder)
}

// Near the top or bottom edge of the list being dragged over (when it
// scrolls) or of the window, scroll one step a frame until the pointer leaves
// the edge.
function scroll(x, y) {
  const list = drag.target ?? drag.origin
  const rect = list.getBoundingClientRect()
  const scrolls = list.scrollHeight > list.clientHeight
  drag.vy = scrolls ? (y < rect.top + EDGE ? -SPEED : y > rect.bottom - EDGE ? SPEED : 0) : 0
  drag.wy = y < EDGE ? -SPEED : y > window.innerHeight - EDGE ? SPEED : 0
  if ((drag.vy || drag.wy) && !drag.raf) {
    const step = () => {
      if (!drag || !(drag.vy || drag.wy)) return drag && (drag.raf = 0)
      ;(drag.target ?? drag.origin).scrollTop += drag.vy
      if (drag.wy) window.scrollBy(0, drag.wy)
      follow(drag.x, drag.y)
      drag.raf = requestAnimationFrame(step)
    }
    drag.raf = requestAnimationFrame(step)
  }
}

// --- Keyboard ----------------------------------------------------------------
// A focused row: Space/Enter picks it up, the arrows move it (← / → into the
// previous / next list of its group), Space/Enter drops it, Escape (or Tab)
// puts it back. Each step is announced in the list's own words.
function keyDown(event, core) {
  const key = event.key
  if (drag?.keyboard) {
    // (A nested root's row bubbles to every ancestor root: only the root that
    // picked the row up answers.)
    if (event.target !== drag.row || drag.core !== core) return
    const handled = {
      " ": drop,
      Enter: drop,
      Escape: cancel,
      Tab: cancel,
      ArrowUp: () => step(-1),
      ArrowDown: () => step(1),
      ArrowLeft: () => hop(-1),
      ArrowRight: () => hop(1),
    }[key]
    if (!handled) return
    if (key !== "Tab") event.preventDefault()
    return handled()
  }
  if (key !== " " && key !== "Enter") return
  const grabbed = grab(event.target, core)
  if (!grabbed || grabbed.item !== event.target || grabbed.list.matches(SOURCE)) return
  event.preventDefault()
  drag = begin({ core, keyboard: true, item: grabbed.item, row: grabbed.item, origin: grabbed.list, style: grabbed.item.getAttribute("style") })
  announce("picked")
}

function step(by) {
  const items = itemsOf(drag.target)
  // (itemsOf leaves the dragged row out: it sits before items[index].)
  const to = position() + by
  // Past either end the row stays, and where it is is said again.
  if (to >= 0 && to <= items.length) insertAt(drag.target, items, to, drag.row)
  moved()
}

function hop(by) {
  const lists = targetsFor(drag.origin)
  const list = lists[lists.indexOf(drag.target) + by]
  if (list) {
    const index = position()
    retarget(list)
    insertAt(list, itemsOf(list), index, drag.row)
  }
  moved()
}

function moved() {
  drag.row.focus?.()
  announce("moved")
}

// The dragged row's index in its target list (the drop's `position`).
function position() {
  const items = itemsOf(drag.target)
  const row = drag.keyboard ? drag.row : drag.placeholder
  // (itemsOf leaves the dragged row out: count the rows before it.)
  return items.filter((el) => el.compareDocumentPosition(row) & 4).length
}

function liveRegion() {
  if (!live?.isConnected) {
    live = document.createElement("div")
    live.setAttribute("aria-live", "polite")
    live.setAttribute("data-reactive-sortable-live", "")
    live.style.cssText = "position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap"
    document.body.append(live)
  }
  return live
}

// Clear the region now and write the words on the next frame, so a change is
// heard even when the words are the same as the last ones.
function announce(name) {
  const list = drag.target ?? drag.origin
  const words = (json(attr(list, "-messages"), {})[name] ?? "")
    .replaceAll("{position}", position() + 1)
    .replaceAll("{count}", itemsOf(list).length + 1)
  const region = liveRegion()
  region.textContent = ""
  cancelAnimationFrame(speaking)
  speaking = requestAnimationFrame(() => (region.textContent = words))
}

// --- Drop / cancel -----------------------------------------------------------
// Settle the row, then send the target's action: a move that changed nothing
// sends nothing. Returns before the reply; the row goes back if it fails.
function drop() {
  const record = drag
  const { target, origin, source, row, placeholder } = record
  const landed = target && (source ? placeholder.isConnected : true)
  const index = landed ? position() : -1
  const after = landed ? keyOf(itemsOf(target)[index - 1]) : null
  if (record.keyboard) announce("dropped")
  if (!source && placeholder) placeholder.replaceWith(row)
  settle(record)
  if (!landed || (target === origin && index === record.index)) return

  const from = target === origin ? "self" : source ? attr(origin, "-source") : (attr(origin, "-name") ?? "list")
  const action = json(attr(target, "-from"), {})[from] ?? attr(target)
  const params = { ...json(attr(target, "-params"), {}), item: keyOf(record.item), position: index, after, from }
  // The list and its ancestors: a reply stream that replaces or updates one
  // of them (by id, or by a `targets:` selector) rendered the list (read now —
  // a replace detaches it).
  const chain = []
  for (let el = target; el; el = el.parentElement) chain.push(el)
  const sent = cores.get(rootOf(target))?.proceed(target, action, JSON.stringify(params), json(attr(target, "-busy")))
  if (source) return
  Promise.resolve(sent).then((html) => renders(html, chain) || restore(record))
}

function renders(html, chain) {
  if (!html) return false
  const template = document.createElement("template")
  template.innerHTML = html
  return [...template.content.querySelectorAll("turbo-stream")].some(
    (stream) => /^(replace|update)$/.test(stream.getAttribute("action")) && hits(stream, chain),
  )
}

function hits(stream, chain) {
  const target = stream.getAttribute("target")
  if (target) return chain.some((el) => el.id === target)
  const selector = stream.getAttribute("targets")
  try {
    return Boolean(selector) && chain.some((el) => el.matches(selector))
  } catch {
    return false // an invalid selector renders nothing
  }
}

function cancel() {
  const record = drag
  if (record.keyboard) announce("cancelled")
  record.placeholder?.remove()
  settle(record)
  restore(record)
}

// Put a moved row back at its original index in its original list.
function restore({ row, origin, index, source }) {
  if (source || !row.isConnected) return
  insertAt(
    origin,
    itemsOf(origin).filter((el) => el !== row),
    index,
    row,
  )
  if (row === document.activeElement) row.focus?.()
}

// Undo everything the drag set: the row's style and marker, the lists'
// markers, the clone, the placeholder, the frame loop, the text selection.
function settle(record) {
  const { row, origin, target, source, style, placeholder } = record
  drag = null
  if (record.raf) cancelAnimationFrame(record.raf)
  row.removeAttribute("data-reactive-sortable-dragging")
  if (source) row.remove()
  else if (!record.keyboard) style == null ? row.removeAttribute("style") : row.setAttribute("style", style)
  placeholder?.remove()
  activate(origin, false)
  activate(target, false)
  if (!record.keyboard) document.documentElement.style.userSelect = record.select ?? ""
}
