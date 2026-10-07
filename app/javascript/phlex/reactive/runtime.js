import { Controller } from "@hotwired/stimulus"
// Import the BARE specifier the engine already pins (phlex/reactive/confirm),
// NOT a relative "./confirm.js" (issue #57). Under importmap-rails + Propshaft
// the controller is served at its DIGESTED url; a relative sibling import is
// left untouched (Propshaft rewrites only RAILS_ASSET_URL(...), and the import
// map resolves ONLY bare specifiers), so "./confirm.js" resolves against the
// digested controller url → an undigested /assets/.../confirm.js that 404s, and
// the throwing import takes down every Stimulus controller on the page. The
// bare specifier resolves to the digested asset through the import map, and
// bundlers/bun resolve it the same way they already resolve
// "phlex/reactive/reactive_controller" (see tsconfig.json paths for the tests).
import { confirmResolver } from "phlex/reactive/confirm"
// The feature modules, imported STATICALLY (issue #305). Only the default
// entry uses these: there `__SPLIT__` is false (scripts/build_client.js
// defines it), every reference below sits in a `__SPLIT__ ? … : …` branch the
// minifier keeps, and the features end up in the same file as the runtime,
// called directly. The opt-in entry (core) is built with `__SPLIT__` true:
// those branches fold away, and its build resolves these five imports to an
// empty module, so core.min.js imports no feature until a root needs one.
//
// THE ORDER BELOW IS THE DEFAULT BUNDLE'S LAYOUT, not the connect order (that
// is #connectFeaturesNow's, persist first). The bundler lays the features out
// in import order, ahead of this file's own code, and gzip only matches text
// within 32 KB: a feature that repeats what the runtime also says (defer's
// fetch headers and meta reads, persist's editor selector, form's dirty
// marker) compresses against it only when it sits close to the runtime. This
// order was the smallest of a swap search over all of them (issue #310):
// ~450 B gzipped less than the table order. None of the features runs
// anything at import time, so the order changes bytes, never behaviour.
import * as bindingsFeature from "phlex/reactive/features/bindings"
import * as computeFeature from "phlex/reactive/features/compute"
import * as persistFeature from "phlex/reactive/features/persist"
import * as formFeature from "phlex/reactive/features/form"
import * as effectsFeature from "phlex/reactive/features/effects"
import * as devtoolsFeature from "phlex/reactive/features/devtools"
import * as hintsFeature from "phlex/reactive/features/hints"
import * as deferFeature from "phlex/reactive/features/defer"

// phlex/reactive/runtime — the reactive controller WITHOUT its feature
// modules (issue #275): the code both client entries share. It is not an
// entry itself and is never pinned; each entry is built with this file inside
// it. An app reaches it one of two ways, never both:
//
//   phlex/reactive/reactive_controller  the default: this runtime bundled with
//                                       every feature in one file, built with
//                                       __SPLIT__ false (issue #305): the
//                                       features are imported statically and
//                                       called directly, and connect inside
//                                       connect(). It has no table and NO way
//                                       to import one.
//   phlex/reactive/core                 opt-in: this runtime plus the table of
//                                       import() calls (core.js). A feature is
//                                       imported the first time a root on the
//                                       page needs it (see "Feature modules").
//
// The ONE generic controller behind every reactive Phlex component. It
// replaces the per-feature Stimulus controllers you'd otherwise hand-write
// for interactive components. A component declares its actions in Ruby (via
// Phlex::Reactive::Component); this controller binds DOM events to a single
// HTTP round trip and lets Turbo apply the re-rendered component back in
// (replace by default; method="morph" — Response.morph — preserves focus).
//
// Wire format (client -> server), POST <action path>, turbo-stream Accept:
//   { token: "<signed identity>", act: "<action>", params: {...} }   (JSON)
// (`act`, not `action`: `action` is a reserved Rails routing param.)
// The token is a MessageVerifier-signed { component, gid } — NO state is sent.
// When the root holds a chosen <input type="file">, the SAME payload is sent as
// multipart FormData instead (token/act flat, params bracketed, files appended)
// so an upload reaches the action (issue #34) — only the encoding differs.
// The response is a <turbo-stream> that replaces the component by its id.
//
// Server -> client live updates use the SAME element id, pushed over the
// stream transport (pgbus SSE / Action Cable) via the Streamable
// .broadcast_* methods — so a click and a background broadcast converge on
// one re-render unit.
//
// Custom turbo-stream action: the server tells the actor to full-navigate
// (e.g. the record's slug changed and the current URL is now dead). It rides a
// 200 turbo-stream — NOT an HTTP 3xx — so it never trips the response.redirected
// bail below (which still correctly catches real auth/CSRF redirects). Registered
// once on the Turbo global (no @hotwired/turbo import — the gem uses window.Turbo
// everywhere, and a named import is unreliable under importmap/esbuild).
export function registerReactiveVisit() {
  const actions = window.Turbo?.StreamActions
  if (!actions || actions["reactive:visit"]) return
  actions["reactive:visit"] = function () {
    const url = this.getAttribute("data-url")
    if (url) window.Turbo.visit(url, { action: "advance" })
  }
}

// Custom turbo-stream action: a TOKEN-ONLY refresh (issue #30). A partial
// update (Response.streams / reply.streams) re-renders only PART of a component
// — so there's no full-self replace to carry the next signed token. The server
// instead emits `<turbo-stream action="reactive:token" target="<id>"
// data-reactive-token-value="<fresh>">`. #perform's #extractToken already reads
// the token out of the response body for the NEXT queued request; this handler
// keeps the DOM in sync too, writing the attribute onto the root element so the
// `tokenValue` fallback stays fresh. It's a pure attribute set — no node is
// replaced — so a focused <input> + caret survive (the whole point: update a
// total cell without tearing down the field the user is typing in).
export function registerReactiveToken() {
  const actions = window.Turbo?.StreamActions
  if (!actions || actions["reactive:token"]) return
  actions["reactive:token"] = function () {
    const token = this.getAttribute("data-reactive-token-value")
    const target = this.getAttribute("target")
    if (!token || !target) return
    const el = document.getElementById(target)
    // Stimulus reads the token via the `token` value -> data-reactive-token-value.
    if (el) el.setAttribute("data-reactive-token-value", token)
  }
}

// Custom turbo-stream action: SERVER-PUSHED client DOM ops (issue #97). The
// server-side sibling of on_client's runOps — a reply (reply.<verb>.js(ops)) or
// a broadcast (Streamable.broadcast_js_to) emits
//
//   <turbo-stream action="reactive:js" target="<optional root id>"
//                 data-reactive-ops="[[op, args], ...]"></turbo-stream>
//
// and Turbo invokes this handler with `this` bound to that <turbo-stream>
// element. It runs the ops through the SAME frozen CLIENT_OPS whitelist as
// runOps (client-side default-deny — an unknown op warns + is skipped), so a
// forged/stale ops attr can never break the page or execute anything off the
// vocabulary. NO token, NO fetch — a pure local DOM mutation.
//
// `target` (optional, an element id) scopes op resolution to that root: "@root"
// resolves to the target element itself and a selector resolves WITHIN it.
// Without a target, ops resolve document-wide (a broadcast op like
// add_class("#bell", ...) that isn't anchored to one component). The op stream
// is emitted AFTER all render streams in the reply (the endpoint appends it
// last), so focus("[name=next]") sees the freshly morphed DOM — Turbo applies
// streams in document order.
export function registerReactiveJs() {
  const actions = window.Turbo?.StreamActions
  if (!actions || actions["reactive:js"]) return
  actions["reactive:js"] = function () {
    const list = parseOps(this.getAttribute("data-reactive-ops"))
    if (!list.length) return
    const targetId = this.getAttribute("target")
    // Issue #237: the server stamps the verbose gate on the stream element
    // itself (verbose_errors), so document-scoped ops are diagnosable too.
    const verbose = this.getAttribute("data-reactive-verbose") === "true"
    // With a target: scope to that element (missing → no-op). Without: document.
    const root = targetId ? document.getElementById(targetId) : null
    if (targetId && !root) {
      if (verbose) {
        if (__SPLIT__) withFeature("devtools", (devtools) => devtools.missingRoot(targetId))
        else devtoolsFeature.missingRoot(targetId)
      }
      return
    }
    applyOps(
      list,
      (args) => streamOpTargets(args, root),
      verbose
        ? (name, args) =>
            __SPLIT__
              ? withFeature("devtools", (devtools) => devtools.diagnoseStream(name, args, root))
              : devtoolsFeature.diagnoseStream(name, args, root)
        : undefined,
    )
  }
}

// --- Deferred and lazy renders (issues #165, #276, #277) ---------------------
// reply.defer, reactive_lazy and reactive_lazy(on:/cache:) live in the defer
// feature module (issue #275, features/defer.js). The core keeps only the
// `reactive:defer` stream action's REGISTRATION: such a stream can reach a
// page that has not loaded the module yet (the first reply.defer on a page
// with no lazy root), and it must not be lost. The <turbo-stream> element is
// handed over once the module is here — at once when it already is.
export function registerReactiveDefer() {
  const actions = window.Turbo?.StreamActions
  if (!actions || actions["reactive:defer"]) return
  actions["reactive:defer"] = function () {
    if (__SPLIT__) withFeature("defer", (defer) => defer.streamAction(this))
    else deferFeature.streamAction(this)
  }
}

// --- Around a stream render: effects and dismissing flashes (issues #100, #215) ---
// Both live in the effects feature module (issue #275, features/effects.js).
// The runtime keeps the ONE document-level turbo:before-stream-render listener
// (it fires for every <turbo-stream>: a reply AND a broadcast) and hands each
// event to the module, which wraps event.detail.render.
//
// In the default client the module is always here. The opt-in client may not
// have imported it yet when a stream first needs it; what happens then is that
// entry's business (core.js installs it: the stream's render waits for the
// import). The runtime only offers the event.
let streamRenderRegistered = false
let streamWithoutEffects = null

export function registerReactiveStreamRender() {
  if (streamRenderRegistered) return
  if (typeof document === "undefined" || typeof document.addEventListener !== "function") return
  streamRenderRegistered = true
  document.addEventListener("turbo:before-stream-render", (event) => {
    // The opt-in entry sees every stream (it may hold one for a module the
    // incoming content needs); with no entry hook, a loaded effects module
    // wraps the stream directly — in the default entry, always.
    if (!__SPLIT__) effectsFeature.wrap(event)
    else if (streamWithoutEffects) streamWithoutEffects(event, featureModules.get("effects"))
    else featureModules.get("effects")?.wrap(event)
  })
}
// The names this registration had while it was two listeners.
export { registerReactiveStreamRender as registerReactiveDismiss, registerReactiveStreamRender as registerReactiveEffects }

// For the opt-in entry: what to do with a stream before its render — hold it
// for a module the incoming content needs. `handle(event, effects)` gets the
// loaded effects module (or undefined) and wraps the stream with it itself.
export function onReactiveStreamWithoutEffects(handle) {
  streamWithoutEffects = handle
}

export function __resetReactiveStreamRenderForTest() {
  streamRenderRegistered = false
}

// --- A morph keeps the focused field's value (issue #338) ---
// Turbo's stream morph (reply.morph, a broadcast morph) runs Idiomorph without
// ignoreActiveValue, so a field being typed in took the render's value: a
// normalised "Hello" over "Hello ", or the value as the request left. Two
// document listeners give a focused input/textarea inside a reactive root
// Idiomorph's own ignoreActiveValue behaviour, minus the stale default:
//   before-morph-element   — write the field's DEFAULT (its value attribute)
//                            from the new render ourselves; with the user's
//                            edit on it (the dirty-value flag) that never
//                            touches .value, so dirty tracking still re-scans
//                            against the saved value. A textarea's default is
//                            its text child, which Idiomorph still morphs.
//   before-morph-attribute — cancel `value` on that field: Idiomorph honours it
//                            for the attribute AND the property. Nothing else
//                            (a root's token, a field's class) is held.
// data-reactive-morph-value on a field lets the morph write it while focused.
let morphFocusRegistered = false

function holdsTypedValue(el) {
  return (
    el === document.activeElement &&
    (el.localName === "input" || el.localName === "textarea") &&
    !el.hasAttribute("data-reactive-morph-value") &&
    !!el.closest('[data-controller~="reactive"]')
  )
}

export function registerReactiveMorphFocus() {
  if (morphFocusRegistered) return
  if (typeof document === "undefined" || typeof document.addEventListener !== "function") return
  morphFocusRegistered = true
  document.addEventListener("turbo:before-morph-element", (event) => {
    const el = event.target
    const next = event.detail?.newElement // absent when Turbo asks before a removal
    if (!next || event.defaultPrevented || el.localName !== "input" || !holdsTypedValue(el)) return
    const value = next.getAttribute("value")
    if (value == null) el.removeAttribute("value")
    else if (el.getAttribute("value") !== value) el.setAttribute("value", value)
  })
  document.addEventListener("turbo:before-morph-attribute", (event) => {
    if (event.detail?.attributeName === "value" && holdsTypedValue(event.target)) event.preventDefault()
  })
}

export function __resetReactiveMorphFocusForTest() {
  morphFocusRegistered = false
}

// The framework-owned act a reactive_lazy(on:) shell sends (issue #276).
// Lockstep with Phlex::Reactive::Component::Lazy::MATERIALIZE_ACTION.
const LAZY_MATERIALIZE_ACTION = "__materialize"

// Offline CSS hook (issue #101). Mirror data-reactive-offline on
// document.documentElement from navigator.onLine, kept in sync by the window
// online/offline events — so an app can dim a save button or show a banner with
// PURE CSS and zero JS ([data-reactive-offline] .save { pointer-events: none }).
// Guarded on window (needed for addEventListener AND navigator) so importing the
// module in a non-browser (bun test) context is a no-op, and registered once
// (the online/offline listeners are NOT {once}, so a second registerReactiveActions
// call must not stack duplicates) — mirroring the dismiss guard + reset seam.
let offlineRegistered = false
export function registerReactiveOffline() {
  if (offlineRegistered) return
  if (typeof window === "undefined" || typeof document === "undefined") return
  if (typeof window.addEventListener !== "function") return
  offlineRegistered = true
  // toggleAttribute(name, force) writes data-reactive-offline="" (a bare boolean
  // attr the [data-reactive-offline] selector matches) or removes it — never the
  // "true" string. navigator.onLine === false is the reliable direction (a false
  // "online" is spec-permitted but rare, and this is only a presentational hook —
  // the authoritative offline signal is the #perform gate, not this attribute).
  // Fully defensive: a missing documentElement/toggleAttribute/navigator degrades
  // to a no-op — a presentational hook must NEVER throw during bootstrap.
  const sync = () => {
    const root = document.documentElement
    if (typeof root?.toggleAttribute !== "function") return
    root.toggleAttribute("data-reactive-offline", globalThis.navigator?.onLine === false)
  }
  sync() // seed synchronously so first paint is correct
  window.addEventListener("online", sync)
  window.addEventListener("offline", sync)
}

export function __resetReactiveOfflineForTest() {
  offlineRegistered = false
}

// Latency simulator dev aid (issue #102): features/devtools.js (issue #275). The
// core keeps the two places that decide whether the module is needed at all:
// the page opted into the console handle (the phlex-reactive-env meta), or a
// delay is stored for this tab. Read live per request, like the CSRF token.
const LATENCY_KEY = "phlex-reactive:latency"

function latencyStored() {
  return typeof sessionStorage !== "undefined" && Boolean(sessionStorage.getItem(LATENCY_KEY))
}

// At registration: a page that can use the simulator gets the module now —
// effectively eager, in development only. No meta and no stored delay: no
// module, no global handle, nothing on the page.
//
// This runtime registers with Turbo while it is being evaluated, BEFORE the
// entry that imports it has run — before the default entry has handed the
// module over, before the opt-in entry has said where to import it from. So
// with neither in place this does nothing, and each entry calls it again
// once it has done its part (see reactive_controller.js and core.js).
export function registerReactiveDev() {
  if (typeof document === "undefined") return
  if (__SPLIT__ && !featureModules.has("devtools") && !FEATURES.get("devtools")[1]) return
  const development = document.querySelector?.('meta[name="phlex-reactive-env"]')?.content === "development"
  // (The default entry has the module in it: there is nothing to load, and
  // attach() is idempotent, so the second call is harmless.)
  if (!__SPLIT__) {
    if (development) devtoolsFeature.attach()
  } else if (development || latencyStored()) withFeature("devtools", (devtools) => development && devtools.attach())
}

// --- Global reactive-activity signal (issue #201) --------------------------
// A DOCUMENT-LEVEL count of in-flight reactive operations — the direct analogue
// of Turbo's progress bar, but for reactive round trips and deferred renders
// instead of navigations. Anything that starts an async reactive operation calls
// enterReactiveActivity(); when it settles (success OR failure, on every path) it
// calls exitReactiveActivity(). The count is exposed two ways so an app — or a
// system test — can key off "is the reactive layer settling?" without knowing
// about any individual root:
//
//   * a marker on <html>: data-reactive-active present while count > 0 (CSS can
//     drive a global spinner; code/tests can read it). A DISTINCT name from the
//     per-root data-reactive-busy so a [data-reactive-busy] selector never also
//     matches the document element.
//   * events on document: reactive:busy on the 0 -> >0 edge, reactive:idle on the
//     >0 -> 0 edge — EDGES ONLY (not once per op), each carrying { count }.
//
// It sums ACROSS all reactive roots (module-level, not per-controller) and across
// the two async lifecycles wired below:
//   * dispatch — entered in #applyBusy (at ENQUEUE, so the queue wait counts too),
//     exited in the settle closure #perform runs in its finally.
//   * defer    — entered/exited with the pendingDefers registry (set/delete), the
//     ONE registry both the fetch (pull) and the stream (push) lane maintain — so
//     the push lane stays balanced even though it clears its pending markers by a
//     node swap, not clearDeferPending. A supersede is delete-then-set (net zero),
//     which is correct: a fast typist's replaced defer is still "layer busy".
//
// compute-seed is deliberately NOT counted: recompute() is synchronous, so a seed
// is fully applied by the time the call returns — there is no async window to await
// (the "value settles a beat after a morph/seed" case the issue describes is
// covered by the System test helpers' re-resolve-by-id polling, not this counter).
export const ACTIVE_ATTR = "data-reactive-active"

let activityCount = 0

// Increment the global in-flight count; on the 0 -> 1 edge, mark <html> and fire
// reactive:busy. Fully defensive — a non-browser/test document with no
// documentElement/dispatchEvent still tracks the count and simply skips the DOM
// side effects (a global signal must never throw during bootstrap or a round trip).
export function enterReactiveActivity() {
  activityCount++
  if (activityCount === 1) syncReactiveActivity("reactive:busy")
}

// Decrement the global in-flight count, clamped at 0 so an unbalanced exit can
// never drive it negative (which would wedge the marker on forever). On the
// 1 -> 0 edge, clear the <html> marker and fire reactive:idle.
export function exitReactiveActivity() {
  if (activityCount === 0) return
  activityCount--
  if (activityCount === 0) syncReactiveActivity("reactive:idle")
}

// The current in-flight count — a test seam and a runtime read (an app can gate an
// "unsaved changes" prompt on `reactiveActivityCount() > 0`).
export function reactiveActivityCount() {
  return activityCount
}

// Test seam: reset the module-level counter (and clear the marker) between tests,
// since the module is imported once per bun run.
export function resetReactiveActivity() {
  activityCount = 0
  const root = typeof document !== "undefined" ? document.documentElement : null
  root?.removeAttribute?.(ACTIVE_ATTR)
}

// Write the <html> marker from the current count and fire the edge event on
// document. Both sides are independently guarded so a partial document stub (a
// documentElement without toggleAttribute, or a document without dispatchEvent)
// degrades to a no-op rather than throwing.
function syncReactiveActivity(eventName) {
  if (typeof document === "undefined") return
  const root = document.documentElement
  if (typeof root?.toggleAttribute === "function") {
    root.toggleAttribute(ACTIVE_ATTR, activityCount > 0)
  }
  if (typeof document.dispatchEvent === "function" && typeof CustomEvent === "function") {
    document.dispatchEvent(new CustomEvent(eventName, { detail: { count: activityCount } }))
  }
}

// --- Reactive request totals (issue #279) ----------------------------------
// A running total of the reactive REQUESTS made, per kind — "action" (one per
// #perform fetch) and "defer" (one per performDeferFetch) — so a system test can
// assert "one request on first open, none after". The in-flight count above says
// whether the layer is settling; this says how much it did.
//
// The JSON on <html data-reactive-requests> IS the store (read-modify-write per
// request): a test reads it, and re-baselines by writing zeros, with no window
// hook and no module state to drift from it. Written ONLY under the verbose gate
// — data-reactive-verbose on <html> or on any reactive root (stamped in dev/test
// by default) — so production writes nothing. The gate is checked once per
// network request, never per event.
export const REQUESTS_ATTR = "data-reactive-requests"

export function countReactiveRequest(kind) {
  if (typeof document === "undefined") return
  const root = document.documentElement
  if (typeof root?.setAttribute !== "function" || !reactiveRequestsCounted(root)) return
  const totals = readReactiveRequests(root)
  totals[kind] = (Number(totals[kind]) || 0) + 1
  root.setAttribute(REQUESTS_ATTR, JSON.stringify(totals))
}

function reactiveRequestsCounted(root) {
  return root.hasAttribute?.("data-reactive-verbose") || !!document.querySelector?.('[data-reactive-verbose="true"]')
}

// The current totals, or zeros when the attribute is absent or not an object
// (a hand-edited / garbled value restarts the count rather than throwing).
function readReactiveRequests(root) {
  try {
    const parsed = JSON.parse(root.getAttribute(REQUESTS_ATTR))
    if (parsed && typeof parsed === "object") return { action: 0, defer: 0, ...parsed }
  } catch {}
  return { action: 0, defer: 0 }
}

export function registerReactiveActions() {
  registerReactiveVisit()
  registerReactiveToken()
  registerReactiveJs()
  registerReactiveDefer()
  registerReactiveStreamRender()
  registerReactiveMorphFocus()
  registerReactiveOffline()
  registerReactiveDev()
}

// Escape a DOM id for safe interpolation into a RegExp (an id can legally contain
// regex metacharacters like `.`/`:` — e.g. an `escape:`-namespaced or dotted id).
// Used by #extractToken to match the stream that re-renders THIS element by id.
export function escapeRegExp(string) {
  return string.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
}

// --- Loaded-twice guard (issue #275) ------------------------------------------
// Each shipped entry carries its own copy of this file. An app that imports
// BOTH phlex/reactive/reactive_controller and phlex/reactive/core (or bundles
// one and pins the other) gets two runtimes: two request queues' worth of
// module state, two activity counters, two feature tables. Say so, loudly.
const CORE_LOADED = Symbol.for("phlex-reactive.core")
if (globalThis[CORE_LOADED]) {
  console.error(
    "[phlex-reactive] the client was loaded twice. Import EITHER phlex/reactive/reactive_controller (the default, " +
      "everything in one file) OR phlex/reactive/core (features on demand), not both — each carries its own state.",
  )
}
globalThis[CORE_LOADED] = true

// --- Registration guard (issue #26 part 2) -------------------------------
// In a `lazyLoadControllersFrom("controllers", application)` app, only
// controllers under app/javascript/controllers/ are registered. This module
// lives outside that dir, so importing it isn't enough — `data-controller=
// "reactive"` does NOTHING until the host runs application.register("reactive",
// ...). The failure is silent: components render, but no action ever fires.
//
// We can't warn from connect() in that case (connect never runs). Instead, once
// the page is ready, if reactive elements exist but no controller has connected,
// the controller wasn't registered — so we warn, pointing at the fix.
let reactiveConnected = false

export function checkReactiveRegistration() {
  if (reactiveConnected) return
  if (typeof document === "undefined") return
  const els = document.querySelectorAll('[data-controller~="reactive"]')
  if (!els || els.length === 0) return
  console.warn(
    "[phlex-reactive] found " + els.length + ' element(s) with data-controller="reactive" ' +
      "but the reactive controller never connected. It is loaded but not registered — " +
      'add `application.register("reactive", ReactiveController)` (importmap) or import it ' +
      "into app/javascript/controllers/ for lazyLoadControllersFrom apps. See the README."
  )
}

// Test seams (no-ops in production usage).
export function __resetReactiveRegistrationForTest() {
  reactiveConnected = false
}
export function __markReactiveConnectedForTest() {
  reactiveConnected = true
}

if (typeof window !== "undefined" && typeof document !== "undefined") {
  // Defer past initial controller connection (a microtask/tick after ready).
  const scheduleCheck = () => setTimeout(checkReactiveRegistration, 0)
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", scheduleCheck, { once: true })
  } else {
    scheduleCheck()
  }
}

// The interpret-time attribute-name allowlist (issue #96) — the SECOND half of
// the two-sided default-deny. The Ruby builder already refuses these at build
// time; this guards a hand-built / forged ops attr from bypassing it. Refused:
// event handlers (on*, XSS), URL-bearing names (a javascript: navigation
// surface), and style (CSS injection). Case-insensitive, mirroring js.rb.
const REFUSED_ATTR_URL = new Set(["href", "src", "srcdoc", "action", "formaction", "xlink:href", "style"])
function attrRefused(name) {
  const lower = String(name).toLowerCase()
  return lower.startsWith("on") || REFUSED_ATTR_URL.has(lower)
}

// Run an animated visibility change (issue #96 `transition:`). `flip` performs
// the actual hidden-flag change; `[during, from, to]` are class lists applied
// AROUND it. Cleanup is awaited via the element's OWN animationend/transitionend
// OR a setTimeout fallback — whichever comes first — so an element with NO
// animation never leaves the helper classes stuck (the op chain itself is not
// blocked: cleanup is fire-and-forget, later ops run immediately). Both end
// events bubble, so a descendant's is ignored, and settling drops both
// listeners (the effects.js fix, #296). The fallback is armed synchronously,
// not behind the frame, so a hidden tab (no rAF) still cleans up; cleanup then
// cancels the pending frame and clears `from` too, so a late frame can't leave
// `to` (or `from`) stuck. A one-shot `done` guard runs cleanup exactly once.
// One run per element: a new run first settles the live one (its classes,
// timer, listeners and frame), so a superseded run's late wakeups can't strip
// the new run's classes. The fallback follows the element's computed
// durations (transitionFallbackMs), so a 600 ms transition isn't cut at 350.
const transitionRuns = new WeakMap()
function runTransition(el, transition, flip) {
  const [during, from, to] = transition
  transitionRuns.get(el)?.()
  el.classList.add(during, from)
  flip()
  let done = false
  const frame = requestAnimationFrame(() => {
    if (done) return
    el.classList.remove(from)
    el.classList.add(to)
  })

  const cleanup = (event) => {
    if (done || (event && event.target !== el)) return
    done = true
    transitionRuns.delete(el)
    clearTimeout(timer)
    globalThis.cancelAnimationFrame?.(frame)
    el.removeEventListener("animationend", cleanup)
    el.removeEventListener("transitionend", cleanup)
    el.classList.remove(during, from, to)
  }
  transitionRuns.set(el, cleanup)
  el.addEventListener("animationend", cleanup)
  el.addEventListener("transitionend", cleanup)
  // Also the ONLY path for a non-animated element (no end event fires there),
  // so it must always be scheduled — and never behind the frame.
  const timer = setTimeout(cleanup, transitionFallbackMs(el))
}

// The longest computed duration × iteration-count + delay over the transition
// and animation lists (CSS repeats the shorter list; a transition runs once,
// `infinite` hits the cap), plus 50 ms; 350 ms when nothing is declared (or
// there is no computed style), capped at 5 s so a bogus value can't wedge the
// classes on. Read once `during` is on the element.
function transitionFallbackMs(el) {
  let longest = 0
  try {
    const style = getComputedStyle(el)
    for (const kind of ["transition", "animation"]) {
      const [durations, delays] = ["Duration", "Delay"].map((name) =>
        String(style[kind + name])
          .split(",")
          .map((v) => parseFloat(v) * (/ms/.test(v) ? 1 : 1000) || 0),
      )
      const counts = String(style[kind + "IterationCount"])
        .split(",")
        .map((v) => (/inf/.test(v) ? Infinity : parseFloat(v) >= 0 ? parseFloat(v) : 1))
      for (let i = 0; i < durations.length || i < delays.length || i < counts.length; i++) {
        const runs = durations[i % durations.length] * counts[i % counts.length] || 0
        longest = Math.max(longest, runs + delays[i % delays.length])
      }
    }
  } catch {}
  return Math.min(Math.max(longest + 50, 350), 5000)
}

// Rich-text and contenteditable fields, as #collectFields reads them (minus
// the [name] guard — an editor's name may live on its IDL `name` getter:
// Trix's `input=`-paired hidden input). The persist feature keeps its own copy
// of these two constants (features never import the core); a test pins that
// they stay equal.
export const EDITOR_SELECTOR =
  ":is(lexxy-editor, trix-editor, [contenteditable=''], [contenteditable=true], [contenteditable=plaintext-only])"
export const EDITOR_TAGS = new Set(["lexxy-editor", "trix-editor"])

// A RICH editor (lexxy/trix) is only ready once its custom element upgraded —
// Trix defines its elements in a setTimeout after load — and exposes the
// string `value` accessor; reading it before that yields "", which is issue
// #8. A bare [contenteditable] is plain DOM and always ready.
function collectorEditorReady(el) {
  return EDITOR_TAGS.has(el.localName) ? typeof el.value === "string" : true
}

// The client-op whitelist behind on_client (issue #95, extended in #96). Mirrors
// Phlex::Reactive::JS's vocabulary; an op name not in this map is
// warn-and-skipped by #applyOps (client-side default-deny — a stale or newer
// ops attr must never break the page). Each op is a pure, local DOM mutation:
// nothing is sent anywhere, and nothing is read back — with ONE deliberate
// exception, paste_into (issue #228), which reads the clipboard behind the
// browser's own gesture + permission gates and still only writes locally.
// Frozen so nothing can be registered into it at runtime — extending the
// vocabulary is a gem change, not an app hook.
const CLIENT_OPS = Object.freeze({
  show: (el, args, resolveTargets) => setVisibility(el, false, args, resolveTargets),
  hide: (el, args, resolveTargets) => setVisibility(el, true, args, resolveTargets),
  toggle: (el, args, resolveTargets) => setVisibility(el, !el.hidden, args, resolveTargets),
  add_class: (el, args) => el.classList.add(...(args.classes ?? [])),
  remove_class: (el, args) => el.classList.remove(...(args.classes ?? [])),
  toggle_class: (el, args) => (args.classes ?? []).forEach((c) => el.classList.toggle(c)),

  // Attribute ops (issue #96), interpret-time allowlisted. set_attr writes the
  // (already-stringified) value; toggle_attr adds a missing attr (value "") or
  // removes a present one — or, given values [on, off] (issue #271), flips
  // between them (an absent attr becomes `on`); remove_attr removes it. A
  // refused name warns + skips.
  set_attr: (el, args) => {
    if (guardAttr(args.name)) el.setAttribute(args.name, args.value ?? "")
  },
  remove_attr: (el, args) => {
    if (guardAttr(args.name)) el.removeAttribute(args.name)
  },
  toggle_attr: (el, args) => {
    if (!guardAttr(args.name)) return
    if (Array.isArray(args.values)) {
      const [on, off] = args.values
      el.setAttribute(args.name, el.getAttribute(args.name) === on ? off : on)
    } else if (el.hasAttribute(args.name)) el.removeAttribute(args.name)
    else el.setAttribute(args.name, "")
  },

  // Focus ops (issue #96). focus targets the match itself; focus_first targets
  // its first focusable descendant (opened-menu → first menuitem).
  focus: (el) => el.focus?.(),
  focus_first: (el) => firstFocusable(el)?.focus?.(),

  // Text op (issue #159): set textContent — XSS-safe by construction (never
  // innerHTML), strictly less powerful than set_attr. Change-guarded like
  // #mirrorText. With global: true it is the cross-root text escape: paint a
  // value into a recap node OUTSIDE the component's root.
  text: (el, args) => {
    const text = String(args.value ?? "")
    if (el.textContent !== text) el.textContent = text
  },

  // Tick or untick a whole checkbox group (issue #342) — "clear selection".
  // The bindings feature flips the root's OWNED boxes the way its select-all
  // header does (every box set, then input + change on each flipped one) and
  // re-syncs the group bindings once. global: true ignores the op's own root
  // and asks every reactive root on the page; each flips only the boxes it
  // owns, so the one that holds the group answers.
  check_group: (el, args) => {
    const roots = args.global ? document.querySelectorAll('[data-controller~="reactive"]') : [el]
    for (const root of roots) {
      __SPLIT__
        ? withFeature("bindings", (bindings) => bindings.checkGroup(root, args.group, args.checked))
        : bindingsFeature.checkGroup(root, args.group, args.checked)
    }
  },

  // Dispatch a bubbling CustomEvent (issue #96). RAW element.dispatchEvent — the
  // controller SHADOWS Stimulus's this.dispatch helper, so it must not be used.
  dispatch: (el, args) => {
    el.dispatchEvent(new CustomEvent(args.name, { bubbles: true, composed: true, detail: args.detail ?? {} }))
  },

  // Submit the target's OWN form (issue #226) via requestSubmit() — constraint
  // validation runs and a REAL cancelable `submit` event fires, so an
  // on(:action, event: "submit") interception or a native/Turbo form handles it
  // exactly like a user submit. No form → no-op. ACTOR-ONLY like focus: the
  // broadcast builder refuses it server-side (BROADCAST_REFUSED_OPS).
  // `submitter:` (issue #319) resolves with the op's own scoping (the
  // `expanded:` precedent) and submits THROUGH it, so its name=value posts. It
  // must be a submit control of that form — requestSubmit(x) throws otherwise —
  // so anything else warns and falls back to a plain requestSubmit().
  submit: (el, args, resolveTargets) => {
    const form = submitFormFor(el)
    if (!form) return
    let submitter = null
    if (args?.submitter != null && typeof resolveTargets === "function") {
      submitter = resolveTargets({ ...args, to: args.submitter })[0] ?? null
      if (!(submitter?.form === form && (submitter.type === "submit" || submitter.type === "image"))) {
        console.warn(`[phlex-reactive] submitter ${args.submitter} is not a submit control of the form — ignored`)
        submitter = null
      }
    }
    submitter ? form.requestSubmit?.(submitter) : form.requestSubmit?.()
  },

  // Clipboard-source paste (issue #228): on a user gesture, read
  // navigator.clipboard.readText() and feed the text into the target field
  // through the normal input pipeline — exactly what a native Cmd/Ctrl+V does.
  // The ONE op that reads a browser API and is async: fire-and-forget, so
  // applyOps stays sync and chain siblings never wait (the runTransition
  // posture). A rejected/dismissed read, empty text, or a missing API is a
  // SILENT no-op — page state must not change. ACTOR-ONLY like focus/submit:
  // the broadcast builder refuses it server-side (BROADCAST_REFUSED_OPS) —
  // and that server gate is the REAL one. The browser only partially backs it
  // up: Safari gates every read on a fresh gesture and Firefox shows its
  // paste picker per read, but Chromium's clipboard-read is a PERSISTENT
  // per-origin permission — once granted (the legit paste button itself
  // induces that), readText() succeeds with no gesture. No client-side
  // refusal is possible here: the reactive:js interpreter cannot distinguish
  // an actor reply's stream from a broadcast's, and reply.js legitimately
  // carries this op.
  paste_into: (el) => pasteClipboardInto(el),

  // Client-only drafts (issue #239): merge a flat state bag into the root's
  // reactive_persist draft / forget the draft. ACTOR-ONLY like focus/submit
  // (BROADCAST_REFUSED_OPS server-side) — rewriting or wiping every
  // subscriber's draft from a broadcast would be hostile.
  // The draft code lives in the persist feature module (issue #275), so both
  // ops run once it has loaded — at once on a root that restored a draft.
  persist_state: (el, args) =>
    __SPLIT__
      ? withFeature("persist", (persist) => persist.writeState(el, args.state))
      : persistFeature.writeState(el, args.state),
  persist_clear: (el) =>
    __SPLIT__ ? withFeature("persist", (persist) => persist.clearRoot(el)) : persistFeature.clearRoot(el),
})

// The form a submit op commits (issue #226), in order: the target itself when
// it IS a form (tagName, not instanceof — fake-node/test friendly), its form
// owner for a control (input.form — honors a form= attribute), else the nearest
// ancestor form. closest() may cross the component root by design — the
// FIELD'S OWN form is the submit scope, not the reactive boundary.
function submitFormFor(el) {
  if (el?.tagName === "FORM") return el
  return el?.form ?? el?.closest?.("form") ?? null
}

// Read the clipboard into a field (issue #228) — the body of the paste_into
// op. The write mirrors a native paste: set .value, dispatch a bubbling
// `input` event (the set-value + dispatch contract, issue #183 — compute
// reducers, show bindings, and on_complete all run exactly as if the user
// had typed), then focus (the caret lands where the user continues typing on
// a partial paste). Availability-guarded: insecure contexts and some
// webviews have no navigator.clipboard — the connect()-time gate hides
// marked triggers there, so this guard is belt-and-braces. Empty text is a
// no-op: "paste nothing" must not clear a half-typed field.
function pasteClipboardInto(field) {
  const clipboard = globalThis.navigator?.clipboard
  if (typeof clipboard?.readText !== "function") return
  clipboard
    .readText()
    .then((text) => {
      if (!text) return
      field.value = text
      if (typeof field.dispatchEvent === "function") field.dispatchEvent(new Event("input", { bubbles: true }))
      field.focus?.()
    })
    .catch(() => {
      // Permission denied or the prompt dismissed — the browser's own UX said
      // no. The issue-#228 contract: a silent no-op, never an error.
    })
}

// Apply a hidden-flag change, optionally animated by a [during, from, to]
// transition (issue #96). Split out so show/hide/toggle share it.
function setHidden(el, hidden, args) {
  if (args?.transition) runTransition(el, args.transition, () => (el.hidden = hidden))
  else el.hidden = hidden
}

// show/hide/toggle (issue #271): flip visibility, then mirror the INTENDED
// state into the `expanded:` target's aria-expanded — computed before the flip,
// so a transition never delays or races it. The expanded target resolves with
// the op's own scoping (root-scoped, or document-wide under global: true).
function setVisibility(el, hidden, args, resolveTargets) {
  setHidden(el, hidden, args)
  if (args?.expanded == null || typeof resolveTargets !== "function") return
  for (const target of resolveTargets({ ...args, to: args.expanded })) {
    target.setAttribute?.("aria-expanded", String(!hidden))
  }
}

// The interpret-time attribute guard: refuse (warn + skip) a name off the
// allowlist. Returns true when the op may proceed.
function guardAttr(name) {
  if (!attrRefused(name)) return true
  console.warn(`[phlex-reactive] refused client attr op on ${JSON.stringify(name)} — skipped`)
  return false
}

// The first focusable descendant of `el`, in document order — the natural
// keyboard target inside an opened menu/dialog. Covers the standard focusable
// set; :not([tabindex="-1"]) drops explicitly-removed nodes. Returns null when
// nothing inside is focusable (focus_first then no-ops).
const FOCUSABLE = 'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])'
function firstFocusable(el) {
  return el.querySelectorAll?.(FOCUSABLE)?.[0] ?? null
}

// Parse a [[name, args], ...] op list from a raw attr/param. An array passes
// through; a JSON string is parsed; anything malformed degrades to [] — a bad
// ops attr must NEVER break the page (client-side default-deny). Shared by the
// controller's runOps and the reactive:js stream action (issue #97).
function parseOps(raw) {
  if (Array.isArray(raw)) return raw
  if (typeof raw !== "string") return []
  try {
    const list = JSON.parse(raw)
    return Array.isArray(list) ? list : []
  } catch {
    return []
  }
}

// --- on_client binding records (issue #271) -----------------------------------
// Each on_client call emits ONE record ({on, ops, window?, outside?, confirm?,
// confirmWhen?}); mix space-joins several onto one element (spaces inside a
// record ride as \u0020, so the join is unambiguous). Stimulus hands every
// runOps descriptor on an element the SAME event.params, so runOps selects the
// record(s) whose descriptor matches the firing event: event.type, the key
// filter, and window-boundness.

// Stimulus's default keyMappings (letters and digits map to themselves). A
// custom Stimulus schema is not mirrored — an unknown filter never matches.
const KEY_FILTER_MAP = Object.freeze({
  enter: "Enter",
  tab: "Tab",
  esc: "Escape",
  space: " ",
  up: "ArrowUp",
  down: "ArrowDown",
  left: "ArrowLeft",
  right: "ArrowRight",
  home: "Home",
  end: "End",
  page_up: "PageUp",
  page_down: "PageDown",
})
const KEY_FILTER_MODIFIERS = Object.freeze(["meta", "ctrl", "alt", "shift"])

// Stimulus's rule: the four modifiers must match EXACTLY (ctrl+k is not k);
// the remaining token is compared to event.key case-insensitively. A
// non-keyboard event (no event.key) checks the modifiers only. `keyMappings`
// is the app's Stimulus schema table (custom keys included) when the
// controller has one; the default table is the fallback.
function keyFilterMatches(filter, event, keyMappings) {
  const parts = filter.split("+")
  for (const mod of KEY_FILTER_MODIFIERS) {
    if (parts.includes(mod) !== Boolean(event[`${mod}Key`])) return false
  }
  const token = parts.find((part) => !KEY_FILTER_MODIFIERS.includes(part))
  if (token === undefined || typeof event.key !== "string") return true
  const key =
    keyMappings && Object.hasOwn(keyMappings, token)
      ? keyMappings[token]
      : Object.hasOwn(KEY_FILTER_MAP, token)
        ? KEY_FILTER_MAP[token]
        : /^[a-z0-9]$/.test(token)
          ? token
          : null
  return typeof key === "string" && key.toLowerCase() === event.key.toLowerCase()
}

// Parse data-reactive-ops-param into binding records. Stimulus typecasts a
// lone record to an object; several records stay a string (JSON.parse fails on
// the join) and are split here. A LEGACY [[op, args]] list (array or JSON
// string — a hand-built attr) becomes one record flagged `legacy`: it has no
// `on`, so it always matches, and runOps reads its flags from event.params. A
// malformed piece warns and is skipped; its siblings still run (default-deny).
function parseBindingRecords(raw) {
  if (Array.isArray(raw)) return [{ ops: raw, legacy: true }]
  if (raw && typeof raw === "object") return [raw]
  if (typeof raw !== "string") return []
  const text = raw.trim()
  if (text.startsWith("[")) return [{ ops: parseOps(text), legacy: true }]
  const records = []
  for (const piece of text.split(" ")) {
    if (piece === "") continue
    let record = null
    try {
      record = JSON.parse(piece)
    } catch {
      record = null
    }
    if (record && typeof record === "object" && !Array.isArray(record)) records.push(record)
    else console.warn(`[phlex-reactive] malformed on_client binding record ${JSON.stringify(piece)} — skipped`)
  }
  return records
}

// Does this record's descriptor match the firing event? The window check
// matters for an element carrying both `click` and `click@window`: one inside
// click reaches both listeners, and only currentTarget tells them apart. It is
// recognised structurally (isWindow), so an undefined currentTarget is never
// window-bound and a replay built for another document's window still counts
// (issue #303). Only a LEGACY record (no `on` by
// construction) matches everything; any other record without a descriptor is
// malformed and never matches (default-deny). `keyMappings === null` skips the
// key filter (the caller's single-candidate shortcut).
function bindingMatches(record, event, keyMappings) {
  if (record.legacy) return true
  const on = record.on
  if (typeof on !== "string" || on === "") return false
  const dot = on.indexOf(".")
  if (event.type !== (dot < 0 ? on : on.slice(0, dot))) return false
  if (Boolean(record.window) !== isWindow(event.currentTarget)) return false
  return dot < 0 || keyMappings === null || keyFilterMatches(on.slice(dot + 1), event, keyMappings)
}

// A `once: true` record (PR #272) is spent after its first run. Stimulus
// removes only that binding's own listener; a regular same-event sibling on
// the element keeps calling runOps with BOTH records, so the spent one is
// skipped here. Spent state belongs to the TRIGGER element (a WeakMap, so it
// is collected with it): a morph/stream that swaps in a fresh element starts
// fresh, and a byte-identical sibling trigger has its own. A window-bound
// binding's currentTarget is the window, so there the element's ops attr joins
// the key (a re-rendered window-bound once trigger with the same markup stays
// spent — a known limit; spentEarlyOnce below has the same one for a replayed
// `:once` hotkey).
const spentOnceBindings = new WeakMap()
function onceBindingSpent(controller, event, record) {
  if (!record.once) return false
  const owner = event.currentTarget ?? controller.element
  let byOwner = spentOnceBindings.get(controller)
  if (!byOwner) {
    byOwner = new WeakMap()
    spentOnceBindings.set(controller, byOwner)
  }
  let spent = byOwner.get(owner)
  if (!spent) {
    spent = new Set()
    byOwner.set(owner, spent)
  }
  const raw = event.params?.ops
  const attr = owner === globalThis.window ? `${typeof raw === "string" ? raw : JSON.stringify(raw ?? null)}|` : ""
  const key = attr + JSON.stringify(record)
  if (spent.has(key)) return true
  spent.add(key)
  return false
}

// Two identical descriptors on one element (two mix-ed on_client calls with
// the same event) are two Stimulus bindings, so runOps runs twice for ONE
// event. The first call runs every matching record; a repeat is a no-op.
// "Repeat" is (controller, listener target, the element's ops attr): Stimulus
// walks EVERY binding of one window listener with the SAME event object, so
// keying on currentTarget alone (= window) would drop every other root's
// window-bound binding — and a sibling element's within one root. The ops attr
// is the per-element key (a lone record is typecast to a fresh object per
// binding, so it is compared by its JSON). Two elements in one root carrying
// byte-identical window-bound records run once — the same ops, applied once.
const ranBindings = new WeakMap()
function bindingsAlreadyRan(event, controller) {
  if (event === null || typeof event !== "object") return false
  const raw = event.params?.ops
  const key = typeof raw === "string" ? raw : JSON.stringify(raw ?? null)
  let byController = ranBindings.get(event)
  if (!byController) {
    byController = new WeakMap()
    ranBindings.set(event, byController)
  }
  let byTarget = byController.get(controller)
  if (!byTarget) {
    byTarget = new Map()
    byController.set(controller, byTarget)
  }
  let keys = byTarget.get(event.currentTarget)
  if (!keys) {
    keys = new Set()
    byTarget.set(event.currentTarget, keys)
  }
  if (keys.has(key)) return true
  keys.add(key)
  return false
}

// Interpret a [[name, args], ...] op list against the frozen CLIENT_OPS
// whitelist (issues #95/#96/#97). `resolveTargets(args)` returns the element(s)
// an op applies to — the controller scopes to its root (excluding nested
// reactive roots); the reactive:js stream action scopes to its target root (or
// the document). An unknown name warns and is SKIPPED while the rest of the
// chain still applies — client-side default-deny, one bad op never takes down
// its siblings. Object.hasOwn (not a bare read) so inherited Object members
// ("constructor") can't masquerade as ops.
function applyOps(list, resolveTargets, onZeroTargets) {
  for (const entry of list) {
    if (!Array.isArray(entry)) continue
    const [name, args = {}] = entry
    if (!Object.hasOwn(CLIENT_OPS, name)) {
      console.warn(`[phlex-reactive] unknown client op ${JSON.stringify(name)} — skipped`)
      continue
    }
    const targets = resolveTargets(args)
    if (targets.length === 0 && onZeroTargets) onZeroTargets(name, args)
    for (const el of targets) CLIENT_OPS[name](el, args, resolveTargets)
  }
}

// Resolve a reactive:js op's targets against its `target` root (issue #97).
// "@root" is the root element itself; a selector resolves WITHIN it; a bare
// selector with no root (no `target` attr on the stream) resolves document-wide
// — a broadcast op anchored by a global selector (#bell) rather than a
// component. Unlike the controller path there is no nested-reactive-root
// ownership filter: a server-pushed op names its own scope explicitly —
// including `global: true`, which opts a single op out of the target-root
// scope to document-wide resolution (issue #159; the same escape the builder
// documents for the controller path).
function streamOpTargets(args, root) {
  const to = args.to
  if (root) {
    if (to === "@root") return [root]
    if (typeof to !== "string" || to === "") return []
    if (args.global) return [...document.querySelectorAll(to)]
    return [...root.querySelectorAll(to)]
  }
  // No target root: document-scoped. "@root" is meaningless here (nothing to
  // anchor to) → no-op; a selector matches document-wide.
  if (typeof to !== "string" || to === "" || to === "@root") return []
  return [...document.querySelectorAll(to)]
}

// --- Feature modules (issue #275) ---------------------------------------------
// The client is a small core plus feature modules a page loads only when one
// of its roots asks for them. Each entry is [needs, load, waiting?, gates?]:
//
//   needs(root)    a cheap marker read — does this root use the feature?
//                  null for a feature no root asks for (it is loaded by
//                  something page-level instead).
//   load()         how to import the module — NOT written here. core.js,
//                  the opt-in entry, supplies one per feature
//                  (registerReactiveFeatureLoader): a LITERAL
//                  import("phlex/reactive/features/<name>"), so a bundler can
//                  see the specifier and the import map resolves it to its
//                  own digested file. The default entry supplies none: its
//                  features are part of the file.
//   waiting(root, pending)
//                  optional, and like load() supplied by core.js (only the
//                  opt-in client ever waits): what must not be missed WHILE
//                  the import is on its way. Runs when a root starts waiting, RECORDS into
//                  `pending` (a plain object the feature receives later) and
//                  returns its own undo. Core bytes — record, never act.
//   gates          optional, true when the feature's connect changes what a
//                  REQUEST reads (the draft restore writes the fields a
//                  request collects). A root's action requests wait for its
//                  features only while one that gates is still loading; a
//                  feature that does not gate never delays a request.
//
// TABLE ORDER IS CONNECT ORDER (and disconnect order): persist is first
// because its restore writes the values every other connect-time seed reads.
//
// A feature module exports
//
//   install(shared)             optional; once, when it has loaded
//   connect(controller, core, morphed, pending)
//                               once per root connection; `pending` is what
//                               its `waiting` hook recorded (undefined when
//                               the root never had to wait)
//   disconnect(controller, core)
//                               FIRST in the controller's disconnect()
//   abandon(root, pending)      optional; the root left BEFORE the feature
//                               could connect — last chance to act on
//                               what was recorded
//
// and never imports this file (two copies of the core would split its state).
// `shared` is FEATURE_SHARED below: the core's single-instance counters.
// Everything a feature needs from one controller arrives as `core`, the
// handle #featureCore builds — the ONE door into its private state:
//
//   core.emit(name, detail, options)      raw-dispatch a lifecycle event
//   core.reseed()                         re-run the connect-time seeds that
//                                         read field values
//   core.proceed(target, action, params)  send an action down the ordinary
//                                         pipeline (veto, queue, request)
//   core.forgetToken()                    drop the token cached from a reply
//   core.owns(el)                         is this control this root's own, not
//                                         a nested reactive root's (issue #15)
//   core.ownership()                      the hoisted per-pass form of owns
//   core.opTargets(args)                  the elements an op's `to:` names
//   core.applyOps(list, defaultTo)        run an op list root-scoped
//   core.diagnose(label, args)            the zero-target warning
//   core.listnavOptions(event)            the keyboard-navigable options
//   core.collectFields()                  this root's fields, as a request
//                                         would send them
//   core.confirm(message, context)        the confirm gate (resolves a boolean)
//
// Later features add to that handle; nothing else of the controller is theirs
// to touch beyond its public surface (element, application, …).
//
// WHEN A FEATURE CONNECTS. A module that is already here connects inside
// connect() itself, in the same task, before the early-queue drain. In the
// default bundle (phlex/reactive/reactive_controller) that is every feature,
// always: they are handed over before anything connects, and nothing below
// about imports, waiting, gates or timeouts ever applies.
//
// With phlex/reactive/core alone, the first root on a page that needs a
// feature waits for its import: connect() only starts it, and the feature
// connects when the module has arrived — after every feature EARLIER in the
// table that this root is also waiting for (table order), never after a later
// one: a slow defer import does not hold the draft restore back. Once the
// module is loaded (a later root, the next Turbo visit, a reconnect) it too
// connects inside connect().
//
// THE DEFAULT ENTRY HAS NONE OF THIS (issue #305). It is built with
// `__SPLIT__` false: the runtime imports every feature statically and calls
// it directly — connect() connects what the root's markers ask for, in this
// order, by name in the source and by nothing at all in the minified file.
// No table, no loader, no import(): what is below is the opt-in entry's.

// The marker checks of the features that connect per root. The default entry
// calls them directly (#connectFeaturesNow); the table below hands them to
// the loader.
function persistNeeded(root) {
  const declared = root.getAttribute?.("data-reactive-persist")
  return Boolean(declared) && declared !== "off"
}

// reply.defer, reactive_lazy, reactive_lazy(on:/cache:). A root is a lazy
// shell when it carries any of these; real content carries none.
function deferNeeded(root) {
  return ["defer-token", "defer-src", "lazy-on", "lazy-visible"].some(
    (marker) => root.getAttribute?.(`data-reactive-${marker}`) != null,
  )
}

// Dirty tracking with its navigate-away guard, and the paste-trigger gate:
// the root or anything inside it carries one of the two markers. (A nested
// root's marker loads the module for its parent too; the module then checks
// ownership before it wires anything.)
function formNeeded(root) {
  return (
    (root.getAttribute?.("data-action") ?? "").includes("reactive#trackDirty") ||
    root.getAttribute?.("data-reactive-clipboard") != null ||
    root.querySelector?.('[data-action*="reactive#trackDirty"],[data-reactive-clipboard]') != null
  )
}

// Show bindings and cross-root show targets, completion bindings, option
// filtering, the bulk-selection group bindings (enable, select-all, count —
// issue #319), the tag-chip input and draft nested rows: a form's client-only
// bindings. The root declares one, or owns an element that does. (The probes
// the connect-time gates ran before the split, unchanged.)
function bindingsNeeded(root) {
  return (
    ["show-targets", "on-complete", "filter-input", "tags-field"].some(
      (marker) => root.getAttribute?.(`data-reactive-${marker}`) != null,
    ) ||
    (root.querySelectorAll?.("[data-reactive-show-field], [data-reactive-show]") ?? []).length > 0 ||
    root.querySelector?.(
      "[data-reactive-nested-json], [data-reactive-nested-list], [data-reactive-confirm-when-param], [data-reactive-enable], [data-reactive-select-all], [data-reactive-count]",
    ) != null
  )
}

// Client-side computes: the root carries a reactive_compute binding.
function computeNeeded(root) {
  return root.getAttribute?.("data-reactive-compute-inputs-param") != null
}

const PRODUCTION_FEATURES = [
  // (Its `waiting` hook is the opt-in entry's: core.js.) The draft restore
  // writes what a request reads, so it gates.
  ["persist", [persistNeeded, null, null, true]],
  ["defer", [deferNeeded, null]],
  ["form", [formNeeded, null]],
  // Its seeds write what a request reads (the JSON-mode rows), so it gates.
  ["bindings", [bindingsNeeded, null, null, true]],
  // The seed writes output fields a request collects, so it gates.
  ["compute", [computeNeeded, null, null, true]],
  [
    // Stream effects and dismissing flashes are document-level: the module
    // has no connect. A root that DECLARES an effect only gets it fetched
    // early, so the first stream need not wait for it (see streamHold).
    "effects",
    [
      (root) => ["enter", "update", "exit"].some((hook) => root.getAttribute?.(`data-reactive-effect-${hook}`) != null),
      null,
    ],
  ],
  [
    // The optimistic/busy hint engine: a trigger in the root declares a hint.
    // No connect — the module acts at enqueue — so the marker is only read
    // while it is not loaded, and a root that declares one preloads it.
    "hints",
    [
      (root) =>
        root.querySelector?.(
          "[data-reactive-optimistic-param], [data-reactive-busy-param], [data-reactive-loading-param]",
        ) != null,
      null,
    ],
  ],
  [
    // Development aids: the latency simulator (page-level, see
    // registerReactiveDev), the zero-target diagnostics and the debug trace.
    // A root in debug mode preloads it; a verbose root asks for it the first
    // time it has something to warn about.
    "devtools",
    [(root) => root.getAttribute?.("data-reactive-debug") === "true", null],
  ],
]
// (Only the opt-in entry has a table: `new Map` would keep it in the default.)
const FEATURES = __SPLIT__ ? new Map(PRODUCTION_FEATURES) : null

// name -> the one import promise every root shares, kept even when it
// rejected: a browser caches a module that failed to load, so importing it
// again only re-rejects. A failed feature stays failed until the page is
// reloaded; every root it costs is told (reactive:error).
const featureLoads = __SPLIT__ ? new Map() : null
// name -> the loaded module: what lets a later root connect a feature inside
// connect(), and a stream action or client op use it in the same tick.
const featureModules = __SPLIT__ ? new Map() : null
// The modules the default bundle handed over (registerReactiveFeature); only
// the test seam below reads it back.
const featuresGiven = __SPLIT__ ? new Map() : null

// How the opt-in entry (core.js) tells the runtime where a feature module is
// — `load`, a function returning its import() — and, optionally, what to
// record while that import is on its way (`waiting`, see above).
export function registerReactiveFeatureLoader(name, load, waiting) {
  if (__SPLIT__) {
    featureLoaders.set(name, [load, waiting])
    applyFeatureLoader(name)
  }
}

// name -> [load, waiting] the opt-in entry registered: kept apart from the
// table so a test's reset of the table puts them back.
const featureLoaders = __SPLIT__ ? new Map() : null

function applyFeatureLoader(name) {
  const entry = FEATURES.get(name)
  const [load, waiting] = featureLoaders.get(name)
  entry[1] = load
  entry[2] = waiting
}

// Hand the runtime a feature that is ALREADY loaded — what
// phlex/reactive/reactive_controller does for every feature before anything
// can connect. Such a feature is never imported: it connects inside connect().
export function registerReactiveFeature(name, feature) {
  if (__SPLIT__) {
    feature.install?.(FEATURE_SHARED)
    featureModules.set(name, feature)
    featuresGiven.set(name, feature)
  }
}

// For the opt-in entry: the features some of `elements` (reactive roots a
// stream is about to render) need and that are not loaded — read off the
// table, so a new feature is covered by its own marker check.
export function unloadedFeaturesFor(elements) {
  const names = []
  if (__SPLIT__) {
    for (const [name, [needs]] of FEATURES) {
      if (!needs || featureModules.has(name)) continue
      try {
        if (elements.some((el) => needs(el))) names.push(name)
      } catch {
        // a marker check that throws is that root's problem at connect, not the stream's
      }
    }
  }
  return names
}

// For the opt-in entry: import a feature now. Resolves with the module, or
// with undefined once the failure has been logged.
export function loadReactiveFeature(name) {
  return __SPLIT__
    ? loadFeature(name).catch((error) => logFeatureFailure(name, "load", error))
    : Promise.resolve()
}

function loadFeature(name) {
  let loading = featureLoads.get(name)
  if (!loading) {
    const load = FEATURES.get(name)[1] ?? (() => Promise.reject(new Error("this entry has no way to import it")))
    loading = load().then((feature) => {
      feature.install?.(FEATURE_SHARED)
      featureModules.set(name, feature)
      return feature
    })
    featureLoads.set(name, loading)
  }
  return loading
}

// Logged once per feature and phase per page (a failed import would otherwise
// log again for every root that connects). `phase` says what went wrong:
// "detect" (its marker check threw), "load" (the import failed — and stays
// failed until the page is reloaded), "timeout" (slow; the root carried on
// without it) or "connect" (it threw while wiring a root).
const featureFailuresLogged = new Set()

function logFeatureFailure(name, phase, error) {
  const logged = name + phase
  if (featureFailuresLogged.has(logged)) return
  featureFailuresLogged.add(logged)
  console.error(
    `[phlex-reactive] the "${name}" feature module (phlex/reactive/features/${name}) is unavailable: ${phase}. ` +
      "If you bundle or vendor the client, alias or pin phlex/reactive/features/* (README: esbuild / webpack / bun).",
    error,
  )
}

// Run `use(feature)` with a feature — for code with no root connection to
// wait on (a client op, a stream action): in this tick when the module is
// loaded, else once it has arrived. A feature that cannot load is logged.
function withFeature(name, use) {
  const feature = featureModules.get(name)
  if (feature) return use(feature)
  loadFeature(name).then(use, (error) => logFeatureFailure(name, "load", error))
}

// How long a root waits for a feature import before it carries on without it
// (<meta name="phlex-reactive-feature-timeout" content="ms"> in <head>).
// 10 s: the modules are a few KB, so even a slow 3G fetch (seconds, not tens
// of seconds) finishes well inside it, and it matches the early-event TTL —
// the other "how long may the client be late" window. A feature that arrives
// AFTER the timeout still connects; the timeout only stops it holding back
// the root's other features and its action requests.
const DEFAULT_FEATURE_TIMEOUT_MS = 10000

function featureTimeoutMs() {
  const ms = Number(globalThis.document?.head?.querySelector?.('meta[name="phlex-reactive-feature-timeout"]')?.content)
  return Number.isFinite(ms) && ms > 0 ? ms : DEFAULT_FEATURE_TIMEOUT_MS
}

export function reactiveFeatureNames() {
  return __SPLIT__
    ? [...FEATURES.keys()]
    : ["persist", "defer", "form", "bindings", "compute", "effects", "hints", "devtools"]
}

export function __setReactiveFeatureForTest(name, needs, load, waiting, gates) {
  if (!__SPLIT__) return
  FEATURES.set(name, [needs, load, waiting, gates])
}

// Test-only: a feature's table entry, to wrap one part of it.
export function __reactiveFeatureEntryForTest(name) {
  return FEATURES.get(name)
}

// Test-only: import a feature now (a later connect is then synchronous).
export function __loadReactiveFeatureForTest(name) {
  if (__SPLIT__) return loadFeature(name)
  const modules = {
    persist: persistFeature,
    defer: deferFeature,
    form: formFeature,
    bindings: bindingsFeature,
    compute: computeFeature,
    effects: effectsFeature,
    hints: hintsFeature,
    devtools: devtoolsFeature,
  }
  return Promise.resolve(modules[name])
}

// Test-only: back to the shipped table, with nothing logged and only the
// modules the default bundle handed over still loaded — or, `cold`, with none
// loaded at all: the state of a page that imported phlex/reactive/core.
export function __resetReactiveFeaturesForTest(cold) {
  // (The default entry has no table to reset: its features are static.)
  if (!__SPLIT__) return
  FEATURES.clear()
  for (const [name, entry] of PRODUCTION_FEATURES) FEATURES.set(name, entry)
  // (Only the opt-in entry registers any; with the default entry alone the
  // table stays without a way to import, as shipped.)
  for (const name of featureLoaders.keys()) applyFeatureLoader(name)
  featureLoads.clear()
  featureModules.clear()
  if (!cold) for (const [name, feature] of featuresGiven) featureModules.set(name, feature)
  featureFailuresLogged.clear()
}

const FEATURES_READY = Promise.resolve()

// The single-instance module state a feature may add to (install()): ONE
// in-flight activity count and one request total per page, whoever counts.
// `waiting` maps a root to { <feature name>: pending } while it waits for that
// feature's import (see the `waiting` hook above).
function forgetWaiting(root, name, pending) {
  const waiting = FEATURE_SHARED.waiting.get(root)
  // (A root that reconnected meanwhile has a NEW record under the same name.)
  if (waiting && waiting[name] === pending) delete waiting[name]
}

const FEATURE_SHARED = {
  enter: enterReactiveActivity,
  exit: exitReactiveActivity,
  count: countReactiveRequest,
  waiting: new WeakMap(),
}

// The default entry's per-root features, one bit each (#connectFeaturesNow).
const PERSIST = 1
const DEFER = 2
const FORM = 4
const BINDINGS = 8
const COMPUTE = 16

// The default entry's features are part of this file: install them now, as
// the opt-in entry does when one arrives.
if (!__SPLIT__) {
  persistFeature.install(FEATURE_SHARED)
  deferFeature.install(FEATURE_SHARED)
}

// --- Early triggers (issue #273) ----------------------------------------------
// phlex/reactive/early (imported eagerly by the app) queues trigger events that
// reach a root before its controller connects. The queue is shared through a
// Symbol.for key on window — no import edge either way, so either module may
// load first, and an app that never imports early gets an empty queue.
const EARLY_KEY = Symbol.for("phlex-reactive.early")
const DEFAULT_EARLY_TTL_MS = 10000
// A window-bound trigger (a hotkey, issue #303) is replayed only this soon
// after the keypress: later, the user has moved on. A shorter configured TTL
// still wins.
const WINDOW_EARLY_TTL_MS = 1500

// Is this event's currentTarget a Window (a Stimulus `@window` listener)? The
// page's window, or any Window recognised structurally (another document's,
// which a replay built from its trigger element's document carries).
const isWindow = (target) => target != null && (target === globalThis.window || target.window === target)

function earlyState() {
  globalThis[EARLY_KEY] ??= { queue: [], connected: new WeakSet() }
  return globalThis[EARLY_KEY]
}

// <meta name="phlex-reactive-early-ttl" content="ms"> (Phlex::Reactive.
// early_event_ttl_ms), parsed defensively like the timeout meta.
function earlyTtlMs() {
  const ms = Number(globalThis.document?.querySelector?.('meta[name="phlex-reactive-early-ttl"]')?.content)
  return Number.isFinite(ms) && ms > 0 ? ms : DEFAULT_EARLY_TTL_MS
}

// Stimulus's param reader (data-reactive-<name>-param, JSON-typecast,
// camelized) — a replayed trigger carries the same event.params a live one does.
function stimulusParams(el) {
  const params = {}
  for (const { name, value } of Array.from(el.attributes ?? [])) {
    const match = /^data-reactive-(.+)-param$/i.exec(name)
    if (!match) continue
    let typed
    try {
      typed = JSON.parse(value)
    } catch {
      typed = value
    }
    params[match[1].replace(/[-_]([a-z0-9])/g, (_, char) => char.toUpperCase())] = typed
  }
  return params
}

// The event a replay hands to dispatch()/runOps(). It is called DIRECTLY, not
// re-dispatched on the element: a real event would also re-run every OTHER
// listener on the trigger (a lazily connected sibling controller that already
// handled the original click would toggle twice). The original's default was
// already prevented (or deliberately kept) by early.js, so preventDefault here
// is a no-op. A window-bound entry (issue #303) is replayed as Stimulus's
// window listener sees it: currentTarget is the window, params come from `el`.
function earlyReplayEvent(event, el, win) {
  return {
    [EARLY_KEY]: true,
    type: event.type,
    detail: event.detail,
    target: event.target,
    currentTarget: win ? el.ownerDocument.defaultView : el,
    params: stimulusParams(el),
    key: event.key,
    code: event.code,
    metaKey: event.metaKey,
    ctrlKey: event.ctrlKey,
    altKey: event.altKey,
    shiftKey: event.shiftKey,
    button: event.button,
    submitter: event.submitter,
    bubbles: event.bubbles,
    timeStamp: event.timeStamp,
    defaultPrevented: event.defaultPrevented,
    preventDefault() {},
    stopPropagation() {},
    stopImmediatePropagation() {},
  }
}

// A :once trigger that was REPLAYED is spent, but Stimulus's own `once`
// listener for it is still armed (the replay calls the method directly). The
// markup is left alone — rewriting data-action would let a morph, which writes
// the server's attribute back, re-arm it — so the spent descriptor is tracked
// per trigger element (a WeakMap: a replaced element starts fresh, like a live
// `once`), and the armed listener's single firing is swallowed. A window-bound
// descriptor's live call carries the window as currentTarget, not its
// element, so it is tracked under the ROOT instead (issue #303), flagged
// `win` (apart from the root's own element-bound descriptors) and told apart
// from its siblings by the params Stimulus reads off its element.
//
// Known limit of the root-keyed entry (the same class as onceBindingSpent's
// window-bound limit above): a reply that MORPHS the root but swaps the
// trigger element gives Stimulus a fresh `once` listener for the new element
// while this entry stays armed, so the next live press is swallowed here and
// that fresh listener is consumed — the hotkey is dead until the root
// disconnects. Keep a `:once` hotkey's trigger element stable across replies,
// or bind the hotkey without `once:`.
const spentEarlyOnce = new WeakMap()

function spendEarlyOnce(owner, { token, type, method, filter, win }, params) {
  let spent = spentEarlyOnce.get(owner)
  if (!spent) spentEarlyOnce.set(owner, (spent = new Map()))
  const key = win ? `${token} ${params}` : token
  if (spent.has(key)) return false
  spent.set(key, { type, method, filter, win, params, armed: true })
  return true
}

// True (once) for the live call that comes from a spent descriptor's listener:
// same element, method, event type AND key filter — a sibling descriptor with
// another filter (keydown.esc beside a spent keydown.enter:once) is not it.
//
// Also true for the ORIGINAL of a replayed event arriving live at the same
// element (issue #274): waking a dormant root can connect its controller while
// the waking event is still propagating (an eagerly registered controller
// connects in the microtask checkpoint after early.js's capture listener), so
// the event reaches the listener Stimulus just bound after it was replayed.
// Only as many live calls as the replay RAN for that element and method are
// dropped — a binding the replay skipped (a key filter only the app's own
// mapping matches) still runs.
function earlyOnceSwallows(event, method, keyMappings, root) {
  if (event?.[EARLY_KEY]) return false
  const win = isWindow(event?.currentTarget)
  // A window-bound replay is owned by its ROOT: another root's binding on the
  // same window event is not it (issue #303).
  const owner = win ? root : event?.currentTarget
  const replayed = takeEarlyReplay(event, owner, win ? `@${method}` : method)
  const spent = spentEarlyOnce.get(owner)
  const params = win && JSON.stringify(event.params)
  for (const entry of spent?.values() ?? []) {
    if (!entry.armed || entry.method !== method || entry.type !== event.type || Boolean(entry.win) !== win) continue
    if (win && entry.params !== params) continue
    if (entry.filter && !keyFilterMatches(entry.filter, event, keyMappings)) continue
    entry.armed = false
    return true
  }
  return replayed
}

// event → (element → { dispatch: n, runOps: n }): how many bindings a replay
// ran while its original may still be propagating. The entry lasts for that
// propagation only — a new task starts after the whole dispatch is over — so
// the same event OBJECT dispatched again later is live.
const replayedEarly = new WeakMap()

function markEarlyReplay(event, el, method) {
  let byElement = replayedEarly.get(event)
  if (!byElement) {
    replayedEarly.set(event, (byElement = new Map()))
    setTimeout(() => replayedEarly.delete(event))
  }
  const counts = byElement.get(el) ?? {}
  byElement.set(el, counts)
  counts[method] = (counts[method] ?? 0) + 1
}

function takeEarlyReplay(event, owner, method) {
  const counts = event && replayedEarly.get(event)?.get(owner)
  if (!counts?.[method]) return false
  counts[method] -= 1
  return true
}

// Register this controller eagerly OR lazily: with phlex/reactive/early
// imported, a trigger that fires before connect is replayed on connect (issue
// #273). The engine auto-pins it with preload: true for importmap apps; see
// the README for esbuild/webpack.
export default class extends Controller {
  static values = {
    token: String, // signed identity token (component + record gid/state)
  }

  #tokenCache // freshest token, threaded synchronously across queued requests
  #debounceTimers = new Map() // trigger element -> { timer, flush } pending dispatch
  #throttleTimers = new Map() // trigger element -> Map(action -> suppression timer)
  #actionPathCache // page-stable action path, resolved once per controller
  #timeoutMsCache // page-stable request timeout (ms), resolved once per controller (issue #101)
  #tokenRegexCache // { id, token, self } — #extractToken's two per-id RegExps, rebuilt on id change (issue #118)
  // Loading-state bookkeeping (issue #99). All keyed so overlapping enqueues
  // refcount correctly and never clobber each other:
  #busyPending = 0 // root aria-busy pending counter (remove only at zero)
  #busyActions = new Map() // action -> in-flight count (root's space-separated busy set + busy_on)
  #busyTokenCounts = new WeakMap() // element -> Map(action -> count): its data-reactive-busy token set
  // Dirty tracking (issue #103): the bound re-scan (turbo:morph-element) and the
  // navigate-away guard handlers, held so disconnect() can remove exactly them.
  // The root-only morph listener of a token root or lazy shell (#275, #312): a morph
  // can add a feature's marker to a connected root. Held for teardown.
  #boundRootMorph
  // Clipboard-trigger availability gate (issue #228): the bound morph re-sync,
  // held for teardown.
  // Client-only drafts (issue #239): the parsed root payload (null when
  // undeclared), the restore-complete latch (no write may run before the
  // connect restore — a connect must never overwrite a draft with server
  // blanks), the ONE per-root trailing-edge write timer, and the bound
  // input/change/turbo:submit-end handlers held for teardown.
  // Feature modules (issue #275). `featuresReady` resolves once the features
  // this root needs have connected (or been given up on: failed, or slower
  // than the timeout) — it never rejects, and is already resolved for a root
  // that needs none. connect() only STARTS the imports. The name is long on
  // purpose: it is a public field, and a short `ready` would shadow a method
  // an app's own subclass may well define.
  // #featureEpoch changes on every connect and disconnect, so an import that
  // resolves for a connection that has since ended connects nothing.
  featuresReady = FEATURES_READY
  #features = new Map() // name -> module connected on this connection
  #featuresWanted = new Set() // names this connection has asked for
  #featuresSettling = false // true while featuresReady is still pending
  #featureGate = null // settles when the last feature that `gates` has connected
  #featureWaits = new Map() // pending import-timeout timer -> its wait's resolve
  #featureHooks = new Map() // name -> [undo, pending] of a feature still on its way
  #featureTurns = new Map() // name -> settles once that feature has had its turn to connect
  #featureEpoch = 0
  #featureHandle // the `core` handle features receive, built on first use
  // The default entry (issue #305): one bit per feature, PERSIST … COMPUTE —
  // asked for (its marker read true) and connected on this connection.
  #featuresAsked = 0
  #featuresOn = 0

  // Mark that a reactive controller actually connected, so the registration
  // guard above knows the controller was registered (issue #26 part 2).
  connect() {
    reactiveConnected = true
    // Early triggers (issue #273): from here on Stimulus delivers this root's
    // events live (its bindings are already wired), so early.js must stop
    // queueing them NOW — a connect-time seed below (a compute output write)
    // dispatches real input events. The queue itself drains at the very end.
    earlyState().connected.add(this.element)

    // Root-id guard (issue #48). The token round trip assumes the reactive root
    // element's id == component.id: the server targets component.id and the client
    // self-matches its NEXT token by this.element.id (#extractToken, issue #46).
    // If `id:` landed on a CHILD instead of the `**reactive_attrs` root, this id is
    // "" — #extractToken falls back to the FIRST token in the response (a child's),
    // so the next action POSTs a foreign token → endpoint default-deny → silent 403.
    // Warn NOW (on connect) so the failure surfaces on page load, not on click 2.
    if (this.element.id === "") {
      console.warn(
        "[phlex-reactive] a reactive root has no id; its next-action token can't self-match " +
          "and may fall back to the first token in the response → a silent HTTP 403 on the NEXT action. " +
          "Put id: on the SAME element as reactive_attrs — use div(**reactive_root) (emits id + token together), " +
          "or div(id:, **reactive_attrs). The id: must NOT be on a child. See the README."
      )
    }

    // Lazy shells (reactive_lazy, on:, cache:) are wired by the defer feature
    // module (issue #275), which #loadFeatures below starts importing when the
    // root carries one of its markers. What stays here is the root-only morph
    // listener of a TOKEN-BEARING root or a LAZY SHELL: a Turbo morph can turn
    // a root that connected on REAL content (no marker, so no feature) into a
    // shell while it stays connected — no Stimulus lifecycle fires — and only
    // a listener that is already there can notice and load the feature. A
    // shell carries no identity token (a `cache:` one has its URL, issue #306;
    // a plain one its defer token), and a morph can turn it, still connected,
    // into a root that needs another feature (issue #312). It costs a root
    // without any marker, before and after the morph, a few attribute reads and
    // never an import. (turbo:morph-element BUBBLES: only a morph of the root
    // itself counts.) A tokenless, client-only root has no such listener.
    if (this.element.getAttribute?.("data-reactive-token-value") != null || deferNeeded(this.element)) {
      this.#boundRootMorph = (event) => {
        if (event.target !== this.element) return
        if (__SPLIT__) this.#loadFeatures(true)
        else this.#connectFeaturesNow(true)
      }
      this.element.addEventListener?.("turbo:morph-element", this.#boundRootMorph)
    }

    // Feature modules (issue #275): connect the ones that are here and START
    // the import of any that is not. HERE, before the seeds below, because
    // this is where their work used to sit: the draft restore (persist) writes
    // the values those seeds read, the dirty baseline (form) comes before
    // them. A module that is still on its way connects when it arrives and
    // re-runs the seeds itself (#reseed). Never awaited — connect() must reach
    // the drain at the end in the same task (issue #274: an await before it
    // runs a waking click twice).
    this.#featureEpoch++
    this.featuresReady = FEATURES_READY
    if (__SPLIT__) this.#loadFeatures()
    else this.#connectFeaturesNow()

    // LAST, after every feature above is wired: a replayed trigger must find
    // the controller exactly as a live event after connect would.
    this.#announceConnected()
  }

  // The default entry (issue #305): every feature is in this file, so each
  // one this root's markers ask for connects now, by a direct call, in the
  // order the opt-in entry's table gives (persist first: its restore writes
  // the values the later seeds read). Again after a morph of the root, for a
  // marker the morph added. The features with no per-root connect (effects,
  // hints, devtools) act when called.
  #connectFeaturesNow(morphed) {
    if (!__SPLIT__) {
      this.#connectFeatureNow(PERSIST, "persist", persistNeeded, (core) => persistFeature.connect(this, core, morphed))
      this.#connectFeatureNow(DEFER, "defer", deferNeeded, (core) => deferFeature.connect(this, core, morphed))
      this.#connectFeatureNow(FORM, "form", formNeeded, (core) => formFeature.connect(this, core, morphed))
      this.#connectFeatureNow(BINDINGS, "bindings", bindingsNeeded, (core) => bindingsFeature.connect(this, core, morphed))
      this.#connectFeatureNow(COMPUTE, "compute", computeNeeded, (core) => computeFeature.connect(this, core, morphed))
    }
  }

  // Once per connection: a marker check that throws loses that feature (and
  // is read again after a morph), a connect that throws loses it until the
  // root reconnects — never the rest of connect().
  #connectFeatureNow(bit, name, needs, connect) {
    if (!__SPLIT__) {
      if (this.#featuresAsked & bit) return
      try {
        if (!needs(this.element)) return
      } catch (error) {
        return this.#featureFailed(name, "detect", error)
      }
      this.#featuresAsked |= bit
      try {
        connect(this.#featureCore())
        this.#featuresOn |= bit
      } catch (error) {
        this.#featureFailed(name, "connect", error)
      }
    }
  }

  // FIRST in disconnect(), in connect order, while the root is still intact
  // (the draft flush reads its fields).
  #disconnectFeaturesNow() {
    if (!__SPLIT__) {
      const on = this.#featuresOn
      this.#featuresAsked = this.#featuresOn = 0
      const core = this.#featureCore()
      if (on & PERSIST) this.#disconnectFeatureNow("persist", () => persistFeature.disconnect(this, core))
      if (on & DEFER) this.#disconnectFeatureNow("defer", () => deferFeature.disconnect(this, core))
      if (on & FORM) this.#disconnectFeatureNow("form", () => formFeature.disconnect(this, core))
      if (on & BINDINGS) this.#disconnectFeatureNow("bindings", () => bindingsFeature.disconnect(this, core))
      if (on & COMPUTE) this.#disconnectFeatureNow("compute", () => computeFeature.disconnect(this, core))
    }
  }

  #disconnectFeatureNow(name, disconnect) {
    if (!__SPLIT__) {
      try {
        disconnect()
      } catch (error) {
        console.error(`[phlex-reactive] the "${name}" feature module failed to disconnect`, error)
      }
    }
  }

  // Starts the import of every feature this root needs and has not asked for
  // yet — at connect, and again after a morph of the root (which may have
  // added a marker; `morphed`). Every import starts now; each feature connects
  // when its own module has arrived (or is given up on) AND the features
  // before it in the table have had their turn — the order their connect-time
  // seeds depend on, never the order the network delivered them in — unless
  // this connection ended meanwhile.
  #loadFeatures(morphed) {
    if (__SPLIT__) {
      const epoch = this.#featureEpoch
      const names = []
      for (const [name, [needs]] of FEATURES) {
        if (!needs || this.#featuresWanted.has(name)) continue
        // Loaded, and with nothing to do per root: its marker need not be read.
        const loaded = featureModules.get(name)
        if (loaded && !loaded.connect) continue
        // A marker check that throws loses that feature, never the rest of
        // connect() — above all not the early drain that follows it.
        try {
          if (needs(this.element)) names.push(name)
        } catch (error) {
          this.#featureFailed(name, "detect", error)
        }
      }
      if (names.length === 0) return
      for (const name of names) this.#featuresWanted.add(name)
      // Every module already here (a later root, the next Turbo visit): connect
      // now, in this task — nothing to wait for, so nothing to gate or time out.
      if (!this.#featuresSettling && names.every((name) => featureModules.has(name))) {
        for (const name of names) this.#connectFeature(epoch, name, featureModules.get(name), morphed)
        return
      }
      for (const name of names) {
        const arrival = this.#awaitFeature(epoch, name)
        // Its turn comes after the features BEFORE it in the table that this
        // root is still waiting for — never after a later one, even one whose
        // import started earlier (a morph can add an earlier feature's marker).
        const earlier = []
        for (const key of FEATURES.keys()) {
          if (key === name) break
          if (this.#featureTurns.has(key)) earlier.push(this.#featureTurns.get(key))
        }
        const turn = Promise.all(earlier)
          .then(() => arrival)
          .then((feature) => feature && this.#connectFeature(epoch, name, feature, morphed))
        this.#featureTurns.set(name, turn)
        if (FEATURES.get(name)[3]) this.#featureGate = turn
      }
      // Requests stop waiting the moment the last gating feature has connected.
      const gate = this.#featureGate
      gate?.then(() => {
        if (this.#featureGate === gate) this.#featureGate = null
      })
      this.#featuresSettling = true
      const ready = Promise.all(this.#featureTurns.values()).then(() => {
        if (this.featuresReady === ready) this.#featuresSettling = false
      })
      this.featuresReady = ready
    }
  }

  // One feature's import, for one scan: resolves with the module, or with
  // null once the import failed or outlasted the timeout — so one slow or
  // broken feature never holds back the others. A module that arrives after
  // its timeout still connects (late, and so out of table order).
  #awaitFeature(epoch, name) {
    if (__SPLIT__) {
      const current = () => epoch === this.#featureEpoch
      this.#startWaitingFor(name)
      return new Promise((resolve) => {
        let timedOut = false
        const timer = setTimeout(() => {
          this.#featureWaits.delete(timer)
          timedOut = true
          if (current()) this.#featureFailed(name, "timeout", new Error(`not loaded after ${featureTimeoutMs()} ms`))
          resolve(null)
        }, featureTimeoutMs())
        // Kept with its resolve: a disconnect ends the wait (#disconnectFeatures),
        // or whatever is queued behind featuresReady would hang on a stuck import.
        this.#featureWaits.set(timer, resolve)
        const settled = () => {
          clearTimeout(timer)
          this.#featureWaits.delete(timer)
        }
        loadFeature(name).then(
          (feature) => {
            settled()
            // Late: connect one microtask on, after whatever else was queued on
            // this import while the root waited.
            if (timedOut) queueMicrotask(() => this.#connectFeature(epoch, name, feature))
            else resolve(feature)
          },
          (error) => {
            settled()
            if (current()) this.#featureFailed(name, "load", error)
            resolve(null)
          },
        )
      })
    }
  }

  // Run the feature's `waiting` hook (if it has one) and remember its undo and
  // what it records, for #connectFeature or #disconnectFeatures to hand on.
  #startWaitingFor(name) {
    if (__SPLIT__) {
      const hook = FEATURES.get(name)[2]
      if (!hook) return
      const pending = {}
      try {
        this.#featureHooks.set(name, [hook(this.element, pending), pending])
        FEATURE_SHARED.waiting.set(this.element, { ...FEATURE_SHARED.waiting.get(this.element), [name]: pending })
      } catch (error) {
        this.#featureFailed(name, "detect", error)
      }
    }
  }

  // The wait is over (the feature is here, or the root is leaving): undo the
  // hook and return what it recorded. The shared record goes with it unless
  // `abandoning`: a root that leaves keeps its record until abandon() has run,
  // so anything else queued on the same import still finds it.
  #stopWaitingFor(name, abandoning) {
    if (__SPLIT__) {
      const [undo, pending] = this.#featureHooks.get(name) ?? []
      this.#featureHooks.delete(name)
      if (!abandoning) forgetWaiting(this.element, name, pending)
      try {
        undo?.()
      } catch (error) {
        console.error(`[phlex-reactive] the "${name}" feature module failed to stop waiting`, error)
      }
      return pending
    }
  }

  #connectFeature(epoch, name, feature, morphed) {
    if (__SPLIT__) {
      if (epoch !== this.#featureEpoch) return
      const pending = this.#stopWaitingFor(name)
      try {
        feature.connect?.(this, this.#featureCore(), morphed, pending)
        this.#features.set(name, feature)
      } catch (error) {
        this.#featureFailed(name, "connect", error)
      }
    }
  }

  // The `core` handle a feature receives (see "Feature modules" above).
  #featureCore() {
    this.#featureHandle ??= {
      emit: (name, detail, options) => this.#emit(name, detail, options),
      reseed: () => this.#reseed(),
      proceed: (target, action, params) => this.#proceed(target, action, params),
      forgetToken: () => {
        this.#tokenCache = undefined
      },
      owns: (el) => this.#ownsField(el),
      ownership: () => this.#ownershipFilter(),
      opTargets: (args) => this.#opTargets(args),
      diagnose: (label, args) => this.#diagnoseZeroTargets(label, args),
      // Apply an op list root-scoped, with the zero-target diagnostics; a
      // missing to: defaults to `defaultTo` (the reducer / completion-binding
      // convention is "@root").
      applyOps: (list, defaultTo) =>
        applyOps(
          list,
          (args) => this.#opTargets(defaultTo != null && args.to == null ? { ...args, to: defaultTo } : args),
          (name, args) => this.#diagnoseZeroTargets(`client op "${name}"`, args),
        ),
      listnavOptions: (event) => this.#listnavOptions(event),
      collectFields: () => this.#collectFields(),
      // The confirm gate, as dispatch() runs it: the resolver inside the chain
      // (a synchronous throw is a cancel), never a rejection out.
      confirm: (message, context) =>
        Promise.resolve()
          .then(() => confirmResolver(message, context))
          .catch(() => false),
    }
    return this.#featureHandle
  }

  // Re-run the connect-time seeds that read field values, in connect() order
  // — for a feature that changed those values after connect() ran (the draft
  // restore). Each is the same re-sync its feature runs after a morph; a root
  // that did not opt into one skips it. on-complete re-ARMS without firing.
  #reseed() {
    if (!__SPLIT__) {
      if (this.#featuresOn & FORM) formFeature.scan(this, this.#featureCore())
      if (this.#featuresOn & BINDINGS) bindingsFeature.reseed(this)
      if (this.#featuresOn & COMPUTE) computeFeature.seed(this)
    } else {
      this.#features.get("form")?.scan(this, this.#featureCore())
      this.#features.get("bindings")?.reseed(this)
      this.#features.get("compute")?.seed(this)
    }
  }

  // A feature that is missing leaves its part of the root dead: say so on
  // every root it costs (reactive:error, the error marker), and once in the
  // console. `phase` is "detect", "load", "timeout" or "connect".
  #featureFailed(name, phase, error) {
    logFeatureFailure(name, phase, error)
    this.#markError("feature")
    // A lazy shell whose module will never come (a failed import stays failed
    // until the page is reloaded) must not go on shimmering as if it loaded.
    if (phase === "load" && this.element.getAttribute?.("data-reactive-defer-pending")) {
      this.element.removeAttribute("data-reactive-defer-pending")
      this.element.removeAttribute("aria-busy")
    }
    this.#emit("reactive:error", { kind: "feature", feature: name, phase, error })
  }

  // Runs FIRST in disconnect(), in table order, while the root is still
  // intact (the draft flush reads its fields). A feature whose disconnect
  // throws must not keep the others, or the rest of disconnect(), from running.
  #disconnectFeatures() {
    if (__SPLIT__) {
      this.#featureEpoch++
      // End every wait still open: nothing will connect on this connection, and
      // a request queued behind featuresReady must not hang on a stuck import.
      for (const [timer, resolve] of this.#featureWaits) {
        clearTimeout(timer)
        resolve(null)
      }
      this.#featureWaits.clear()
      // A feature this root was still waiting for never connected here: hand it
      // what its hook recorded, once (and if) the module arrives.
      for (const name of [...this.#featureHooks.keys()]) {
        const pending = this.#stopWaitingFor(name, true)
        const root = this.element
        withFeature(name, (feature) => {
          feature.abandon?.(root, pending)
          forgetWaiting(root, name, pending)
        })
      }
      this.#featuresWanted.clear()
      this.#featureTurns.clear()
      this.#featuresSettling = false
      this.#featureGate = null
      const connected = [...this.#features]
      this.#features.clear()
      for (const [name, feature] of connected) {
        try {
          feature.disconnect?.(this, this.#featureCore())
        } catch (error) {
          console.error(`[phlex-reactive] the "${name}" feature module failed to disconnect`, error)
        }
      }
    }
  }

  // Early triggers (issue #273): mark the root (the attribute is for CSS and
  // tests; early.js trusts the WeakSet joined at the top of connect()),
  // announce it with a bubbling reactive:connect, then replay its queued triggers.
  #announceConnected() {
    // The attribute is a connect-time marker only: an in-place morph writes
    // the server's attributes back and strips it (re-marking would cost every
    // root a morph listener — the "a root that never opted in pays nothing"
    // contract). The connected WeakSet is the truth; reactive:connect the signal.
    this.element.setAttribute?.("data-reactive-connected", "")
    // Raw dispatch (as #emit), on the root only: connect() runs on an attached
    // element, so there is no detached-node fallback to make.
    if (this.element.isConnected) {
      this.element.dispatchEvent?.(
        new CustomEvent("reactive:connect", { bubbles: true, composed: true, detail: { id: this.element.id } }),
      )
    }
    this.#drainEarly()
  }

  // The trigger elements whose :once descriptor THIS connection replayed —
  // forgotten on disconnect (see disconnect()).
  #earlySpentOn = new Set()

  // Takes this root's entries — and those of any root that left the page
  // before connecting (replaced by a stream), which no controller would ever
  // claim.
  #drainEarly() {
    const { queue } = earlyState()
    if (queue.length === 0) return
    const mine = []
    for (let i = queue.length - 1; i >= 0; i--) {
      const { root } = queue[i]
      if (root === this.element || !root.isConnected) mine.unshift(...queue.splice(i, 1))
    }
    const ttl = earlyTtlMs()
    // Two module instances of early.js (a bundled copy beside the pinned one)
    // each queue the same event: replay an (event, element) pair once. (One
    // event OBJECT dispatched twice on one element before connect also counts
    // once — indistinguishable here.) An element bound to both `click` and
    // `click@window` is heard by both listeners live, so its window-bound
    // entry (issue #303) is a separate pair.
    const replayed = new Map()
    for (const entry of mine) {
      const pair = replayed.get(entry.event) ?? [new Set(), new Set()]
      replayed.set(entry.event, pair)
      const seen = pair[+!!entry.win]
      if (seen.has(entry.el)) continue
      seen.add(entry.el)
      const limit = entry.win ? Math.min(WINDOW_EARLY_TTL_MS, ttl) : ttl
      const reason =
        entry.root !== this.element
          ? "its root left the page before a controller connected"
          : performance.now() - entry.at > limit
            ? `it is older than the ${limit} ms ${entry.win ? "window-trigger" : "early-event"} TTL`
            : entry.el.isConnected && this.element.contains(entry.el)
              ? null
              : "its element left the root before the controller connected"
      if (reason) {
        if (this.#verboseEnabled()) console.warn(`[phlex-reactive] dropped an early "${entry.event.type}" trigger: ${reason}`)
        continue
      }
      this.#replayEarly(entry)
    }
  }

  // One queued event, replayed once per matching descriptor — Stimulus calls
  // each binding with the SAME event object, so runOps' duplicate-binding
  // guard behaves as it does live. Each descriptor is re-checked here, where
  // Stimulus would check it: it must still be on the element (a morph may
  // have removed it), its key filter must match under the app's own key
  // mappings (early.js knows only Stimulus's defaults), and a :once one runs a single time however often it
  // was queued (spendEarlyOnce).
  #replayEarly({ event, el, descs, win }) {
    const replay = earlyReplayEvent(event, el, win)
    const keyMappings = this.application?.schema?.keyMappings
    const tokens = (el.getAttribute("data-action") ?? "").split(/\s+/)
    // A window-bound entry belongs to this root, not to `el` (issue #303).
    const owner = win ? this.element : el
    for (const desc of descs) {
      if (!tokens.includes(desc.token)) continue
      if (desc.filter && !keyFilterMatches(desc.filter, event, keyMappings)) continue
      // (`:once` is read off the token: early.js keeps its records minimal.)
      if (/#\w+.*:once\b/.test(desc.token)) {
        if (!spendEarlyOnce(owner, desc, win && JSON.stringify(replay.params))) continue
        this.#earlySpentOn.add(owner)
      }
      // The original may still be propagating (issue #274): its live arrival at
      // `el` — or at the window, for a window-bound entry — must not run this
      // binding again (earlyOnceSwallows).
      markEarlyReplay(event, owner, win ? `@${desc.method}` : desc.method)
      if (desc.method === "runOps") this.runOps(replay)
      else this.dispatch(replay)
    }
  }

  // Tear down any pending debounce timers when the controller leaves the DOM
  // (Turbo morph/navigation removes the element). Otherwise a timer that hasn't
  // fired yet would later call #enqueue on a disconnected controller — a round
  // trip against a detached element / stale token (issue #17 follow-up).
  // Throttle suppression timers (issue #80) are torn down the same way — a
  // leading-edge timer holds no pending POST, but leaving it running would leak
  // it past the element's life.
  disconnect() {
    // Features FIRST (issue #275): the persist feature flushes a pending draft
    // write while the fields are still readable (Turbo disconnects before
    // leaving the page — a fast visit otherwise loses the last keystrokes).
    if (__SPLIT__) this.#disconnectFeatures()
    else this.#disconnectFeaturesNow()
    this.#clearAllDebounces()
    this.#clearAllThrottles()
    if (this.#boundRootMorph) {
      this.element.removeEventListener?.("turbo:morph-element", this.#boundRootMorph)
    }
    // Early triggers (issue #273): a disconnected root records again.
    earlyState().connected.delete(this.element)
    this.element.removeAttribute?.("data-reactive-connected")
    // A spent :once replay is remembered per element so a morph REPLY (root
    // still connected) cannot re-arm it. A disconnect drops Stimulus's own
    // `once` listeners and the next connect binds fresh ones, so the memory
    // goes too (issue #274: a dormant morph-back disconnects a root in place —
    // its :once trigger must work again after the re-wake).
    for (const el of this.#earlySpentOn) spentEarlyOnce.delete(el)
    this.#earlySpentOn.clear()
  }

  // Serialize requests per component. Each round trip rewrites the signed
  // token in the DOM (state lives in the token, not the client). If events
  // fire faster than round trips complete, concurrent requests would all read
  // the SAME stale token and clobber each other (last-write-wins). Chaining on
  // a per-controller promise makes each dispatch wait for the previous one, so
  // it always uses the freshest token.
  dispatch(event) {
    // A :once trigger already replayed on connect (issue #273) is spent.
    if (earlyOnceSwallows(event, "dispatch", this.application?.schema?.keyMappings, this.element)) return
    // `window` (renamed: never shadow the global) and `outside` are the event-
    // modifier params (issue #80). The client decides preventDefault behavior
    // from event.params — set by the Ruby on() — never by sniffing the
    // Stimulus descriptor.
    const { action, params, debounce, throttle, confirm, confirmWhen, outside, window: windowBound, optimistic } =
      event.params
    if (!action) return

    // The pending-state hint (issue #181): data-reactive-busy-param. During a
    // deploy overlap a page rendered by the PREVIOUS gem still emits the old
    // data-reactive-loading-param — read it as a fallback so an in-flight page
    // keeps its pending affordance until the next full render (the hints
    // feature remaps its `class:` key).
    const busy = event.params.busy ?? event.params.loading

    // Outside guard FIRST (issue #80): an outside: trigger only fires for
    // events whose target is OUTSIDE this component's ROOT (containment against
    // this.element — .contains includes the root itself). An event inside the
    // root must be a COMPLETE no-op — before preventDefault (the page's native
    // click behavior is untouched) and before the reactive:before-dispatch
    // lifecycle event (nothing to announce, nothing to veto).
    if (outside && this.element.contains(event.target)) return

    // The trigger is event.currentTarget — the element on(...) was spread onto —
    // NOT event.target (issue #99). A `<button><span>Save</span></button>` click
    // has target === the span, which carries no params and is the wrong element
    // to disable / swap text on. currentTarget is the bound element; fall back to
    // target for a directly-invoked/synthetic event. Captured now because
    // #proceed runs in a later microtask (after the confirm resolver), by which
    // point currentTarget is reset to null.
    const target = event.currentTarget ?? event.target

    // Stop native behavior (button submit / FORM NAVIGATION) HERE, synchronously
    // within the event dispatch — BEFORE the (possibly async) confirm gate below.
    // preventDefault() only works while the event is still being handled; once we
    // await the confirm resolver it's too late, and a `submit` trigger would
    // natively POST the form and navigate before the reactive round trip runs
    // (issue #11). For a `click` trigger there's no default to miss. This holds
    // for debounced triggers too — the round trip is deferred, but the native
    // default must still be prevented now. (Moved ahead of the confirm branch in
    // issue #55: an async resolver means we can't preventDefault after awaiting.)
    //
    // ONLY for element-bound triggers: a window-bound trigger (window:/outside:,
    // issue #80) hears EVERY matching event on the page — preventDefault-ing
    // those would kill every link click while a dropdown is mounted. The page's
    // native behavior proceeds alongside the reactive round trip.
    //
    // The `checked: :keep` optimistic hint (issue #98) OPTS OUT: for a click-bound
    // checkbox/radio the unconditional preventDefault is exactly what stops the
    // native flip from happening before the morph — so a bare checkbox click
    // (which has no form-navigation default to lose) skips it and flips now, and
    // the failure revert snaps it back. A `change`-bound trigger is unaffected —
    // `change` isn't cancelable, so preventDefault was already a no-op there.
    if (!windowBound && !this.#keepsNativeToggle(optimistic, target)) event.preventDefault()

    // A reactive_lazy(on:) shell's trigger (issue #276) goes through the one
    // materialize entry point, which dedupes it against the observer, the
    // re-armed listener and a morph-back. That entry point lives in the defer
    // feature (issue #275): the synchronous part of this dispatch is done, and
    // the load itself waits for the feature while it is still on its way.
    if (action === LAZY_MATERIALIZE_ACTION) {
      // Without the feature (it failed to load) a shell can still load the
      // plain way: the signed __materialize POST. A `cache:` shell carries no
      // token (issue #306) and has no such way: the feature's reactive:error
      // already said so, and nothing is sent.
      const materialize = () => {
        // (A shell whose defer connect threw has nothing wired: the plain POST.)
        if (!__SPLIT__) {
          if (this.#featuresOn & DEFER) return deferFeature.materialize(this)
        } else {
          const defer = this.#features.get("defer")
          if (defer) return defer.materialize(this)
        }
        if (this.tokenValue) return this.#proceed(target, action, "{}")
      }
      return this.#featuresSettling ? this.featuresReady.then(materialize) : materialize()
    }

    // Resolve the EFFECTIVE confirm message (issue #179): a plain string confirm:
    // is that string (static, #52); a Hash confirm: (confirmWhen) evaluates its
    // condition/predicate over the collected fields and returns the message ONLY
    // when it fires, else null → no dialog. No confirm at all → also null. The
    // conditional form is the bindings feature's: on the opt-in client its
    // answer may come a moment later (a promise), once the module is here.
    const message = this.#effectiveConfirmMessage(confirm, confirmWhen)
    const proceed = () => this.#proceed(target, action, params, debounce, throttle, optimistic, busy)

    // No message → proceed straight away (unchanged fast path).
    if (!message) return proceed()
    if (message instanceof Promise) {
      return message.then((resolved) => (resolved ? this.#confirmThen(resolved, target, proceed) : proceed()))
    }
    this.#confirmThen(message, target, proceed)
  }

  // The confirmation gate (issue #52, made overridable + async in #55). A
  // reactive trigger can't use Hotwire's data-turbo-confirm — this controller
  // preempts the event — so a `confirm:` message routes through
  // confirmResolver (default window.confirm; an app can override it to reuse
  // Turbo.config.forms.confirm). The resolver may be sync or async; call it
  // INSIDE the chain (via the leading .then) so even a SYNCHRONOUS override
  // throw rejects this promise instead of escaping dispatch — a throwing
  // dialog is treated as a cancel, like the user dismissing it. The .catch is
  // scoped to the resolver step (→ false = cancel), so a dismissed/erroring
  // dialog never surfaces as an unhandled rejection AND a genuine bug inside
  // #proceed is NOT silently swallowed. Enqueue ONLY on a truthy resolution —
  // nothing is enqueued, no timer scheduled, otherwise. The resolver's
  // optional 2nd arg (issue #222) carries the trigger element, so an override
  // has the same ctx shape here as on nestedRemove ({ el, … }).
  #confirmThen(message, target, proceed) {
    return Promise.resolve()
      .then(() => confirmResolver(message, { el: target }))
      .catch(() => false)
      .then((ok) => {
        if (ok) proceed()
      })
  }

  // The effective confirm message (issue #179): the static string; or, for a
  // conditional confirm, what the bindings feature says — now when the module
  // is here, else a promise of it (the opt-in client's import window); or
  // null when neither applies. A module that cannot load, or is slower than
  // the feature timeout, answers null: no dialog, the endpoint's
  // authorize/default-deny is the real gate.
  #effectiveConfirmMessage(confirm, confirmWhen) {
    if (confirm) return confirm
    if (!confirmWhen) return null
    if (!__SPLIT__) return bindingsFeature.confirmMessage(this, this.#featureCore(), confirmWhen)
    else {
      const loaded = featureModules.get("bindings")
      if (loaded) return loaded.confirmMessage(this, this.#featureCore(), confirmWhen)
      return this.#awaitFeatureOrNull("bindings").then(
        (bindings) => bindings && bindings.confirmMessage(this, this.#featureCore(), confirmWhen),
      )
    }
  }

  // A feature's module, or null once its import failed (logged) or outlasted
  // the feature timeout — for the two places a REQUEST waits on an import
  // without a root connection to wait with (a hint, a conditional confirm).
  #awaitFeatureOrNull(name) {
    if (__SPLIT__) {
      let timer
      return Promise.race([
        loadFeature(name).catch((error) => (logFeatureFailure(name, "load", error), null)),
        new Promise((resolve) => (timer = setTimeout(() => resolve(null), featureTimeoutMs()))),
      ]).finally(() => clearTimeout(timer))
    }
  }


  // CLIENT-ONLY trigger entry point (issue #95) — the zero-round-trip sibling
  // of dispatch(). Wired by on_client: applies the declared op chain
  // (data-reactive-ops-param, built by Phlex::Reactive::JS) locally. NO token,
  // NO params, NO fetch, ever. Ops are ephemeral UI: any server re-render of
  // the component resets whatever they toggled (by design — a signed action
  // owns state that must survive re-renders).
  runOps(event) {
    if (earlyOnceSwallows(event, "runOps", this.application?.schema?.keyMappings, this.element)) return
    if (bindingsAlreadyRan(event, this)) return
    const params = event.params ?? {}
    // The trigger element on_client was spread onto (issue #222 ctx: { el }),
    // captured now — currentTarget resets before the confirm resolver's microtask.
    const trigger = event.currentTarget ?? event.target
    // Issue #271: run only the binding record(s) whose descriptor fired. A
    // legacy [[op, args]] attr reads its flags from the element-wide params.
    const records = parseBindingRecords(params.ops)
    // Stimulus already applied the firing descriptor's key filter (custom
    // schema keys included), so a lone candidate on type + window-boundness
    // runs without a second key check; several same-type candidates are told
    // apart by their key filters, read through the app's Stimulus schema.
    const candidates = records.filter((record) => bindingMatches(record, event, null))
    const matching =
      candidates.length <= 1
        ? candidates
        : candidates.filter((record) => bindingMatches(record, event, this.application?.schema?.keyMappings))
    if (matching.length === 0 && records.length > 0) {
      // Issue #271: a hand-edited attr or a descriptor the matcher doesn't
      // know. Verbose gate only (the devtools feature dedupes).
      if (this.#verboseEnabled()) {
        if (__SPLIT__) this.#devtools((devtools) => devtools.noBinding(this, event))
        else devtoolsFeature.noBinding(this, event)
      }
      return
    }
    for (const record of matching) {
      // An early replay never runs an outside: record (issue #303: an outside
      // click before connect had nothing to close).
      if (record.outside && event[EARLY_KEY]) continue
      if (onceBindingSpent(this, event, record)) continue
      this.#runBinding(record.legacy ? { ...params, ops: record.ops } : record, event, trigger)
    }
  }

  // One on_client binding (issue #95): its outside guard, preventDefault rule,
  // confirm gate, then its ops — every flag read from the binding itself.
  #runBinding({ ops, confirm, confirmWhen, outside, window: windowBound }, event, trigger) {
    // Outside guard FIRST — identical semantics to dispatch() (issue #80): an
    // outside: trigger is a COMPLETE no-op for events inside this root, before
    // preventDefault and before any op runs.
    if (outside && this.element.contains(event.target)) return

    // Element-bound triggers preventDefault (a bare button inside a <form>
    // must not submit it); window-bound triggers (window:/outside:) never do —
    // they hear every matching event on the page, and preventDefault-ing those
    // would kill native clicks site-wide (issue #80 rationale). Runs BEFORE the
    // (possibly async) confirm gate below — a native default can't wait for a
    // pending dialog (same ordering as dispatch()).
    if (!windowBound) event.preventDefault()

    // Resolve the effective confirm message — static string, or the conditional
    // Hash form (issue #179) evaluated over collected fields (a promise of it
    // on the opt-in client while the bindings module is on its way). Null →
    // no dialog. The gate is here (the user gesture), NOT in #applyOps: that
    // applier is shared with the server-pushed reactive:js stream action,
    // which must NEVER prompt. The same confirmResolver gate on(:action,
    // confirm:) uses (issues #52/#55/#178), so a themed dialog covers both.
    const message = this.#effectiveConfirmMessage(confirm, confirmWhen)
    const apply = () => this.#applyOps(this.#parseOps(ops))
    if (!message) return apply()
    if (message instanceof Promise) {
      return message.then((resolved) => (resolved ? this.#confirmThen(resolved, trigger, apply) : apply()))
    }
    this.#confirmThen(message, trigger, apply)
  }

  // Client-side compute (issue #104) is the compute feature's (issue #275,
  // features/compute.js). This is the method its descriptor names
  // (input->reactive#recompute), so it stays. While the module is on its way
  // (the opt-in client) the entry records the edit, and the module runs one
  // recompute when it connects.
  recompute(event) {
    return __SPLIT__
      ? featureModules.get("compute")?.recompute(this, this.#featureCore(), event)
      : computeFeature.recompute(this, this.#featureCore(), event)
  }

  // Tag-chip input (issue #203) and draft nested rows (issue #208) are the
  // bindings feature's (issue #275, features/bindings.js). These are the
  // methods their descriptors name, so they stay: each hands the event to the
  // module — now, or, with the opt-in client, once it has arrived. The event
  // is dead by then, so what the module reads of it (the trigger, the target)
  // is captured here; the native default is prevented now, as the module
  // would have. tagsAdd keeps its two composition guards (an Enter that
  // listnav already took, or is about to take) in the same tick.
  tagsAdd(event) {
    if (event?.defaultPrevented) return
    if (this.#listnavOptions(event).some((el) => el.hasAttribute?.("data-reactive-highlighted"))) return
    return __SPLIT__
      ? this.#bindingsAction("tagsAdd", event)
      : bindingsFeature.tagsAdd(this, this.#featureCore(), event)
  }

  tagsPick(event) {
    return __SPLIT__
      ? this.#bindingsAction("tagsPick", event)
      : bindingsFeature.tagsPick(this, this.#featureCore(), event)
  }

  tagsRemove(event) {
    return __SPLIT__
      ? this.#bindingsAction("tagsRemove", event)
      : bindingsFeature.tagsRemove(this, this.#featureCore(), event)
  }

  nestedAdd(event) {
    return __SPLIT__
      ? this.#bindingsAction("nestedAdd", event)
      : bindingsFeature.nestedAdd(this, this.#featureCore(), event)
  }

  nestedRemove(event) {
    return __SPLIT__
      ? this.#bindingsAction("nestedRemove", event)
      : bindingsFeature.nestedRemove(this, this.#featureCore(), event)
  }

  syncNestedJson(event) {
    return __SPLIT__
      ? featureModules.get("bindings")?.syncNestedJson(this, this.#featureCore(), event)
      : bindingsFeature.syncNestedJson(this, this.#featureCore(), event)
  }

  #bindingsAction(name, event) {
    if (__SPLIT__) {
      const loaded = featureModules.get("bindings")
      if (loaded) return loaded[name](this, this.#featureCore(), event)
      event?.preventDefault?.()
      const snapshot = { currentTarget: event?.currentTarget ?? null, target: event?.target ?? null, preventDefault() {} }
      return withFeature("bindings", (bindings) => bindings[name](this, this.#featureCore(), snapshot))
    }
  }

  // Dirty tracking (issue #103) is the form feature's (issue #275,
  // features/form.js). This is the method its descriptor names
  // (input->reactive#trackDirty), so it stays: a full re-scan, by the module
  // when it is here. While it is still on its way nothing is lost — it scans
  // the whole root when it connects.
  trackDirty() {
    if (!__SPLIT__) formFeature.scan(this, this.#featureCore())
    else (this.#features.get("form") ?? featureModules.get("form"))?.scan(this, this.#featureCore())
  }

  // Client-side list navigation (combobox keyboard nav, issue #72). Wired by
  // on(:search, …, listnav: "[role=option]"), which appends keyboard filters to
  // the input's data-action (keydown.down/up/enter/esc->reactive#listnav*) and
  // sets data-reactive-listnav-option-param. Arrow keys move a highlight among
  // the options WITH NO ROUND TRIP; Enter picks the highlighted option by
  // CLICKING IT (so its own on(:select) reactive trigger fires — selection stays
  // a signed action); Escape clears. Ephemeral highlight state lives on the DOM
  // (data-reactive-highlighted), never shipped to the client as trusted state.
  //
  // Issue #271: a container spread with reactive_listnav(focus: true) carries
  // data-reactive-listnav-focus-param="true" — ROVING-FOCUS mode for a
  // role=menu: the same moves shift real focus among the items instead of a
  // highlight, and Home/End (listnavFirst/listnavLast) jump to the edges.
  listnavNext(event) {
    this.#listnavMove(event, (current, length) => (current < 0 ? 0 : (current + 1) % length))
  }

  listnavPrev(event) {
    this.#listnavMove(event, (current, length) => (current < 0 ? length - 1 : (current - 1 + length) % length))
  }

  listnavFirst(event) {
    this.#listnavMove(event, () => 0)
  }

  listnavLast(event) {
    this.#listnavMove(event, (_current, length) => length - 1)
  }

  // Enter: activate the highlighted option (fires its reactive select). No-op if
  // nothing is highlighted, and in that case DON'T preventDefault — Enter falls
  // through (there's no selection to make).
  listnavPick(event) {
    const options = this.#listnavOptions(event)
    const current = options.findIndex((el) => el.hasAttribute("data-reactive-highlighted"))
    if (current < 0) return
    event.preventDefault()
    options[current].click()
  }

  listnavClose(event) {
    for (const el of this.#listnavOptions(event)) el.removeAttribute("data-reactive-highlighted")
  }

  // Move among THIS root's options: `pick(current, length)` returns the next
  // index (current is -1 when nothing is highlighted/focused). preventDefault
  // stops Arrow keys moving the caret in a search input, and the page scrolling
  // under a menu. Highlight mode writes data-reactive-highlighted; focus mode
  // (issue #271) focuses the chosen item, current being the item that is or
  // contains document.activeElement.
  #listnavMove(event, pick) {
    const options = this.#listnavOptions(event)
    if (!options.length) return
    event.preventDefault()

    const focusMode = this.#listnavFocusMode(event)
    const active = globalThis.document?.activeElement
    const current = focusMode
      ? options.findIndex((el) => el === active || (active != null && el.contains?.(active)))
      : options.findIndex((el) => el.hasAttribute("data-reactive-highlighted"))
    const chosen = options[pick(current, options.length)]

    if (focusMode) {
      chosen.focus?.()
    } else {
      for (const el of options) el.removeAttribute("data-reactive-highlighted")
      chosen.setAttribute("data-reactive-highlighted", "true")
    }
    chosen.scrollIntoView?.({ block: "nearest" })
  }

  // Focus mode is read off the TRIGGER like the option selector (issue #271).
  #listnavFocusMode(event) {
    const trigger = event?.currentTarget ?? event?.target ?? this.element
    return trigger.getAttribute?.("data-reactive-listnav-focus-param") === "true"
  }

  // The option elements this root owns (skips nested reactive roots, issue #15),
  // per the selector on data-reactive-listnav-option-param. The attr rides on the
  // TRIGGER element (the search input on(...) is spread onto), read from the
  // event; the options are still scoped to this controller's root. Empty when
  // unset. Falls back to the root for a directly-invoked call (unit tests). The
  // ownership predicate is hoisted ONCE per keypress (issue #117) — in the common
  // no-nested-root case it is a constant true, skipping a closest() walk per
  // option. Hidden options are excluded (issue #163): a reactive_filter (or any
  // `hidden` toggle) removes a row from the keyboard path too, so an Arrow can't
  // highlight — and Enter can't pick — an invisible option.
  #listnavOptions(event) {
    const trigger = event?.currentTarget ?? event?.target ?? this.element
    const selector =
      trigger.getAttribute?.("data-reactive-listnav-option-param") ??
      this.element.getAttribute("data-reactive-listnav-option-param")
    if (!selector) return []
    const owns = this.#ownershipFilter()
    return Array.from(this.element.querySelectorAll(selector)).filter((el) => !el.hidden && owns(el))
  }

  // Enqueue the action — debounced if a debounce window is set, else immediately.
  // Split out of dispatch so both the no-confirm fast path and the post-confirm
  // microtask share one place (issue #55). `target` is captured up front because
  // this can run in a later microtask, after event.target has been reset.
  #proceed(target, action, params, debounce, throttle, optimistic, busy) {
    // Lifecycle veto point (issue #79): one cancelable reactive:before-dispatch
    // per user gesture — post-preventDefault, post-confirm, PRE-debounce (and
    // PRE-throttle, the same timing). event.preventDefault() skips the
    // debounce/throttle AND the enqueue entirely (nothing is scheduled).
    // retry() re-enters the queue directly, so this does NOT refire on a retry.
    // detail.params are the trigger's explicit params; sibling fields are
    // collected later, at send time.
    const before = this.#emit("reactive:before-dispatch", {
      action,
      params: this.#parseParams(params),
      element: this.element,
    }, { cancelable: true })
    if (before.defaultPrevented) return

    // Debounced trigger (e.g. on(:update, event: "input", debounce: 300)):
    // coalesce rapid events into ONE round trip after a quiet period, instead of
    // one POST per keystroke (issue #17). A blur flushes a pending dispatch.
    // The optimistic hint (issue #98) and the busy state (issue #181) ride to
    // the flush too, so they apply ONCE per enqueue — a debounced input must not
    // flap toggle_class per keystroke, and its element must NOT be disabled
    // during the quiet period (that would break typing). Both apply at ENQUEUE.
    const ms = Number(debounce) || 0
    if (ms > 0) return this.#debounceDispatch(target, ms, action, params, optimistic, busy)

    // Throttled trigger (e.g. on(:track, event: "scroll", window: true,
    // throttle: 250), issue #80): LEADING-EDGE rate limit — fire the first
    // event immediately, drop the rest until the window elapses. debounce and
    // throttle are mutually exclusive (the Ruby on() raises on both).
    const throttleMs = Number(throttle) || 0
    if (throttleMs > 0) return this.#throttleDispatch(target, throttleMs, action, params, optimistic, busy)

    return this.#enqueue(action, params, optimistic, target, busy)
  }

  // Apply the optimistic hint ONCE (recording its inverse) and chain the round
  // trip, threading that inverse onto THIS queued request so the serialized
  // per-controller queue reverts the RIGHT request's hint on failure (issue
  // #98). Applying here — the single flush/enqueue point every path funnels
  // through — is what makes a hint apply once per enqueue, not per raw dispatch.
  //
  // The busy state (issue #181) applies here too, for the same reason: enqueue
  // is the moment the request is committed to the queue, so the always-on busy
  // vocabulary (data-reactive-busy on the trigger + root, aria-busy via a pending
  // counter, busy_on scoping) and the busy hint (disable + class + text swap)
  // cover the WHOLE pending window — queue wait included — not just the fetch. It
  // returns a `settle` closure that #perform runs in its finally (success OR
  // failure), guarded so a morph-replaced trigger is never clobbered.
  #enqueue(action, params, optimistic, target, busy) {
    // The always-on busy state and the activity signal, now: they cover the
    // whole pending window, a wait for the hints module included. `pending`
    // is what this request's hint engine recorded — filled in by the apply
    // below, which may run a moment later than this call.
    const pending = { inverse: null, undo: [], resurrect: null }
    const settle = this.#applyBusy(action, target, pending)
    const wanted = Boolean(optimistic || busy)
    const apply = (hints) => {
      if (!wanted || !hints) return
      const core = this.#featureCore()
      pending.inverse = __SPLIT__
        ? hints.optimistic(this, core, optimistic, target)
        : hintsFeature.optimistic(this, core, optimistic, target)
      pending.undo.push(...(__SPLIT__ ? hints.busy(this, core, busy, target) : hintsFeature.busy(this, core, busy, target)))
      // Debug-only teaching aid (issue #181): if optimistic: { hide: true } is
      // used for instant-delete but the reply RE-RENDERS the element (bringing
      // it back), that hint was pointless — the developer likely wanted
      // reply.remove. Capture the hidden nodes now; the success path re-checks
      // the OBSERVED DOM after the morph (never inferred from the verb).
      if (this.#debugEnabled()) {
        pending.resurrect = __SPLIT__
          ? hints.resurrection(this, core, optimistic, target)
          : hintsFeature.resurrection(this, core, optimistic, target)
      }
    }
    // A hint applies ONCE per enqueue — the single flush point every path
    // funnels through — never per raw dispatch. With the module here (the
    // default client, always) that is now, synchronously.
    const loaded = __SPLIT__ ? featureModules.get("hints") : true
    if (!wanted || loaded) apply(loaded)
    // A feature still loading may be about to change what this request reads
    // (issue #275: the draft restore writes the fields #perform collects). Only
    // such a feature — one that `gates` — holds a request back, until it has
    // connected: at most the feature timeout, and on a root that never waited
    // for one, not at all. A feature that does not gate (the defer module)
    // never delays a request, however slow its import. A request WITH a hint
    // on a page that has not loaded the hints module waits for that import
    // the same way (at most the feature timeout), then applies the hint and
    // goes out — once.
    const perform = () => this.#perform(action, params, pending, settle)
    const ready = () => (this.#featureGate ? this.#featureGate.then(perform) : perform())
    this.queue = (this.queue ?? Promise.resolve()).then(() =>
      wanted && !loaded ? this.#awaitHints().then(apply).then(ready) : ready(),
    )
    return this.queue
  }

  // The hints module, or null once its import failed or outlasted the feature
  // timeout (the request then goes out without its hint).
  #awaitHints() {
    return this.#awaitFeatureOrNull("hints")
  }

  // Reset a per-element timer; only enqueue the round trip after `ms` of quiet.
  // Also flush immediately on blur so leaving the field never drops the last
  // edit (a long debounce shouldn't swallow a value the user tabbed away from).
  #debounceDispatch(target, ms, action, params, optimistic, busy) {
    this.#clearDebounce(target)

    const flush = () => {
      this.#clearDebounce(target)
      this.#enqueue(action, params, optimistic, target, busy)
    }
    const timer = setTimeout(flush, ms)
    target?.addEventListener?.("blur", flush, { once: true })
    this.#debounceTimers.set(target, { timer, flush })
  }

  #clearDebounce(target) {
    const pending = this.#debounceTimers.get(target)
    if (!pending) return
    clearTimeout(pending.timer)
    target?.removeEventListener?.("blur", pending.flush)
    this.#debounceTimers.delete(target)
  }

  // Clear every pending debounce timer (used on disconnect). Reuses
  // #clearDebounce so all timer/listener teardown stays in one place. Snapshot
  // the keys first — #clearDebounce mutates the map as it goes.
  #clearAllDebounces() {
    for (const target of [...this.#debounceTimers.keys()]) this.#clearDebounce(target)
  }

  // Leading-edge throttle (issue #80), mirroring #debounceDispatch: the FIRST
  // event fires immediately; a suppression timer then drops further events
  // until the window elapses (no trailing fire — dropped, not queued). Timers
  // are keyed on action + target, NOT target alone: window-bound scroll/resize
  // events all share event.target === document, so two window-bound triggers
  // on one component would otherwise collide on one timer.
  #throttleDispatch(target, ms, action, params, optimistic, busy) {
    const timers = this.#throttleTimers.get(target) ?? new Map()
    if (timers.has(action)) return // inside the window — suppress

    const timer = setTimeout(() => {
      timers.delete(action)
      if (timers.size === 0) this.#throttleTimers.delete(target)
    }, ms)
    timers.set(action, timer)
    this.#throttleTimers.set(target, timers)
    return this.#enqueue(action, params, optimistic, target, busy) // leading edge: fire NOW
  }

  // Clear every throttle suppression timer (used on disconnect, alongside
  // #clearAllDebounces) so nothing outlives the element.
  #clearAllThrottles() {
    for (const timers of this.#throttleTimers.values()) {
      for (const timer of timers.values()) clearTimeout(timer)
    }
    this.#throttleTimers.clear()
  }

  // Raw-dispatch a lifecycle CustomEvent (issue #79). Deliberately NOT
  // Stimulus's this.dispatch() helper — that name is SHADOWED by this
  // controller's own dispatch(event) action method. Bubbling + composed so a
  // page-level listener (or `data-action="reactive:error->toast#show"` on an
  // ancestor) hears it. After a plain (non-morph) replace this.element is a
  // DETACHED node — a bubbling event on it never reaches document listeners —
  // so fall back to dispatching on document itself.
  #emit(name, detail, { cancelable = false } = {}) {
    const event = new CustomEvent(name, { bubbles: true, composed: true, cancelable, detail })
    const root = this.element.isConnected ? this.element : document
    root.dispatchEvent(event)
    return event
  }

  // reactive:error detail: { action, params, kind, status?, body?, retry }.
  // `params` are the FULL params that were sent (collected fields + explicit
  // trigger params). retry() re-enters the request queue with the ORIGINAL raw
  // trigger params, so #perform re-reads the freshest token and RE-COLLECTS the
  // sibling fields — nothing stale is replayed. It does not refire
  // reactive:before-dispatch (one veto per user gesture), and it no-ops with a
  // warning once the root has left the DOM (retrying against a detached
  // element would post a stale token into nowhere).
  #emitError(action, rawParams, sentParams, extra) {
    const retry = () => {
      if (!this.element.isConnected) {
        console.warn("[phlex-reactive] retry() ignored — the reactive root left the DOM")
        return
      }
      return this.#enqueue(action, rawParams)
    }
    this.#emit("reactive:error", { action, params: sentParams, ...extra, retry })
  }

  // Mark the reactive root as errored (issue #100) with the failure kind, so an
  // app can style it purely in CSS ([data-reactive-error] { … }) with zero JS.
  // Guarded — a plain replace may have detached the root before the failure lands.
  #markError(kind) {
    if (this.element?.isConnected === false) return
    this.element?.setAttribute?.("data-reactive-error", kind)
  }

  // Clear the failure marker on the next successful apply (issue #100).
  #clearError() {
    this.element?.removeAttribute?.("data-reactive-error")
  }

  // Offline fallback (issue #100): a network failure reached no server, so there
  // is no body to render. Clone the content of a server-rendered
  // <template data-reactive-error-flash> into the flash region so the user still
  // sees SOMETHING. The template is app-authored (trusted) — this is a pure
  // deep clone, never client templating of untrusted data. No template, or no
  // flash container, is a silent no-op (a page without the opt-in is unchanged).
  #renderNetworkFallback() {
    const template = document.querySelector("[data-reactive-error-flash]")
    if (!template?.content) return
    // The flash region is the host-app container Response#flash targets. Its id
    // defaults to "flash" (Phlex::Reactive.flash_target); an app that customized
    // it can point the fallback at the same node by putting the template's
    // data-reactive-error-flash value there — but the common case is #flash.
    const targetId = template.getAttribute("data-reactive-error-flash") || "flash"
    const region = document.getElementById(targetId)
    if (!region) return
    region.appendChild(template.content.cloneNode(true))
  }

  // Latency simulator (issue #102): the delay itself is the dev feature's.
  // A request waits for the module only while a delay is stored (so the very
  // first delayed request is delayed too); with none stored this is two reads.
  #maybeSimulateLatency() {
    if (!__SPLIT__) return devtoolsFeature.delay()
    else {
      const devtools = featureModules.get("devtools")
      if (devtools) return devtools.delay()
      if (latencyStored()) return loadFeature("devtools").then((loaded) => loaded.delay(), () => {})
    }
  }

  // Client debug mode (issue #108) — the "devtools-lite" lens. On when the Ruby
  // reactive_attrs stamped data-reactive-debug="true" (Phlex::Reactive.debug).
  // Read live (a single getAttribute) so the whole feature is inert for any app
  // that never opts in: OFF → this returns false and #perform builds no debug
  // object, parses no response, and logs nothing (the "zero cost when off"
  // invariant — one nil-check per dispatch). Guarded for a stub root with no
  // getAttribute (unit harnesses) so it degrades to off, never throwing.
  #debugEnabled() {
    return this.element?.getAttribute?.("data-reactive-debug") === "true"
  }

  // A monotonic timestamp for the round-trip duration (ms). performance.now is
  // monotonic (immune to a wall-clock adjustment mid-request); Date.now is the
  // fallback for an exotic environment without it. ONLY called on the debug path,
  // so it costs nothing when debug is off.
  #debugNow() {
    return typeof performance !== "undefined" && typeof performance.now === "function"
      ? performance.now()
      : Date.now()
  }

  async #perform(action, params, pending, settle) {
    // Auto-collect named field values inside this component so a button-
    // triggered action still receives sibling inputs (Livewire-style), plus any
    // chosen file inputs in the SAME walk. Explicit params
    // (data-reactive-params-param) win over collected fields.
    const { fields, files } = this.#collectFields()
    // Parse the explicit trigger params ONCE — reused below for allParams and, on
    // the debug path, for the params-only name list (so the trace can show
    // `params: [...]` distinct from the collected `+ collected: [...]`). #parseParams
    // is pure (a fresh object from a JSON string, or the same object by reference
    // when already parsed); allParams spreads a COPY and nothing mutates parsedParams
    // downstream (JSON.stringify / #buildFormData read allParams, a new object).
    const parsedParams = this.#parseParams(params)
    const allParams = { ...fields, ...parsedParams }
    const token = this.#currentToken

    // File/multipart path (issue #34): if THIS root has a populated
    // <input type="file">, the action can't be JSON (JSON.stringify drops the
    // File). Send FormData instead — token + act + scalar params as fields, each
    // chosen file appended. The morph/token machinery downstream is identical;
    // only the request ENCODING differs when files are present.
    const multipart = files.length > 0
    const body = multipart
      ? this.#buildFormData(token, action, allParams, files)
      : JSON.stringify({ token, act: action, params: allParams })

    // Client debug mode (issue #108): build the trace object ONLY when debug is on
    // (one nil-check otherwise — zero cost off). It carries NAMES only: the
    // explicit trigger param names and the collected sibling field names, split so
    // the group shows `params: [...] + collected: [...]`. status/streams/
    // tokenRefreshed are filled in at the branch that knows them; the group is
    // emitted once in the finally so EVERY exit (success or any failure) logs.
    const debug = this.#debugEnabled()
      ? {
          action,
          paramNames: Object.keys(parsedParams),
          fieldNames: Object.keys(fields),
          encoding: multipart ? "multipart" : "json",
          status: null,
          streams: [],
          tokenRefreshed: false,
          started: this.#debugNow(),
        }
      : null

    // aria-busy on the root is now driven by the loading pending counter
    // (#applyLoading, applied at ENQUEUE so it covers the queue wait too), not
    // set here. #settleLoading in the finally clears it — see #enqueue.

    // Latency simulator (issue #102): the busy window (aria-busy + loading state)
    // is already applied at enqueue, so awaiting the configured delay HERE — after
    // that window opened and before the fetch — is what makes it visible on
    // localhost. A null/absent/non-positive sessionStorage key is a no-op (zero
    // production surface), so this line vanishes for any app that never opts in.
    await this.#maybeSimulateLatency()

    try {
      // Offline gate (issue #101), authoritative at the NETWORK BOUNDARY (send
      // time), not at enqueue. A click can enqueue while online and reach here
      // after going offline (a debounced/queued request, a rapid transition) —
      // gating in #perform makes the kind consistently "offline" for that whole
      // condition instead of leaking through as a "network" fetch throw. The
      // fetch never fires, so the edit is not half-sent; the finally still runs
      // (settle clears loading), the optimistic hint reverts, and retry() (which
      // re-enters #perform) re-checks and sends once back online.
      if (navigator.onLine === false) {
        this.#revertOptimistic(pending.inverse)
        this.#markError("offline")
        this.#emitError(action, params, allParams, { kind: "offline" })
        return
      }

      let response
      try {
        const headers = {
          Accept: "text/vnd.turbo-stream.html",
          "X-CSRF-Token": this.#csrfToken(),
        }
        // For JSON we declare the content type; for multipart we must NOT — the
        // browser sets `multipart/form-data; boundary=…` itself, and overriding it
        // would strip the boundary and corrupt the body server-side.
        if (!multipart) headers["Content-Type"] = "application/json"
        // Send the pgbus SSE connection id (if subscribed) so the server can
        // exclude this connection from its own broadcast echo — the actor
        // already gets the action's HTTP response. Harmless without pgbus.
        const connectionId = this.#connectionId()
        if (connectionId) headers["X-Pgbus-Connection"] = connectionId

        // ONLY `fetch` itself is the network boundary — offline, DNS, a reset
        // connection. Everything below this inner try (reading the body,
        // extracting the token, handing streams to Turbo) runs AFTER the
        // server already processed the mutation, so none of it belongs in the
        // `kind: "network"` / retriable bucket (CodeRabbit review on #89): if
        // renderStreamMessage throws, retry()ing would re-POST an action the
        // server already completed — see the outer catch below. (NOT a
        // reactive:applied LISTENER throwing — per the DOM spec, dispatchEvent
        // never propagates a listener's exception back to its caller, so that
        // case can't reach this catch at all; verified in the JS test suite.)
        countReactiveRequest("action")
        response = await fetch(this.#actionPath(), {
          method: "POST",
          headers,
          body,
          credentials: "same-origin",
          // Bound the request (issue #101): a server that never answers used to
          // wedge this.queue forever (the finally that clears aria-busy/loading
          // never ran). AbortSignal.timeout(ms) aborts the fetch after the
          // configured window; the abort surfaces in this catch as a
          // DOMException named "TimeoutError" (see the branch below).
          signal: AbortSignal.timeout(this.#timeoutMs()),
        })
      } catch (error) {
        console.error("[phlex-reactive] action error", error)
        this.#revertOptimistic(pending.inverse)
        // AbortSignal.timeout() rejects with a DOMException named "TimeoutError"
        // (a manual AbortController.abort() would be "AbortError" — we don't use
        // one, but accept it too for robustness). A timeout is NOT "offline":
        // the request left and the server didn't answer in time; connectivity is
        // unknown. So do NOT clone the offline-fallback template or mark network
        // — just fire kind:"timeout" (retriable). The queue still advances
        // (#perform returns, never rejects), so the hung request un-wedges it.
        if (error?.name === "TimeoutError" || error?.name === "AbortError") {
          this.#markError("timeout")
          this.#emitError(action, params, allParams, { kind: "timeout" })
          return
        }
        // No server reached — nothing to render (issue #100). Clone a
        // server-rendered <template data-reactive-error-flash> into the flash
        // region as an offline fallback. The template is rendered by the app
        // (trusted), so this is a pure clone — no client templating of data.
        this.#renderNetworkFallback()
        this.#markError("network")
        this.#emitError(action, params, allParams, { kind: "network" })
        return
      }

      // Debug (issue #108): the server answered — record the status for the trace
      // now, so every response branch below (redirected/http/content-type/ok) logs
      // it. The transport-failure branches above return before here (they have no
      // status); their group still fires from the finally with status null → "—".
      if (debug) debug.status = response.status

      if (response.redirected) {
        console.error("[phlex-reactive] action was redirected (auth/CSRF?) — no update applied")
        this.#revertOptimistic(pending.inverse)
        this.#markError("redirected")
        this.#emitError(action, params, allParams, { kind: "redirected", status: response.status })
        return
      }
      if (!response.ok) {
        const errorBody = await response.text()
        console.error(`[phlex-reactive] action failed: HTTP ${response.status}`, errorBody)
        this.#revertOptimistic(pending.inverse)
        // Render a non-OK turbo-stream body so a server-rendered error flash
        // (an error_flash rescue, or a status: :unprocessable_entity validation
        // reply from a plain controller) is actually SHOWN — instead of being
        // read only for the console (issue #100). #extractToken is run as usual;
        // it NO-OPS when no stream re-renders our id, so a 400 InvalidToken body
        // never refreshes the held identity token (which is not a nonce and stays
        // retry-valid — do not "fix" that). A non-turbo-stream body is left to the
        // console.error above (an HTML error page must not be handed to Turbo).
        if ((response.headers.get("Content-Type") || "").includes("turbo-stream")) {
          const fresh = this.#extractToken(errorBody)
          this.#currentToken = fresh ?? this.#currentToken
          if (debug) {
            if (__SPLIT__) this.#devtools((devtools) => devtools.recordBody(debug, errorBody, fresh))
            else devtoolsFeature.recordBody(debug, errorBody, fresh)
          }
          window.Turbo.renderStreamMessage(errorBody)
        }
        this.#markError("http")
        this.#emitError(action, params, allParams, { kind: "http", status: response.status, body: errorBody })
        return
      }

      const contentType = response.headers.get("Content-Type") || ""
      if (!contentType.includes("turbo-stream")) {
        console.error(`[phlex-reactive] expected a turbo-stream, got "${contentType}" — no update applied`)
        this.#revertOptimistic(pending.inverse)
        this.#markError("content-type")
        this.#emitError(action, params, allParams, { kind: "content-type", status: response.status })
        return
      }

      const html = await response.text()
      // Capture the new token from the response synchronously, so the next
      // queued request uses it without waiting for the async DOM morph.
      const fresh = this.#extractToken(html)
      this.#currentToken = fresh ?? this.#currentToken
      // Debug (issue #108): record the stream actions/targets + whether a refresh
      // arrived, from the body we JUST read (reuse — no second text() read). Never
      // the token or template contents.
      if (debug) {
        if (__SPLIT__) this.#devtools((devtools) => devtools.recordBody(debug, html, fresh))
        else devtoolsFeature.recordBody(debug, html, fresh)
      }
      // Turbo applies the <turbo-stream> ops by id. A plain replace is an
      // outerHTML swap (focus on the replaced subtree is lost); a method="morph"
      // replace (Response.morph) or an update morphs in place, preserving the
      // focused input + caret on unchanged nodes — see issue #28.
      window.Turbo.renderStreamMessage(html)
      // Debug-only (issue #181): the morph may apply a microtask later, so check
      // the resurrected-hide case AFTER it lands. Off the debug path, resurrect is
      // null — zero cost.
      if (pending.resurrect) queueMicrotask(pending.resurrect)
      // A successful apply CLEARS any prior failure marker (issue #100), so
      // error-driven CSS on the root (a red border, a shake) resets on recovery.
      this.#clearError()
      // Lifecycle hook (issue #79): the streams were HANDED TO Turbo — a
      // renderStreamMessage applies asynchronously, so the DOM mutation may
      // complete a tick later. Apps needing post-morph timing listen to Turbo's
      // own events; this one is for "the action round trip succeeded".
      this.#emit("reactive:applied", { action, params: allParams, html })
    } catch (error) {
      // The server already processed this action successfully (we're past the
      // fetch) — a throw here is a CLIENT-side apply failure (a malformed
      // response, a broken Turbo render — NOT a reactive:applied listener
      // throw, which dispatchEvent never propagates here), not a transport
      // failure. kind: "apply" carries NO retry() — retrying would re-POST an
      // action the server already completed.
      console.error("[phlex-reactive] action error", error)
      this.#revertOptimistic(pending.inverse)
      this.#emit("reactive:error", { action, params: allParams, kind: "apply" })
    } finally {
      // Settle the loading state (issue #99): decrement the pending counter,
      // drop the trigger's/root's busy tokens, restore disabled/text/class —
      // guarded so a morph-replaced trigger is never clobbered. Runs on EVERY
      // exit (success, every failure branch, or an apply throw).
      settle?.()
      // Debug (issue #108): emit the group here so EVERY exit path logs exactly
      // once — success, any transport/response failure, or an apply throw. Null
      // when debug is off (zero cost). The round-trip ms is measured now, at the
      // finally, so it spans the whole #perform (fetch + apply) regardless of exit.
      if (debug) {
        if (__SPLIT__) this.#devtools((devtools) => devtools.trace(this, { ...debug, ms: this.#debugNow() - debug.started }))
        else devtoolsFeature.trace(this, { ...debug, ms: this.#debugNow() - debug.started })
      }
    }
  }

  get #currentToken() {
    return this.#tokenCache ?? this.tokenValue
  }

  set #currentToken(value) {
    this.#tokenCache = value
  }

  // A token written into the DOM wins over the cached one (issue #301): an
  // outside morph (a broadcast, a page refresh, a dormant morph-back) rewrites
  // the attribute while this controller survives, and Stimulus calls this on
  // that change and on a reconnect after it. Our own reply's morph writes the
  // token #extractToken already cached, so dropping the cache changes nothing —
  // unless a later reply was already extracted: then the attribute holds the
  // older token until that reply's morph lands, the same frame (Turbo renders
  // streams after nextRepaint), before any queued dispatch reads it.
  tokenValueChanged() {
    this.#tokenCache = undefined
  }

  // Read the next token for THIS controller — the one that re-renders THIS
  // element's id, never just the first token in the body (issue #46). On a
  // collection of REACTIVE rows the prepended/appended ROW carries its OWN
  // data-reactive-token-value and it sorts FIRST in the response; the list's own
  // fresh token rides a trailing `reactive:token` stream targeting the container.
  // Grabbing the first match stored the ROW's token, so the list's SECOND
  // dispatch sent a row token → failed verification → add-once-only. This mirrors
  // the server's carries_token_for? (#44): a stream carries OUR token only when it
  // RE-RENDERS our id (reactive:token / replace / update of `this.element.id`) —
  // append/prepend insert children and never count. Returns undefined when no
  // stream re-renders our id, so #currentToken keeps its existing value.
  #extractToken(html) {
    const id = this.element.id
    if (!id) {
      // No id to self-match (shouldn't happen for a reactive root). Fall back to
      // the legacy first-token behavior so a single-component response still works.
      return html.match(/data-reactive-token-value="([^"]+)"/)?.[1]
    }

    const { token, self } = this.#tokenRegexes(id)

    // The dedicated token-only refresh for THIS element (partial updates / the
    // collection container) — an attribute on the <turbo-stream> itself.
    const tokenStream = html.match(token)
    if (tokenStream) return tokenStream[1]

    // A full self re-render: a replace/update of THIS element whose template root
    // carries the fresh token. Scope the token search to that one stream so a
    // sibling/child token elsewhere in the body can't leak in.
    const selfStream = html.match(self)
    if (selfStream) return selfStream[1].match(/data-reactive-token-value="([^"]+)"/)?.[1]

    // Nothing re-rendered our id — keep the current token.
    return undefined
  }

  // The two per-id RegExps #extractToken uses to self-match this element's next
  // token (issue #118). `this.element.id` is page-stable, so these are compiled
  // ONCE and reused across every response — instead of allocating two fresh
  // RegExps per round trip. The memo is KEYED ON THE ID and rebuilt when it
  // changes: a re-render that re-identifies the root must scan for the NEW target,
  // never the stale one (or the token would freeze — see the id-change bun test).
  // The PATTERNS are byte-identical to the pre-memo inline literals; only their
  // allocation moved.
  #tokenRegexes(id) {
    const cache = this.#tokenRegexCache
    if (cache && cache.id === id) return cache
    const escaped = escapeRegExp(id)
    return (this.#tokenRegexCache = {
      id,
      token: new RegExp(
        `<turbo-stream\\b[^>]*\\baction="reactive:token"[^>]*\\btarget="${escaped}"[^>]*\\bdata-reactive-token-value="([^"]+)"`,
      ),
      self: new RegExp(
        `<turbo-stream\\b[^>]*\\baction="(?:replace|update)"[^>]*\\btarget="${escaped}"[^>]*>([\\s\\S]*?)</turbo-stream>`,
      ),
    })
  }

  // True when `el` is collected by THIS reactive root and not by a nested one.
  // A reactive component can be rendered inside another (both are
  // data-controller="reactive" roots). querySelectorAll() descends into nested
  // roots, so without this guard an outer action would sweep the inner roots'
  // inputs into its own params (issue #15). An element belongs to this root iff
  // its nearest [data-controller~="reactive"] ancestor is this.element.
  #ownsField(el) {
    return el.closest('[data-controller~="reactive"]') === this.element
  }

  // A per-op ownership PREDICATE — the issue #117 fast path over issue #15
  // scoping. #ownsField answers "is this element mine, not a nested reactive
  // root's" with a per-element closest() walk; on a wide form or every keystroke
  // that walk runs per matched field. This hoists the DECISION to once per op.
  //
  // HYBRID GATE — closest() stays the source of truth; the nested-root query only
  // decides whether the fast path is SAFE:
  //   * Fast path (overwhelmingly common): this root contains NO nested reactive
  //     roots, so every element the caller's querySelectorAll returned is already
  //     a direct descendant of this.element with no intervening reactive root —
  //     it is ours. Return a constant-true predicate and skip the per-field
  //     closest() walk entirely. That is the whole win.
  //   * Nested case: fall back to the UNCHANGED #ownsField closest() check, so
  //     scoping is byte-identical to before. We deliberately do NOT use
  //     contains() here — the closest() form needs no node to implement
  //     contains(), and on a real DOM the two agree for a descendant of
  //     this.element (el.closest('[data-controller~="reactive"]') === this.element
  //     iff no nested reactive-root descendant contains el).
  //
  // Computed ONCE per dispatch-scoped op (per #collectFields call, per recompute,
  // per #listnavOptions) and NEVER stored on the instance — a morph replaces
  // nodes, so a cached predicate would close over stale roots.
  #ownershipFilter() {
    const nested = this.element.querySelectorAll('[data-controller~="reactive"]')
    if (nested.length === 0) return () => true
    return (el) => this.#ownsField(el)
  }

  // One walk over THIS root's named controls (not a nested reactive root's),
  // returning both the scalar `fields` and any chosen `files`. The ownership
  // predicate is hoisted ONCE (issue #117) via #ownershipFilter — in the common
  // no-nested-root case it is a constant true, so we skip a closest() walk per
  // field. A file input's `.value` is the useless "C:\fakepath\…" string, never a
  // scalar — so its chosen files are collected separately (honoring `multiple`)
  // and it adds no phantom blank value (issue #34). An empty `files` keeps the
  // JSON path.
  #collectFields() {
    const fields = {}
    const files = []
    const owns = this.#ownershipFilter() // compute ONCE per dispatch (issue #117)
    const controls = []
    this.element.querySelectorAll("input[name], select[name], textarea[name]").forEach((field) => {
      if (!owns(field)) return
      if (field.type === "file") {
        // Carry the input's `multiple` flag so #buildFormData keeps the array
        // shape (params[name][]) even when the user picked exactly one file —
        // otherwise a [:file] schema would see a lone scalar upload and drop it.
        for (const file of field.files ?? []) files.push({ name: field.name, file, multiple: field.multiple })
      } else {
        // Held for a second pass: a hidden input is only a companion if a
        // checkbox somewhere in the root shares its name, which the first
        // occurrence cannot know yet.
        controls.push(field)
      }
    })
    // Collected before the first pass so the editor DOM is walked once.
    const editors = []
    this.element.querySelectorAll(`[name]${EDITOR_SELECTOR}`).forEach((el) => {
      if (owns(el)) editors.push(el) // the SAME hoisted predicate (nested reactive root, issue #15)
    })
    const arrayNames = this.#arrayFieldNames(controls)
    const companionNames = this.#companionNames(controls)
    for (const field of controls) {
      if (arrayNames.has(field.name)) {
        const slot = fields[field.name] ?? (fields[field.name] = [])
        if (field.type === "checkbox" || field.type === "radio") {
          // An unchecked box contributes NOTHING, the way a native submission
          // leaves it out. The group's value is the list of checked values, and
          // with none checked that list stays an EMPTY ARRAY rather than
          // vanishing: the action can tell "the operator cleared them" from
          // "the group never rendered", and an [:string] schema coerces [] to
          // []. A form body cannot carry the empty array, so #buildFormData
          // announces the group there instead.
          if (field.checked) slot.push(field.value)
        } else if (field.type === "hidden") {
          if (!companionNames.has(field.name)) slot.push(field.value)
        } else if (field.multiple && field.options) {
          for (const option of field.options) if (option.selected) slot.push(option.value)
        } else {
          slot.push(field.value)
        }
      } else if (field.type === "checkbox") {
        fields[field.name] = field.checked
      } else if (field.type === "radio") {
        if (field.checked) fields[field.name] = field.value
      } else {
        fields[field.name] = field.value
      }
    }
    // Named rich-text / custom editors (lexxy-editor, trix-editor) and bare
    // [contenteditable]. These aren't input/select/textarea, so the query above
    // skips them — without this, a reactive save posts an empty value and
    // silently wipes the field (issue #8). Read whatever the element exposes:
    // a custom editor's serialized `.value`, else its contenteditable text.
    // Under a plain name: only fill what the standard controls left absent or
    // empty, so a synced hidden input (e.g. Trix mirrors into one) still wins
    // when populated. Under a `[]` name the editor APPENDS to the group slot
    // instead, and a same-named hidden keeps its own say: nothing here can
    // tell a hidden that mirrors this editor from one that is a list JS
    // maintains.
    editors
      .forEach((el) => {
        // A plain element (e.g. a <div contenteditable>) has no `name` IDL
        // property — only the attribute — so read getAttribute, not el.name.
        const name = el.getAttribute("name")
        if (!name) return
        const own = el.value ?? el.textContent ?? el.innerHTML ?? ""
        // A `[]` name is a group here too: the editor APPENDS its value
        // instead of replacing the slot. Assigning a scalar posted
        // `{"notes[]": "<p>x</p>"}` while the draft snapshot pushed the same
        // control into an array — the wire and the draft disagreeing about one
        // field, and a declared array type seeing a string. A same-named hidden
        // is NOT read as this editor's twin: nothing here can tell a mirror
        // from a list JS maintains, and a value posted twice is visible while a
        // suppressed one is not.
        const existing = fields[name]
        // An editor that has not upgraded yet contributes NOTHING to a group.
        // Trix defines its elements in a setTimeout after load, and its "" is
        // not an empty value but an absent one: persistSnapshot omits such an
        // editor for the same reason, so this keeps the wire and the draft
        // saying the same thing.
        if (String(name).endsWith("[]") && !collectorEditorReady(el)) return
        if (String(name).endsWith("[]") && (existing === undefined || Array.isArray(existing))) {
          const slot = Array.isArray(existing) ? existing : (fields[name] = [])
          slot.push(own)
          return
        }
        // A scalar already under a `[]` name can only be a RADIO's: a radio
        // means "pick one" and keeps its single value with or without the
        // suffix, which is why #arrayFieldNames excepts it. Converting that to
        // a group here would discard the chosen value — measured, the post lost
        // it — so the editor stands down and the rule below applies, which
        // never overwrites a populated name.
        // Only fill what the standard controls left absent or empty, so a
        // synced hidden input still wins when populated.
        if (existing == null || existing === "") {
          fields[name] = own
        }
      })
    return { fields, files }
  }

  // Names collected as an ARRAY rather than a single value: a name carrying the
  // `[]` suffix, the HTML convention for a group. That suffix is the ONLY
  // trigger — a group says so, it is not inferred from two controls happening
  // to share a name. Radios are excluded BY DESIGN: a radio group shares one
  // name to mean "pick one", and it keeps posting the single checked value,
  // suffix or not.
  //
  // Issue #258: without this, `fields[name] = field.checked` wrote a boolean per
  // checkbox and same-named boxes overwrote each other, so three boxes with two
  // ticked left the browser as the LAST box's checked state — the chosen values
  // never reached the wire, whatever the action's schema declared.
  #arrayFieldNames(controls) {
    const names = new Set()
    for (const field of controls) {
      // A radio group shares one name BY DESIGN to mean "pick one" and keeps
      // its single checked value, `[]` suffix or not.
      if (field.type === "radio") continue
      if (String(field.name).endsWith("[]")) names.add(field.name)
    }
    return names
  }

  // Names whose group carries a hidden COMPANION: a hidden input is Rails' way
  // of giving a checkbox a value for the unchecked case, and it is never a
  // chosen value. Measured from the helpers, the three shapes are:
  //
  //   check_box(:u, :sub)
  //     <input name="u[sub]" type="hidden" value="0"><input type="checkbox" value="1" name="u[sub]">
  //   check_box(:u, :ids, {multiple: true}, "3")
  //     <input name="u[ids][]" type="hidden" value="0"><input type="checkbox" value="3" name="u[ids][]">
  //   collection_check_boxes(...) / an unchecked_value of nil
  //     <input type="hidden" name="u[ids][]" value="">  — or no hidden at all
  //
  // The value differs (unchecked_value, blank, absent), so the value cannot be
  // the test. What identifies a companion is that a checkbox shares its name.
  // A hidden WITHOUT a same-named checkbox is a list JS maintains, and its
  // value is a chosen value like any other.
  #companionNames(controls) {
    const names = new Set()
    for (const field of controls) if (field.type === "checkbox") names.add(field.name)
    return names
  }

  // Build the multipart body (issue #34). `token`/`act` are flat fields the
  // endpoint reads from params[:token]/params[:act]; scalar params nest under
  // params[<key>] (Rails parses the bracket into params[:params]); each file is
  // appended under params[<name>] (single) — a second file with the same name
  // (a `multiple` picker, several inputs sharing a name) is sent as
  // params[<name>][] so Rails coerces it to an array for a [:file] schema.
  #buildFormData(token, action, params, files) {
    const fd = new FormData()
    fd.append("token", token)
    fd.append("act", action)
    const emptyGroups = []
    for (const [key, value] of Object.entries(params)) {
      // A `[]` name carrying an array is the group shape (issue #258): every
      // element goes to params[name][], which Rack parses as an array. The
      // indexed form #appendField writes for a plain array (params[name][0],
      // params[name][1]) arrives as a hash of index keys — ParamSchema's array
      // type normalizes that back, but only an array type does, so the two
      // bodies would stop coercing identically for the same fields.
      //
      // An EMPTY group cannot be an empty array in a form body, so it is
      // ANNOUNCED instead: its key stays absent from params and its name goes
      // into `empty_groups[]`, a field of its own beside token/act/params. A
      // blank entry was the obvious alternative and is ambiguous — Rails leaves
      // `[""]` to the caller, and a `[:date]` or `[:file]` element reads it as
      // "did not come in", so treating it as "cleared" would change what those
      // params mean. The field is additive: a server that ignores it behaves
      // exactly as it does today, and so does a client that never sends it.
      if (Array.isArray(value) && String(key).endsWith("[]")) {
        if (value.length === 0) {
          emptyGroups.push(String(key).slice(0, -2))
        } else {
          const wire = `${this.#wireKey(key)}[]`
          for (const element of value) fd.append(wire, String(element))
        }
      } else {
        this.#appendField(fd, this.#wireKey(key), value)
      }
    }
    for (const name of emptyGroups) fd.append("empty_groups[]", name)
    const multiNames = this.#multiFileNames(files)
    for (const { name, file, multiple } of files) {
      // params[name][] when the input is `multiple` (array shape even for one
      // file) OR the name repeats across inputs; otherwise a lone scalar file.
      const asArray = multiple || multiNames.has(name)
      const key = asArray ? `${this.#wireKey(name)}[]` : this.#wireKey(name)
      fd.append(key, file, file.name)
    }
    return fd
  }

  // The multipart wire key for a collected field/file name: params[...] with
  // the name's OWN brackets expanded into nesting segments (issue #231). The
  // old verbatim wrap of a Rails-bracketed name — params[blog_post[summary]] —
  // is unparseable by Rack: a scalar arrived as {"blog_post[summary" => {"]" =>
  // value}} (data corruption written through `update!` with a 200) and a file
  // never reached its schema key (silent drop). Expanding blog_post[summary]
  // into params[blog_post][summary] mirrors the server's bracket_path exactly —
  // split at the first "[", then each non-empty bracket segment; an empty
  // trailing segment (tags[]) drops, matching how the JSON path's
  // expand_bracket_keys coerces the same name — so a multipart body and a JSON
  // body coerce identically for the same fields (the documented contract).
  // A flat name stays a single params[name] wrap, byte-identical to before.
  #wireKey(name) {
    const raw = String(name)
    const head = raw.indexOf("[")
    if (head === -1) return `params[${raw}]`
    const segments = [raw.slice(0, head), ...(raw.slice(head).match(/[^\[\]]+/g) ?? [])]
    return `params${segments.map((segment) => `[${segment}]`).join("")}`
  }

  // Append a param leaf to FormData under its bracketed key. FormData carries
  // only strings, so a NON-scalar param (a nested object or an array) is
  // bracket-EXPANDED into params[key][sub] / params[key][index][...] fields —
  // the SAME Rails-form shape the server's expand_bracket_keys / array_values
  // already parse, so a JSON body and a multipart body coerce identically
  // (issue #39). Previously a non-scalar was JSON.stringify'd into one
  // params[key]='<json>' field, which the server received as an un-decodable
  // String leaf and DROPPED (nested hash -> {}, array -> key removed).
  //
  // Arrays use NUMERIC indices (params[key][0], params[key][1]) — required for
  // an array-of-hash so each element's sub-keys stay grouped and the server's
  // index-hash sort rebuilds order; params[key][] would collapse them. A scalar
  // (string/number/boolean) is one string field, mirroring the JSON wire shape
  // (the server's :boolean/:integer casts read "true"/"42"). null/undefined is
  // an empty field. An EMPTY array/object emits NOTHING — FormData can't carry
  // []/{}, so the key is omitted and the action's keyword default applies (this
  // differs from the JSON path, where an explicit [] coerces to an empty array).
  #appendField(fd, key, value) {
    if (value == null) {
      fd.append(key, "")
    } else if (Array.isArray(value)) {
      value.forEach((element, index) => this.#appendField(fd, `${key}[${index}]`, element))
    } else if (typeof value === "object") {
      for (const [subKey, subValue] of Object.entries(value)) {
        this.#appendField(fd, `${key}[${subKey}]`, subValue)
      }
    } else {
      fd.append(key, String(value))
    }
  }

  // Names that appear more than once across the chosen files (a `multiple`
  // picker, or several file inputs sharing a name) — those go to params[name][]
  // so the server sees an array; a lone file stays params[name].
  #multiFileNames(files) {
    const counts = new Map()
    for (const { name } of files) counts.set(name, (counts.get(name) ?? 0) + 1)
    return new Set([...counts].filter(([, n]) => n > 1).map(([name]) => name))
  }

  #parseParams(raw) {
    if (!raw) return {}
    try {
      return typeof raw === "string" ? JSON.parse(raw) : raw
    } catch {
      return {}
    }
  }

  // Stimulus typecasts a JSON param to the parsed array already; a raw string
  // (hand-built attr, non-typecasting harness) is parsed here. Delegates to the
  // shared parseOps so the controller and the reactive:js stream action (issue
  // #97) treat a malformed ops attr identically (→ [], never a throw).
  #parseOps(raw) {
    return parseOps(raw)
  }

  // Interpret a [[name, args], ...] op list against this root (issue #95),
  // scoping each op's targets to this controller's own root via #opTargets (the
  // nested-reactive-root ownership filter, issue #15). The whitelist + skip
  // logic lives in the shared applyOps so runOps and the reactive:js stream
  // action interpret the SAME vocabulary the SAME way (client-side default-deny).
  #applyOps(list) {
    applyOps(
      list,
      (args) => this.#opTargets(args),
      (name, args) => this.#diagnoseZeroTargets(`client op "${name}"`, args),
    )
  }

  // Issue #237: the verbose gate for zero-target diagnostics — the
  // verbose_errors stamp (ON by default in dev/test) or full debug mode (a
  // debug user must never see less). Read live off the root like #debugEnabled.
  #verboseEnabled() {
    return this.element?.getAttribute?.("data-reactive-verbose") === "true" || this.#debugEnabled()
  }

  // Issue #237: called when a selector-form target resolved to ZERO elements on
  // this root. Past the verbose gate the devtools feature (issue #275) does the
  // work: the DOM probes, the dedupe, the trap-specific hint.
  #diagnoseZeroTargets(label, args) {
    if (!this.#verboseEnabled()) return
    if (__SPLIT__) this.#devtools((devtools) => devtools.diagnose(this, label, args))
    else devtoolsFeature.diagnose(this, label, args)
  }

  // Run `use` with the devtools feature: now when it is loaded (the default
  // client, always), else once it has arrived — a warning or a trace a tick
  // late is still a warning. Called only past a debug/verbose gate, so a page
  // with neither never asks for the module.
  #devtools(use) {
    if (__SPLIT__) withFeature("devtools", use)
  }

  // Resolve an op's targets: "@root" is this element; a selector resolves
  // WITHIN this root and excludes nested reactive roots' subtrees (issue #15
  // semantics — the same nearest-root ownership check the field walk uses);
  // global: true opts a single op out to document-wide.
  #opTargets(args) {
    const to = args.to
    if (to === "@root") return [this.element]
    if (typeof to !== "string" || to === "") return []
    if (args.global) return [...document.querySelectorAll(to)]
    return [...this.element.querySelectorAll(to)].filter((el) => this.#ownsField(el))
  }

  // Whether a click-bound checkbox/radio trigger should keep its NATIVE flip
  // (issue #98). `checked: :keep` means "let the control flip now": the
  // unconditional preventDefault is exactly what suppresses that flip until the
  // morph, so we skip it — but ONLY for a checkbox/radio (a bare toggle click
  // has no form-navigation default to lose). Any other element (a button) keeps
  // preventDefault so an in-form submit can't navigate.
  #keepsNativeToggle(optimistic, target) {
    if (optimistic?.checked !== "keep") return false
    const type = target?.type
    return type === "checkbox" || type === "radio"
  }

  // Replay the recorded undo ops on failure (issue #98), guarded by isConnected:
  // a plain (non-morph) replace can detach this subtree before the failure lands,
  // and reverting a stale/detached node is pointless (it's gone) — so a
  // disconnected root skips the revert entirely. On success NOTHING calls this:
  // the server re-render overwrites the hint, or (reply.remove / streams-only)
  // the hint is deliberately left standing.
  #revertOptimistic(inverse) {
    if (!inverse) return
    if (!this.element.isConnected) return
    for (const undo of inverse) undo()
  }

  // Apply the BUSY state for THIS enqueue (issue #181) and return a `settle`
  // closure that undoes exactly this enqueue's contribution when the round trip
  // finishes (success OR any failure). Everything is refcounted so overlapping
  // enqueues never clobber: A's settle can't clear busy while B is still pending.
  //
  // Two layers:
  //   1. The ALWAYS-ON busy vocabulary (fires for every action, no hint needed):
  //      data-reactive-busy="<action>" on the trigger and the root (a
  //      space-separated, per-action refcounted set), aria-busy on the root (a
  //      pending counter), and data-reactive-busy on any busy_on element scoped
  //      to this action. Apps style a spinner with pure CSS and zero Ruby.
  //   2. The busy HINT (only when busy: was declared): the SAME cosmetic op set
  //      as optimistic: (class ops, hide/show, disable, text), applied by the
  //      hints feature (features/hints.js) and reverted on SETTLE (not on
  //      failure) — its undo ops land in `pending.undo`, which the settle
  //      closure replays. They apply at ENQUEUE — never during a debounce quiet
  //      period — so a debounced input is not disabled mid-typing.
  #applyBusy(action, trigger, pending) {
    this.#markBusy(action, trigger)
    // Global activity signal (issue #201): this enqueue is one in-flight reactive
    // operation. Entered HERE (at enqueue, via #applyBusy) so the document marker
    // covers the whole pending window — queue wait included — exactly like the
    // per-root busy vocabulary. Exited once in the settle closure below, which
    // #perform runs in its finally on EVERY exit path (success or any failure).
    enterReactiveActivity()

    let settled = false
    return () => {
      if (settled) return // one settle per enqueue, even if called twice
      settled = true
      this.#unmarkBusy(action, trigger)
      exitReactiveActivity()
      // Busy reverts on SETTLE regardless of outcome, guarded per element.
      for (const op of pending.undo) op()
    }
  }

  // Layer 1 — the always-on busy markers. Trigger + root carry the action token;
  // the root's counter drives aria-busy; busy_on elements scoped to this action
  // light up. Refcounts (#busyActions, #busyPending) so overlapping requests
  // don't clear each other.
  #markBusy(action, trigger) {
    this.#setBusyToken(trigger, action, +1)
    this.#setBusyToken(this.element, action, +1)

    this.#busyActions.set(action, (this.#busyActions.get(action) ?? 0) + 1)
    if (this.#busyPending++ === 0) this.element.setAttribute("aria-busy", "true")

    for (const el of this.#busyOnTargets(action)) this.#setBusyToken(el, action, +1)
  }

  #unmarkBusy(action, trigger) {
    this.#setBusyToken(trigger, action, -1)
    this.#setBusyToken(this.element, action, -1)

    const count = (this.#busyActions.get(action) ?? 1) - 1
    if (count <= 0) this.#busyActions.delete(action)
    else this.#busyActions.set(action, count)

    if (--this.#busyPending <= 0) {
      this.#busyPending = 0
      this.element.removeAttribute("aria-busy")
    }

    for (const el of this.#busyOnTargets(action)) this.#setBusyToken(el, action, -1)
  }

  // Add (+1) or remove (-1) `action` from an element's space-separated
  // data-reactive-busy token set, refcounted PER ELEMENT+ACTION so two queued
  // requests of the same action on the same element don't drop the token early
  // (and two DIFFERENT actions both keep their token — the set never clobbers).
  // The attribute is removed only when the set empties. No-op on a nullish/
  // detached element (a morph may have replaced the trigger before settle).
  #setBusyToken(el, action, delta) {
    if (!el || typeof el.getAttribute !== "function") return

    const counts = (this.#busyTokenCounts.get(el) ?? new Map())
    const next = (counts.get(action) ?? 0) + delta
    if (next <= 0) counts.delete(action)
    else counts.set(action, next)

    if (counts.size === 0) {
      this.#busyTokenCounts.delete(el)
      el.removeAttribute("data-reactive-busy")
      return
    }
    this.#busyTokenCounts.set(el, counts)
    el.setAttribute("data-reactive-busy", [...counts.keys()].join(" "))
  }

  // busy_on elements scoped to THIS action, owned by this root (not a nested
  // reactive root's, issue #15). data-reactive-busy-on="<action>" is the marker
  // busy_on(:action) emits.
  #busyOnTargets(action) {
    const nodes = this.element.querySelectorAll?.("[data-reactive-busy-on]") ?? []
    return [...nodes].filter(
      (el) => el.getAttribute("data-reactive-busy-on") === action && this.#ownsField(el),
    )
  }

  // The action path comes from a <meta> tag that is fixed for the page's life,
  // so resolve it once per controller and cache it — avoids a querySelector on
  // every dispatch (this runs on the request hot path, once per click/keystroke
  // round trip). Cached on the instance, so a fresh connect() (after a Turbo
  // navigation swaps the element) re-reads it.
  #actionPath() {
    return (this.#actionPathCache ??=
      document.querySelector('meta[name="phlex-reactive-action-path"]')?.content ||
      "/reactive/actions")
  }

  // The per-request timeout in ms (issue #101), from a page-stable
  // <meta name="phlex-reactive-timeout"> (default 30000). Cached per-controller
  // like the action path. Parsed defensively: a missing/blank/non-positive/NaN
  // value falls back to the default, so a typo'd meta can never disable the
  // timeout (which would reintroduce the wedged-queue bug) or set a zero/negative
  // window that aborts instantly.
  #timeoutMs() {
    if (this.#timeoutMsCache != null) return this.#timeoutMsCache
    const raw = document.querySelector('meta[name="phlex-reactive-timeout"]')?.content
    const ms = Number(raw)
    return (this.#timeoutMsCache = Number.isFinite(ms) && ms > 0 ? ms : 30000)
  }

  // CSRF token and connection id are read LIVE (not cached) on purpose: Rails
  // can rotate the CSRF token, and the pgbus connection id changes on an SSE
  // reconnect — caching either would send a stale value. A single querySelector
  // per request is cheap next to the round trip itself.
  #csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content ?? ""
  }

  // The pgbus SSE connection id, if the page is subscribed to a stream. pgbus
  // reflects it onto the <pgbus-stream-source connection-id="…"> element (and
  // apps may mirror it to <meta name="pgbus-connection-id">). Returns null
  // when not present (e.g. no pgbus, or no active subscription) — the header
  // is then simply omitted.
  #connectionId() {
    return (
      document.querySelector("pgbus-stream-source[connection-id]")?.getAttribute("connection-id") ||
      document.querySelector('meta[name="pgbus-connection-id"]')?.content ||
      null
    )
  }
}

// Register with Turbo as soon as it is there. LAST in the file: registration
// reads the feature table (the dev module is loaded from it), which must
// exist by then.
if (typeof window !== "undefined") {
  if (window.Turbo) registerReactiveActions()
  else document.addEventListener("turbo:load", registerReactiveActions, { once: true })
}
