// phlex/reactive/features/dev — development aids. One of the feature modules
// the core imports on demand (issue #275); in the default client it is part
// of the one file. Today: the latency simulator.
//
// It is page-level, not per root. With phlex/reactive/core alone the core
// imports it at registration when the page carries
// <meta name="phlex-reactive-env" content="development"> or a delay is stored
// for this tab — so in development it is effectively eager, and in production
// (no meta, no stored delay) it is never fetched.
//
// This module never imports the core.

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
