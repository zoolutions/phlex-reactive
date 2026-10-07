// phlex/reactive/core — the OPT-IN client: the reactive controller without
// its feature modules, which it imports when a root on the page needs one
// (issue #275). The default is phlex/reactive/reactive_controller: one file
// with every feature inside, nothing imported later. An app imports ONE of
// the two, never both.
//
// The controller itself is the shared runtime (runtime.js); the shipped
// core.min.js is this file BUNDLED with it. All this entry adds is where each
// feature module lives: one LITERAL import() per feature, by the bare
// specifier the engine pins (phlex/reactive/features/<name>) — literal so a
// bundler can see it and split the feature into its own chunk, bare so the
// import map resolves it to that module's own digested file (issue #57).
//
// What the opt-in costs a page is documented in the README ("The split
// client"): the first root that needs a feature waits for its import.
import ReactiveController, {
  loadReactiveFeature,
  onReactiveStreamWithoutEffects,
  registerReactiveDev,
  registerReactiveFeatureLoader,
  unloadedFeaturesFor,
} from "phlex/reactive/runtime"

registerReactiveFeatureLoader("persist", () => import("phlex/reactive/features/persist"), waitingForPersist)
registerReactiveFeatureLoader("defer", () => import("phlex/reactive/features/defer"))
registerReactiveFeatureLoader("form", () => import("phlex/reactive/features/form"))
registerReactiveFeatureLoader("bindings", () => import("phlex/reactive/features/bindings"))
registerReactiveFeatureLoader("compute", () => import("phlex/reactive/features/compute"), waitingForEdit)
registerReactiveFeatureLoader("effects", () => import("phlex/reactive/features/effects"))
registerReactiveFeatureLoader("hints", () => import("phlex/reactive/features/hints"))
registerReactiveFeatureLoader("devtools", () => import("phlex/reactive/features/devtools"))
// The runtime registered with Turbo before this file ran: now it knows where
// the dev module is, a development page can have it.
registerReactiveDev()

// --- While the persist module is on its way ---------------------------------------
// What the draft code must not miss while it is on its way: that the
// user edited a field (the edit must be drafted once the module is here)
// and that the form around the root was submitted successfully (the
// draft must be forgotten, not restored). The feature listens for both
// itself once it has connected.
function waitingForPersist(root, pending) {
  const edited = () => {
    pending.edited = true
  }
  const submitted = (event) => {
    const form = event.target
    if (event.detail?.success && form?.tagName === "FORM" && form.contains?.(root)) pending.submitted = true
  }
  // (Lexical and Trix swallow the native `input` of their editor; their
  // own bubbling change events are the keystroke signal.)
  const edits = ["input", "change", "lexxy:change", "trix-change"]
  for (const type of edits) root.addEventListener?.(type, edited)
  document.addEventListener("turbo:submit-end", submitted)
  return () => {
    for (const type of edits) root.removeEventListener?.(type, edited)
    document.removeEventListener("turbo:submit-end", submitted)
  }
}

// --- While the compute module is on its way --------------------------------------
// An edit the user made before the module could recompute: it runs one pass
// when it connects, over the fields as the user left them.
function waitingForEdit(root, pending) {
  const edited = () => {
    pending.edited = true
  }
  root.addEventListener?.("input", edited)
  root.addEventListener?.("change", edited)
  return () => {
    root.removeEventListener?.("input", edited)
    root.removeEventListener?.("change", edited)
  }
}

// --- A stream that needs a module before it is loaded ------------------------------
// A stream can bring the page's first use of a feature: a broadcast appends
// the first dismissing flash, a reply removes a row with an exit effect or
// swaps in a form with show bindings and tag chips. Stream effects are
// document-level (features/effects.js) and an exit effect runs BEFORE the
// render; a swapped-in root connects AFTER it and would start its import
// then, showing the server's rendering until the module arrives. Both are
// avoided the same way: the render WAITS for the imports (`hold`), so the
// stream is animated and the new root connects with its modules present.
// Which modules a stream needs is read off the runtime's feature table
// (unloadedFeaturesFor: every incoming reactive root's marker checks), plus
// the effects module's own stream-level checks — no per-feature copy here.
//
// Turbo renders each <turbo-stream> on its own, so one waiting render would
// let a later stream to the same target overtake it: while the hold is open
// EVERY stream's render waits on the same promise, and so they resume in
// arrival order. The hold is an animation's worth of patience, never the
// import timeout: after STREAM_HOLD_MS the streams render plain, a root
// connects and imports as usual, and the effects module, when it does arrive,
// sweeps up the flashes it missed (their timers then start at arrival, not at
// render). A module already loaded is never waited for.
const STREAM_HOLD_MS = 1000
let hold = null
let effects
const holding = new Set() // the modules the open hold is waiting for

function loadIntoHold(name) {
  return loadReactiveFeature(name).then((feature) => {
    if (name !== "effects") return
    effects = feature
    feature?.sweep()
  })
}

onReactiveStreamWithoutEffects((event, loadedEffects) => {
  const detail = event.detail
  const render = detail?.render
  if (typeof render !== "function") return
  const streamEl = detail.newStream ?? event.target
  const names = unloadedFeaturesFor(incomingRoots(streamEl)).filter((name) => !holding.has(name))
  if (!loadedEffects && !holding.has("effects") && streamNeedsEffects(streamEl)) names.push("effects")
  // Nothing to wait for, and no hold open: a loaded effects module wraps the
  // stream now, as it would without this entry.
  if (names.length === 0 && !hold) return loadedEffects?.wrap(event)
  // A hold that is open grows: a later stream's modules join it (the hold
  // then lasts up to another STREAM_HOLD_MS from now), so a second stream is
  // never left to render without the module it asked for.
  if (names.length > 0) {
    for (const name of names) holding.add(name)
    const opened = (hold = Promise.race([
      Promise.all([hold, ...names.map(loadIntoHold)]),
      new Promise((resolve) => setTimeout(resolve, STREAM_HOLD_MS)),
    ]).then(() => {
      if (hold !== opened) return
      hold = null
      holding.clear()
    }))
  }
  const waiting = hold
  detail.render = async (streamElement) => {
    await waiting
    // Wrapped now, not when the event fired: nothing has rendered meanwhile.
    // On a copy: the event's detail.render is not ours to set back — a defer
    // reply has already rendered it, and leaves Turbo a no-op (issue #336).
    const held = { target: event.target, detail: { newStream: detail.newStream, render } }
    ;(loadedEffects ?? effects)?.wrap(held)
    await held.detail.render(streamElement)
  }
})

// The reactive roots a stream is about to put on the page: the roots in its
// template (the template's own root element included).
function incomingRoots(streamEl) {
  const content = streamEl?.querySelector?.("template")?.content
  if (!content) return []
  const roots = [...(content.querySelectorAll?.('[data-controller~="reactive"]') ?? [])]
  for (const child of content.children ?? []) {
    if (child.matches?.('[data-controller~="reactive"]') && !roots.includes(child)) roots.unshift(child)
  }
  return roots
}

// Does this stream need the effects module? A cheap superset of what the
// module itself resolves: a per-call effect, an effect declared on the target
// or on incoming content, a dismissing flash arriving or already on the page.
function streamNeedsEffects(streamEl) {
  return Boolean(
    streamEl?.hasAttribute?.("data-reactive-effect") ||
      document
        .getElementById?.(streamEl?.getAttribute?.("target"))
        ?.matches?.("[data-reactive-effect-update],[data-reactive-effect-exit]") ||
      streamEl
        ?.querySelector?.("template")
        ?.content?.querySelector?.("[data-reactive-effect-enter],[data-reactive-dismiss-after]") ||
      document.querySelector?.("[data-reactive-dismiss-after]:not([data-reactive-dismiss-scheduled])"),
  )
}

export function __resetReactiveStreamHoldForTest() {
  hold = null
  effects = undefined
  holding.clear()
}

export * from "phlex/reactive/runtime"
export default ReactiveController
