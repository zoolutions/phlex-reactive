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
} from "phlex/reactive/runtime"

registerReactiveFeatureLoader("persist", () => import("phlex/reactive/features/persist"), waitingForPersist)
registerReactiveFeatureLoader("defer", () => import("phlex/reactive/features/defer"))
registerReactiveFeatureLoader("form", () => import("phlex/reactive/features/form"))
registerReactiveFeatureLoader("effects", () => import("phlex/reactive/features/effects"))
registerReactiveFeatureLoader("dev", () => import("phlex/reactive/features/dev"))
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

// --- A stream that needs the effects module before it is loaded ----------------
// Stream effects and dismissing flashes are document-level (features/effects.js):
// a broadcast can append the page's first flash, a reply can remove a row with
// an exit effect, on a page where no root ever asked for the module. That
// stream must still get its effect, and an exit effect runs BEFORE the render,
// so the render WAITS for the import (`hold`). Turbo renders each
// <turbo-stream> on its own, so one waiting render would let a later stream to
// the same target overtake it: while the hold is open EVERY stream's render
// waits on the same promise, and so they resume in arrival order.
//
// The hold is an animation's worth of patience, never the import timeout:
// after STREAM_HOLD_MS the streams render plain, and the module, when it does
// arrive, sweeps up the flashes it missed (their timers then start at arrival,
// not at render). Once the module is loaded the runtime hands it every stream
// directly and none of this runs again.
const STREAM_HOLD_MS = 1000
let hold = null
let effects

onReactiveStreamWithoutEffects((event) => {
  const detail = event.detail
  const render = detail?.render
  if (typeof render !== "function") return
  if (!hold) {
    if (!streamNeedsEffects(detail.newStream ?? event.target)) return
    hold = Promise.race([
      loadReactiveFeature("effects").then((feature) => {
        effects = feature
        feature?.sweep()
      }),
      new Promise((resolve) => setTimeout(resolve, STREAM_HOLD_MS)),
    ])
  }
  const waiting = hold
  detail.render = async (streamElement) => {
    await waiting
    // Wrapped now, not when the event fired: nothing has rendered meanwhile.
    detail.render = render
    effects?.wrap(event)
    await detail.render(streamElement)
  }
})

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
}

export * from "phlex/reactive/runtime"
export default ReactiveController
