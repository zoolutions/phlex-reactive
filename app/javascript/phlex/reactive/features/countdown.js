// phlex/reactive/features/countdown — a deadline counted down on the client
// (issue #400). One of the feature modules the core imports on demand (issue
// #275); in the default client it is part of the one file.
//
// The markup is the Ruby side's (reactive_countdown):
//
//   data-reactive-countdown='{"until":"<ISO8601>","format":"ms","waiting":"#wait","done":"#done"}'
//
// Every tick reads Date.now against the deadline, so a late tick (a throttled
// background tab, a slept laptop) paints the real remaining time, never a
// count of missed ticks; a tab that becomes visible again re-reads at once.
// The text is unpadded minutes, a colon and zero-padded seconds ("1:30"),
// written as textContent only. The next tick is set for the moment the shown
// second changes.
//
// At zero (or with the deadline already past on connect, which starts no
// timer) the text is "0:00", data-reactive-countdown-state is "done", the
// waiting: node hides, the done: node shows, and the element dispatches
// reactive:countdown-done (bubbling) once. "Once" is per root id (a root
// without one is its own element), countdown (its id, else its place in the
// root) and deadline, kept for the life of the document: a morph or a replace
// that keeps the deadline, or brings back one that already fired, paints the
// done state again without a second event; a new deadline counts down afresh.
// The countdown's content is its text: waiting: and done: are nodes beside it,
// so a root that is itself the countdown has none.
// No request, no frame reload: the page decides what the event does.
//
// This module never imports the core: it reaches a controller through the
// `core` handle (core.owns).

const MARK = "data-reactive-countdown"
const STATE = "data-reactive-countdown-state"

// "<root id>|<countdown key>" -> every deadline it already dispatched for.
const finished = new Map()
// A root without an id: a number of its own, so two never share a key.
const anonymous = new WeakMap()
let anonymousSeq = 0
// controller -> the removal of what connect() added.
const wired = new WeakMap()

export function connect(controller, core) {
  const root = controller.element
  if (!root.id && !anonymous.has(root)) anonymous.set(root, `#${++anonymousSeq}`)
  const rootKey = root.id || anonymous.get(root)
  // countdown element -> its pending timer.
  const timers = new Map()
  let queued = false

  const clear = (el) => {
    clearTimeout(timers.get(el))
    timers.delete(el)
  }

  const tick = (el, wire, key) => {
    clear(el)
    const left = Date.parse(wire.until) - Date.now()
    if (!(left > 0)) return finish(el, wire, key)
    const seconds = Math.ceil(left / 1000)
    paint(el, `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`, "running")
    show(wire.waiting, true)
    show(wire.done, false)
    timers.set(
      el,
      setTimeout(() => tick(el, wire, key), ((left - 1) % 1000) + 1),
    )
  }

  const finish = (el, wire, key) => {
    paint(el, "0:00", "done")
    show(wire.waiting, false)
    show(wire.done, true)
    const fired = finished.get(key) ?? new Set()
    if (fired.has(wire.until)) return
    finished.set(key, fired.add(wire.until))
    el.dispatchEvent(new CustomEvent("reactive:countdown-done", { bubbles: true, detail: { until: wire.until } }))
  }

  // A selector that is not valid CSS is ignored, never a stopped clock.
  const show = (selector, visible) => {
    let node
    try {
      node = selector && root.querySelector(selector)
    } catch {}
    if (node && node.hidden === visible) node.hidden = !visible
  }

  // Every countdown this root owns, from scratch: a morph may have changed a
  // deadline, written the server's text back, or removed a countdown.
  const sync = () => {
    queued = false
    // A morph that also removed the root: disconnect ran first.
    if (!wired.has(controller)) return
    const seen = new Set()
    const els = [...(root.matches(`[${MARK}]`) ? [root] : []), ...root.querySelectorAll(`[${MARK}]`)]
    els.forEach((el, index) => {
      if (!core.owns(el)) return
      let wire
      try {
        wire = JSON.parse(el.getAttribute(MARK))
      } catch {
        return
      }
      if (Number.isNaN(Date.parse(wire?.until))) return
      seen.add(el)
      tick(el, wire, `${rootKey}|${el.id || index}`)
    })
    for (const el of timers.keys()) if (!seen.has(el)) clear(el)
  }

  // A morph of the root or of anything in it (turbo:morph-element bubbles,
  // once per morphed element), a stream rendered into it, a tab woken up:
  // one sync for all of them, after the morph is done.
  const later = () => {
    if (queued) return
    queued = true
    queueMicrotask(sync)
  }
  const woke = () => document.visibilityState === "visible" && sync()
  root.addEventListener("turbo:morph-element", later)
  root.addEventListener("reactive:streamed", later)
  document.addEventListener("visibilitychange", woke)
  wired.set(controller, () => {
    root.removeEventListener("turbo:morph-element", later)
    root.removeEventListener("reactive:streamed", later)
    document.removeEventListener("visibilitychange", woke)
    for (const el of [...timers.keys()]) clear(el)
  })
  sync()
}

export function disconnect(controller) {
  wired.get(controller)?.()
  wired.delete(controller)
}

function paint(el, text, state) {
  if (el.textContent !== text) el.textContent = text
  if (el.getAttribute(STATE) !== state) el.setAttribute(STATE, state)
}
