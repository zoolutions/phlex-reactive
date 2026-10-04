// phlex/reactive/early — never lose a trigger that fires before the `reactive`
// controller connects (issue #273).
//
// An on()/on_client trigger is a Stimulus action: its listener only exists
// once the controller module has loaded and connected. With a lazily loaded
// controller (stimulus-loading's lazyLoadControllersFrom, a preload: false
// pin, a slow network) a click or custom event in that window used to vanish:
// no request, no error, a UI waiting forever. Import this tiny module EAGERLY
// (`import "phlex/reactive/early"` in the entry point; the engine pins it with
// preload: true) and the controller can load whenever it likes.
//
// How: one CAPTURE listener per trigger event type on document (the types come
// from the `->reactive#dispatch` / `->reactive#runOps` descriptors in the page,
// rescanned by a MutationObserver as markup arrives). When an event reaches a
// descriptor whose root has NOT connected, it is queued and — synchronously,
// while preventDefault still works — its native default is stopped exactly
// where dispatch()/runOps() would stop it. connect() drains the queue
// (reactive_controller.js #drainEarly) and replays each entry.
//
// The queue lives on window under a Symbol.for key, so neither module imports
// the other and either may load first. NO Stimulus import: this module must
// stay tiny (< 1 KB gzipped, asserted by spec/javascript/reactive_early.test.js).
//
// Limits: @window/@document bindings (window:/outside:) are not recorded; a
// key filter is matched against Stimulus's DEFAULT key mappings only.

const KEY = Symbol.for("phlex-reactive.early")

// The roots whose triggers are captured. A root counts as connected only
// through state.connected (a WeakSet the controller fills in connect()), never
// through markup — a Turbo snapshot clone carries data-reactive-connected over.
const ROOT_SELECTOR = '[data-controller~="reactive"]'

const state = (globalThis[KEY] ??= { queue: [], connected: new WeakSet() })

// One Stimulus descriptor token → { token, type, filter, method, once }
// for a reactive trigger, else undefined. `@window`/`@document` tokens never
// match (the `@` is excluded before `->`). Stimulus keeps a dot suffix as part
// of the event name unless the event is a key event (`keydown.enter`).
function parseDescriptor(token) {
  const match = /^([^@>]+?)(?:\.([\w+]+))?->reactive#(dispatch|runOps)((?::!?\w+)*)$/.exec(token)
  if (!match) return
  let [, type, filter, method, options] = match
  if (filter && !type.startsWith("key")) [type, filter] = [`${type}.${filter}`]
  return { token, type, filter, method, once: options.includes(":once") }
}

// A COARSE key-filter check (bytes matter here): the key after the last "+"
// against Stimulus's default mappings (esc, space, the arrows, page_up/down;
// letters, digits, enter, tab, home, end map to themselves), modifiers
// ignored. It only decides what to queue and preventDefault before connect;
// the replay re-checks the full filter, modifiers and the app's own key
// mappings included (reactive_controller.js #replayEarly).
function keyMatches(filter, event) {
  const key = filter?.split("+").pop()
  const name =
    key === "esc" ? "escape" : key === "space" ? " " : /^(up|down|left|right)$/.test(key) ? `arrow${key}` : key?.replace("_", "")
  return !key || name === event.key?.toLowerCase()
}

const descriptors = (el) => (el.getAttribute("data-action") ?? "").split(/\s+/).map(parseDescriptor).filter(Boolean)

function record(event) {
  if (event[KEY]) return // a replay from #drainEarly
  for (let el = event.target; el?.closest; el = el.parentElement) {
    if (!event.bubbles && el !== event.target) break
    const descs = descriptors(el).filter((d) => d.type === event.type && keyMatches(d.filter, event))
    if (!descs.length) continue
    const root = el.closest(ROOT_SELECTOR)
    if (!root || state.connected.has(root)) continue
    // dispatch() keeps the native flip of a checked: :keep checkbox/radio;
    // everything else element-bound is prevented now, as the controller would.
    // (checked: :keep only renders on a checkbox/radio trigger.)
    const keepsToggle = /"checked":"keep"/.test(el.getAttribute("data-reactive-optimistic-param"))
    if (!keepsToggle || descs.some((d) => d.method === "runOps")) event.preventDefault()
    // Every firing is queued — a `:once` repeat included: the replay skips a
    // descriptor already consumed (reactive_controller.js #replayEarly).
    const { queue } = state
    // Bounded: a root whose controller never registers must not grow it forever.
    if (queue.push({ event, el, root, descs, at: performance.now() }) > 50) queue.shift()
  }
}

// Install the capture listeners for every reactive trigger type in `doc`, now
// and as markup arrives. Runs on import; exported for tests and for apps that
// render into another document.
// addEventListener ignores a repeat of the same (type, listener, capture), so
// every scan may simply re-add.
export function startEarly(doc = document) {
  const scan = (node) => {
    if (node.nodeType !== 1) return
    for (const el of [node, ...node.querySelectorAll('[data-action*="reactive#"]')]) {
      for (const { type } of descriptors(el)) doc.addEventListener(type, record, true)
    }
  }
  scan(doc.documentElement)
  new MutationObserver((mutations) => {
    for (const m of mutations) m.type === "attributes" ? scan(m.target) : m.addedNodes.forEach(scan)
  }).observe(doc.documentElement, { childList: true, subtree: true, attributeFilter: ["data-action"] })
}

if (globalThis.document?.documentElement) startEarly()
