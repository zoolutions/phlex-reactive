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

// One Stimulus descriptor token → [{ token, type, filter, method }] for a
// reactive trigger, else [] (flatMap-ready). `@window`/`@document` tokens
// never match (no `@` before `->`). Like Stimulus, a dot suffix is a key
// filter only on a key event (`keydown.enter`); otherwise it is part of the
// event name (`panel.opened`).
function parseDescriptor(token) {
  const match = /^(?:(key\w+)\.([\w+]+)|([^@>]+))->reactive#(dispatch|runOps)(?::!?\w+)*$/.exec(token)
  return match ? [{ token, type: match[1] ?? match[3], filter: match[2], method: match[4] }] : []
}

// Stimulus's key-filter rule against its DEFAULT mappings (esc, space, the
// arrows, page_up/down; letters, digits, enter, tab, home, end map to
// themselves): the key after the last "+" matches event.key, and the four
// modifiers match exactly (ctrl+enter is not enter). It decides what to queue
// and preventDefault before connect; the replay re-checks the filter against
// the app's own key mappings (reactive_controller.js #replayEarly).
function keyMatches(filter, event) {
  if (!filter) return true
  const parts = filter.split("+")
  const key = parts.pop()
  const name = key === "esc" ? "escape" : key === "space" ? " " : key.replace(/^(?=up|down|left|right)/, "arrow").replace("_", "")
  return name === event.key?.toLowerCase() && ["meta", "ctrl", "alt", "shift"].every((mod) => parts.includes(mod) === event[`${mod}Key`])
}

const descriptors = (el) => (el.dataset.action ?? "").split(/\s+/).flatMap(parseDescriptor)

function record(event) {
  for (let el = event.target; el?.closest; el = el.parentElement) {
    if (!event.bubbles && el !== event.target) break
    const descs = descriptors(el).filter((d) => d.type === event.type && keyMatches(d.filter, event))
    if (!descs.length) continue
    const root = el.closest(ROOT_SELECTOR)
    if (!root || state.connected.has(root)) continue
    // dispatch() keeps the native flip of a checked: :keep checkbox/radio;
    // everything else element-bound is prevented now, as the controller would.
    const keepsToggle =
      /^(checkbox|radio)$/.test(el.type) && /"checked":"keep"/.test(el.dataset.reactiveOptimisticParam)
    if (!keepsToggle || descs.some((d) => d.method === "runOps")) event.preventDefault()
    // Every firing is queued — a `:once` repeat included: the replay skips a
    // descriptor already consumed (reactive_controller.js #replayEarly).
    const { queue } = state
    // Bounded: a root whose controller never registers must not grow it forever.
    // (The entry's age is read off event.timeStamp on connect.)
    if (queue.push({ event, el, root, descs }) > 50) queue.shift()
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

if (globalThis.document) startEarly()
