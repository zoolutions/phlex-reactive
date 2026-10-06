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
// stay tiny (its gzipped size is asserted by spec/javascript/reactive_early.test.js).
//
// Dormant roots (issue #274): reactive_root(dormant: true) renders
// data-reactive-dormant="reactive" INSTEAD of data-controller="reactive", so
// nothing mounts (or, with a lazily loaded controller, is even fetched) until
// one of the root's triggers fires. The first recorded trigger WAKES the root:
// the identifier moves into data-controller, Stimulus connects it, and the
// trigger is replayed like any other early event. A dormant root therefore
// NEEDS this module — without it nothing ever wakes it.
//
// Window-bound triggers (window:, issue #303 — how a hotkey is bound) are
// recorded too, by a capture listener on window: the keypress lands anywhere
// on the page, so the scan keeps a registry of the elements carrying an
// `@window` descriptor instead of walking up from the target. They are never
// prevented (dispatch() does not prevent a window binding either) and live a
// short TTL in the controller (a hotkey replayed seconds late is wrong).
//
// Limits: outside: triggers and @document bindings are not recorded (an
// outside click before connect has nothing to close); a key filter is matched
// against Stimulus's DEFAULT key mappings only.

const KEY = Symbol.for("phlex-reactive.early")

// The roots whose triggers are captured. A root counts as connected only
// through state.connected (a WeakSet the controller fills in connect()), never
// through markup — a Turbo snapshot clone carries data-reactive-connected over.
// A dormant root (issue #274) is one too: it has no controller yet by design.
const ROOT_SELECTOR = '[data-controller~="reactive"],[data-reactive-dormant~="reactive"]'

const state = (globalThis[KEY] ??= { queue: [], connected: new WeakSet() })

// One Stimulus descriptor token → [{ token, type, filter, win, method }] for a
// reactive trigger, else [] (flatMap-ready). `win` marks an `@window` token;
// `@document` never matches. Like Stimulus, a dot suffix is a key filter only
// on a key event (`keydown.enter`); otherwise it is part of the event name
// (`panel.opened`).
function parseDescriptor(token) {
  const match = /^(?:(key\w+)\.([\w+]+)|([^@>]+))(@window)?->reactive#(dispatch|runOps)(?::!?\w+)*$/.exec(token)
  return match ? [{ token, type: match[1] ?? match[3], filter: match[2], win: !!match[4], method: match[5] }] : []
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

const matching = (el, event, win) =>
  descriptors(el).filter((d) => d.win === win && d.type === event.type && keyMatches(d.filter, event))

// Queue one firing for `el`'s root, unless that root has connected.
function enqueue(event, el, descs, win) {
  const root = el.closest(ROOT_SELECTOR)
  if (!root || state.connected.has(root)) return
  // dispatch() keeps the native flip of a checked: :keep checkbox/radio and
  // never prevents a window binding; everything else is prevented now, as the
  // controller would.
  const keepsToggle =
    /^(checkbox|radio)$/.test(el.type) && /"checked":"keep"/.test(el.dataset.reactiveOptimisticParam)
  if (!win && (!keepsToggle || descs.some((d) => d.method === "runOps"))) event.preventDefault()
  // Every firing is queued — a `:once` repeat included: the replay skips a
  // descriptor already consumed (reactive_controller.js #replayEarly).
  const { queue } = state
  // Bounded: a root whose controller never registers must not grow it forever.
  // `at` is the capture time — not event.timeStamp, which is when the event
  // object was CREATED (an app may build one and dispatch it much later).
  if (queue.push({ event, el, root, descs, win, at: performance.now() }) > 50) queue.shift()
  // Wake a dormant root (issue #274) — synchronously, so by the time the
  // event bubbles to an OUTER reactive root's Stimulus listener, `el` is
  // already in this root's scope. Other controllers on the root are kept.
  const { reactiveDormant, controller = "" } = root.dataset
  if (reactiveDormant) {
    root.dataset.controller = `${controller} ${reactiveDormant}`.trim()
    delete root.dataset.reactiveDormant
  }
}

function record(event) {
  for (let el = event.target; el?.closest; el = el.parentElement) {
    if (!event.bubbles && el !== event.target) break
    const descs = matching(el, event, false)
    if (descs.length) enqueue(event, el, descs, false)
  }
}

// The elements carrying an `@window` reactive descriptor (issue #303), fed by
// the scan; one that left the page is dropped when next seen.
const windowBound = new Set()

function recordWindow(event) {
  // Stimulus's window listener is a bubble-phase one: a non-bubbling event
  // (focus, mouseenter) from inside the page never reaches it.
  if (!event.bubbles && event.target !== event.currentTarget) return
  for (const el of windowBound) {
    if (!el.isConnected) {
      windowBound.delete(el)
      continue
    }
    // Cheapest check first: once its root connects, Stimulus hears it.
    if (state.connected.has(el.closest(ROOT_SELECTOR))) continue
    // outside: is not recorded — on() flags it on the element, on_client in
    // the binding record (one window record without it is enough to queue;
    // the replay skips the outside ones).
    const descs = matching(el, event, true).filter((d) =>
      d.method === "runOps"
        ? /"window":true(?!,"outside")/.test(el.dataset.reactiveOpsParam)
        : el.dataset.reactiveOutsideParam !== "true",
    )
    if (descs.length) enqueue(event, el, descs, true)
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
      for (const { type, win } of descriptors(el)) {
        if (win) windowBound.add(el)
        ;(win ? doc.defaultView : doc).addEventListener(type, win ? recordWindow : record, true)
      }
    }
  }
  scan(doc.documentElement)
  new MutationObserver((mutations) => {
    for (const m of mutations) m.type === "attributes" ? scan(m.target) : m.addedNodes.forEach(scan)
  }).observe(doc.documentElement, { childList: true, subtree: true, attributeFilter: ["data-action"] })
}

if (globalThis.document) startEarly()
