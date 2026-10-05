// phlex/reactive/features/devtools — development aids: the latency
// simulator (issue #102), the zero-target diagnostics (issue #237) and the
// client debug trace (issue #108). One of the feature modules the opt-in
// client imports on demand (issue #275); in the default client it is part of
// the one file.
//
// When the opt-in client imports it: at registration on a page that carries
// <meta name="phlex-reactive-env" content="development"> or has a latency
// delay stored for the tab (effectively eager, in development); at connect
// for a root stamped data-reactive-debug="true"; and otherwise the first
// time a verbose root has something to warn about, after which the warning
// is a tick late. The runtime keeps the gates (the debug and verbose attribute
// reads) and asks for the module only past them, so a production page with
// neither never fetches it.
//
// This module never imports the runtime: it reaches a controller through the
// `core` handle.

// Latency simulator dev aid (issue #102). On localhost the click→morph round
// trip is ~5ms, so the pending/loading/optimistic affordances (aria-busy,
// disable_with, busy_on, optimistic hints) flash by too fast to see while
// developing or demoing them — the reason LiveView ships enableLatencySim(ms).
//
// enableLatencySim(ms) persists the delay to sessionStorage (session-scoped, so
// it clears when the tab closes — never a config you forget you left on); the
// controller awaits delay() right before the fetch, stretching the already-set
// busy window to something visible. disableLatencySim() clears it. NAMED
// exports (the setConfirmResolver precedent; phlex/reactive/reactive_controller
// re-exports them) — but importmap module exports are unreachable from the
// browser console, so attach() ALSO puts them on window.PhlexReactive, and
// ONLY when the app opts in with
// <meta name="phlex-reactive-env" content="development">.
export const LATENCY_KEY = "phlex-reactive:latency"

// One-time "sim active" banner guard: delay() warns ONCE while the sim is on,
// not once per request.
let latencyBannerShown = false

export function enableLatencySim(ms) {
  if (typeof sessionStorage === "undefined") return
  sessionStorage.setItem(LATENCY_KEY, String(ms))
}

export function disableLatencySim() {
  if (typeof sessionStorage === "undefined") return
  sessionStorage.removeItem(LATENCY_KEY)
  // Re-arm the one-time "sim active" banner: turning the sim OFF is the lifecycle
  // boundary, so a later enableLatencySim() in the same session re-announces that
  // the sim is on (otherwise the guard would stay set across an off→on cycle and
  // swallow the banner).
  latencyBannerShown = false
}

// The console handle. importmap module exports aren't reachable from the
// DevTools console, so the two functions also go on a window global — which
// the core asks for ONLY when the app authored
// <meta name="phlex-reactive-env" content="development">. There is NO
// engine-emitted meta (the engine can't inject into the host layout); the
// install generator ships the snippet commented. Without the meta: no global
// handle at all — zero production surface.
export function attach() {
  if (typeof window !== "undefined") window.PhlexReactive = { enableLatencySim, disableLatencySim }
}

// Forget the one-time active-sim banner (tests).
export function resetLatencySim() {
  latencyBannerShown = false
}

// If enableLatencySim(ms) stored a delay in sessionStorage, resolve after it —
// the controller awaits this before the fetch so the busy window (already open
// since enqueue) is actually visible on localhost. Reads the key LIVE per
// request — like the CSRF token — so toggling the sim mid-session takes effect
// on the very next action without a reload. A missing sessionStorage, an absent
// key, or a non-positive/NaN value resolves immediately (no timer, no delay) —
// the whole feature is inert for any app that never opts in.
export function delay() {
  if (typeof sessionStorage === "undefined") return Promise.resolve()
  const ms = Number(sessionStorage.getItem(LATENCY_KEY))
  if (!Number.isFinite(ms) || ms <= 0) return Promise.resolve()
  if (!latencyBannerShown) {
    latencyBannerShown = true
    console.warn(
      `[phlex-reactive] latency simulator ACTIVE — every action is delayed by ${ms}ms. ` +
        "Call PhlexReactive.disableLatencySim() (or clear sessionStorage) to turn it off.",
    )
  }
  return new Promise((resolve) => setTimeout(resolve, ms))
}

// --- The zero-target diagnostics (issue #237) ---------------------------------
// The runtime calls these only past the verbose gate.
// --- zero-target diagnostics (issue #237) -----------------------------------
// An op resolving ZERO targets is indistinguishable from a working no-op, and
// the documented scoping traps (nested-root ownership filter, root-self
// selector, stream default scope) all present exactly that way. Under the
// verbose gate (data-reactive-verbose, stamped when Phlex::Reactive
// .verbose_errors is on — dev/test by default — or the debug attr) warn ONCE
// per unique (label, selector, scope) with a targeted hint when the element
// EXISTS but sits outside the op's scope. Everything below runs only after a
// zero-match with the gate on; production (no attr) pays one boolean per empty
// resolution and never probes the DOM.
//
// Dedupe is keyed per document (page lifetime): a WeakMap entry per document
// means a fresh page — or a fresh unit-harness stub — starts clean, and the
// per-keystroke reducer ($ops) path can never flood the console.
const zeroTargetWarnSets = new WeakMap()

function zeroTargetAlreadyWarned(key) {
  const doc = globalThis.document
  if (!doc) return true
  let seen = zeroTargetWarnSets.get(doc)
  if (!seen) {
    seen = new Set()
    zeroTargetWarnSets.set(doc, seen)
  }
  if (seen.has(key)) return true
  seen.add(key)
  return false
}

// Guarded probes: unit harnesses stub partial documents/roots, and an exotic
// selector could throw — a diagnostic must never break the op pipeline.
function countMatches(node, selector) {
  try {
    return node?.querySelectorAll?.(selector)?.length ?? 0
  } catch {
    return 0
  }
}

function emitZeroTargetWarn(label, to, scope, hint) {
  if (zeroTargetAlreadyWarned(`${label}|${to}|${scope}`)) return
  console.warn(`[phlex-reactive] ${label} matched zero targets for selector "${to}" (${scope})${hint}`)
}

// The stream-path diagnoser (reactive:js). No ownership filter exists here, so
// the only trap is the target-root scope: the selector matches document-wide
// but the op was scoped to the stream's target root.
function diagnoseStreamZeroTargets(name, args, root) {
  const to = args.to
  if (typeof to !== "string" || to === "" || to === "@root") return
  let hint = ""
  if (root && !args.global) {
    const n = countMatches(globalThis.document, to)
    if (n > 0) hint = ` — it matches ${n} element(s) outside the stream's target root; use global: true`
  }
  emitZeroTargetWarn(`client op "${name}"`, to, root ? `scoped to #${root.id || "?"}` : "document-scoped", hint)
}

// The runtime's call-ins. `c` is a controller's context: its root and id.
function ctx(controller) {
  return { root: controller.element }
}

export function diagnose(controller, label, args) {
  diagnoseZeroTargets(ctx(controller), label, args)
}

export function noBinding(controller, event) {
  warnNoBinding(ctx(controller), event)
}

// The stream path (reactive:js): no root, or the stream's target root.
export function diagnoseStream(name, args, root) {
  diagnoseStreamZeroTargets(name, args, root)
}

export function missingRoot(targetId) {
  if (!zeroTargetAlreadyWarned(`missing-root|#${targetId}`)) {
    console.warn(`[phlex-reactive] reactive:js stream target root #${targetId} is not in the DOM — its ops were dropped`)
  }
}

// --- The debug trace (issue #108) -----------------------------------------------
export function recordBody(debug, body, freshToken) {
  debugRecordBody(null, debug, body, freshToken)
}

export function trace(controller, info) {
  logDispatch(ctx(controller), info)
}

// Issue #237: called when a selector-form target resolved to ZERO elements on
// this root. Gated + deduped (module helpers); builds the trap-specific hint:
// the root-self selector (root-scoped resolution never includes the root),
// the nested-reactive-root ownership filter, or plain out-of-scope. All DOM
// probes run only here — after a zero-match with the gate on.
function diagnoseZeroTargets(c, label, args) {
  const to = args.to
  if (typeof to !== "string" || to === "" || to === "@root") return
  let hint = ""
  if (!args.global) {
    if (c.root?.matches?.(to)) {
      hint = " — the selector matches this component's own root, which root-scoped resolution never includes; use to: :root"
    } else if (countMatches(c.root, to) > 0) {
      hint = " — it matches only inside a nested reactive root (excluded by ownership scoping); use global: true"
    } else {
      const n = countMatches(globalThis.document, to)
      if (n > 0) hint = ` — it matches ${n} element(s) outside this scope; use global: true`
    }
  }
  emitZeroTargetWarn(label, to, `scoped to #${c.root?.id || "?"}`, hint)
}

// Issue #271: runOps fired but no record matched the event — a hand-edited
// attr or a descriptor the matcher doesn't know. Verbose gate only, deduped.
function warnNoBinding(c, event) {
  const key = `no-binding|${event.type}|${c.root?.id || "?"}`
  if (zeroTargetAlreadyWarned(key)) return
  console.warn(
    `[phlex-reactive] runOps on #${c.root?.id || "?"} found no on_client binding matching a "${event.type}" event — nothing ran`,
  )
}

// Parse a turbo-stream response's action + target pairs for the debug trace,
// from the body text #perform ALREADY read (never a re-fetch). NAMES only — the
// <template> contents (rendered HTML, the fresh token) are deliberately not
// touched. A non-turbo-stream / empty body yields [] (nothing to report).
function debugStreams(_c, body) {
  if (!body) return []
  const streams = []
  const re = /<turbo-stream\b([^>]*)>/g
  let match
  while ((match = re.exec(body)) !== null) {
    const attrs = match[1]
    const action = attrs.match(/\baction="([^"]*)"/)?.[1] ?? "?"
    const target = attrs.match(/\btarget="([^"]*)"/)?.[1]
    streams.push(target ? `${action} → #${target}` : action)
  }
  return streams
}

// console.group ONE dispatch (issue #108). Carries NAMES + outcomes ONLY — the
// signed token VALUE and every field/param VALUE are deliberately absent (they
// may be sensitive; the whole point is observability without leaking data). The
// caller passes the info it already holds so nothing is recomputed or re-fetched:
//   { action, paramNames, fieldNames, encoding, status, streams, tokenRefreshed, ms }
// `console.groupCollapsed` keeps the console tidy (one collapsed line per action).
function logDispatch(c, info) {
  const { action, status, ms } = info
  // The client can't name the component CLASS (it's inside the signed, opaque
  // token — never decoded here), but the root's id is the stable client-side
  // handle (e.g. #todo_42), so the header reads `reactive #todo_42 rename → …`.
  const who = c.root?.id ? `#${c.root.id} ` : ""
  const header = `reactive ${who}${action} → ${status ?? "—"} (${Math.round(ms)}ms)`
  /* eslint-disable no-console */
  console.groupCollapsed(header)
  console.log(`params: [${info.paramNames.join(", ")}] + collected: [${info.fieldNames.join(", ")}]`)
  console.log(`encoding: ${info.encoding}`)
  if (info.streams.length) console.log(`streams: ${info.streams.join("   ")}`)
  console.log(`token: ${info.tokenRefreshed ? "refreshed ✓" : "unchanged"}`)
  console.groupEnd()
  /* eslint-enable no-console */
}

// Debug (issue #108): fold the response body #perform already read into the
// trace — the stream action/target pairs and whether a token refresh arrived
// (a boolean; the token VALUE is intentionally not stored). Shared by the
// success and the non-OK-turbo-stream branches so both log the same shape.
function debugRecordBody(_c, debug, body, freshToken) {
  debug.streams = debugStreams(_c, body)
  debug.tokenRefreshed = freshToken != null
}
