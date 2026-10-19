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
// A shortcut: (issue #357) is the exception: the chord is prevented, as
// dispatch() prevents it, and the other platform's `mod` twin or a press in an
// editable field is neither queued nor prevented.
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
function enqueue(event, el, descs, win, shortcut) {
  const root = el.closest(ROOT_SELECTOR)
  if (!root || state.connected.has(root)) return
  // dispatch() keeps the native flip of a checked: :keep checkbox/radio and
  // never prevents a window binding — but a shortcut (issue #357), the chord
  // the page claims (mod+s must not open the save dialog before connect), is
  // always prevented: the keepsToggle exemption is for element-bound clicks
  // only. Everything else is prevented now, as the controller would. A
  // shortcut's chord is remembered as prevented FOR a shortcut (issue #429):
  // a connected root's shortcut on the same chord still runs, as a shortcut
  // only skips a key some other handler prevented.
  //
  // `prevent: false` (issue #433) keeps the default when EVERY descriptor that
  // fired opts out: on() through its element-wide param, an on_client
  // descriptor when every record on its `on` carries `"prevent":false`,
  // written right after `on` (a legacy attr has no `on`, so it is prevented).
  // A record starts the attribute or follows the space mix joins records with
  // (a record writes its own spaces as \u0020), so ` {"on":"…"` is a record's
  // start and never an op's argument.
  const keepsToggle =
    /^(checkbox|radio)$/.test(el.type) && /"checked":"keep"/.test(el.dataset.reactiveOptimisticParam)
  const ops = ` ${el.dataset.reactiveOpsParam ?? ""}`
  const keeps = (d) => {
    const on = ` {"on":${JSON.stringify(d.token.split("->")[0])}`
    return d.method === "runOps"
      ? ops.includes(on) && ops.split(on).length === ops.split(`${on},"prevent":false`).length
      : keepsToggle || el.dataset.reactivePreventParam === "false"
  }
  if (win ? shortcut : !descs.every(keeps)) {
    if (win && !event.defaultPrevented) (state.prevented ??= new WeakSet()).add(event)
    event.preventDefault()
  }
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

// Issue #442: an on_client descriptor whose every record on its `on` is a
// within: delegation the event's target falls outside of (no matching element
// strictly under `el`: its parent is not inside `el`) is a miss — runOps
// would run nothing and prevent nothing — so it is neither queued nor
// prevented: a link in a delegated list's footer still navigates before
// connect. A record without within:, or an attr that does not parse (a legacy
// list), keeps the descriptor; a within: that does not parse is a miss, as
// it is for runOps. (A row of a nested root is still queued; the replay's
// ownership check makes it a miss.)
const outside = (el, target, within) => {
  try {
    return !el.contains(target.closest(within)?.parentElement ?? null)
  } catch {
    return true
  }
}

function delegatedMiss(el, d, target) {
  let mine
  try {
    mine = el.dataset.reactiveOpsParam.split(" ").map(JSON.parse).filter((r) => r.on === d.token.split("->")[0])
  } catch {
    return false
  }
  return mine.length > 0 && mine.every((r) => r.within != null && outside(el, target, r.within))
}

function record(event) {
  for (let el = event.target; el?.closest; el = el.parentElement) {
    if (!event.bubbles && el !== event.target) break
    const descs = matching(el, event, false).filter((d) => d.method !== "runOps" || !delegatedMiss(el, d, event.target))
    if (descs.length) enqueue(event, el, descs, false)
  }
}

// The elements carrying an `@window` reactive descriptor (issue #303), fed by
// the scan. One that left the page is dropped once per mutation batch (a
// Turbo Drive visit swaps the body, so the old page's triggers do not keep it
// alive) or when next seen by the listener.
const windowBound = new Set()
export const __windowBoundForTest = windowBound

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
    // A shortcut (issue #357): on() flags it on the element, on_client in its
    // record (read off the raw attribute: the element's records share one
    // guard here, and the replay re-checks each). The guard covers only a
    // key-filtered descriptor — a shortcut's twins always carry a filter — so
    // the element's other window bindings (a click, a bare keydown) behave
    // as they do without a shortcut. The exception is a delete/backspace
    // chord's bare keydown (below), which on that element IS the shortcut.
    const ops = el.dataset.reactiveOpsParam ?? ""
    const shortcut = el.dataset.reactiveShortcutParam ?? (/"shortcut":/.test(ops) && ops)
    const { target } = event
    const typing =
      shortcut && !/inEditable":true/.test(shortcut) && (target.isContentEditable || /^(input|textarea|select)$/.test(target.localName))
    // Apple platforms run the meta twin of a `mod` chord, the rest the ctrl
    // one: `skip` is the other platform's.
    const mod = shortcut && (/[Mm]ac|iP/.test(navigator.userAgentData?.platform ?? navigator.platform) ? "meta" : "ctrl")
    const skip = /mod\+/.test(shortcut) && (mod === "meta" ? "ctrl" : "meta")
    // A delete/backspace chord (issue #366) binds a BARE keydown (Stimulus
    // lacks the keys): the chord itself, this platform's `mod`, decides.
    const chords = (shortcut && shortcut.match(/(^|"(keys|shortcut)":")[\w+]*(delete|backspace)(?="|$)/g)) || []
    const bare = (d) => !d.filter && chords[0] && d.type === "keydown"
    // outside: is not recorded — on() flags it on the element, on_client in
    // the binding record (one window record without it is enough to queue;
    // the replay skips the outside ones).
    const descs = matching(el, event, true).filter(
      (d) =>
        (bare(d)
          ? !typing && chords.some((chord) => keyMatches(chord.slice(chord.lastIndexOf('"') + 1).replace("mod", mod), event))
          : !(d.filter && (typing || (skip && d.filter.includes(skip))))) &&
        (d.method === "runOps" ? /"window":true(?!,"outside")/.test(ops) : el.dataset.reactiveOutsideParam !== "true"),
    )
    if (descs.length) enqueue(event, el, descs, true, shortcut && descs.some((d) => d.filter || bare(d)))
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
  // Once per batch of markup, not per added node: drop the window-bound
  // triggers that left the page (a Turbo Drive visit swaps the whole body).
  const prune = () => {
    for (const el of windowBound) if (!el.isConnected) windowBound.delete(el)
  }
  prune()
  scan(doc.documentElement)
  new MutationObserver((mutations) => {
    prune()
    for (const m of mutations) m.type === "attributes" ? scan(m.target) : m.addedNodes.forEach(scan)
  }).observe(doc.documentElement, { childList: true, subtree: true, attributeFilter: ["data-action"] })
}

if (globalThis.document) startEarly()
