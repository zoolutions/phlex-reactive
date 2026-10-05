// phlex/reactive/features/effects — stream effects (issue #215) and
// self-dismissing flashes (issue #100): everything the client does AROUND a
// <turbo-stream> render. One of the feature modules the core imports on
// demand (issue #275); in the default client it is part of the one file.
//
// Both are document-level, not per root: the core owns the ONE
// turbo:before-stream-render listener and hands every event to wrap() below,
// which wraps event.detail.render. With phlex/reactive/core alone the module
// is imported when a root declares an effect, or when the first stream that
// needs it arrives — the core then holds that stream's render (and any stream
// behind it) until the module is here, so the effect applies to THAT stream.
//
// This module never imports the core.

// The core's stream-render listener calls this for every <turbo-stream>.
// Dismiss wraps first, effects around it — the order the two listeners were
// registered in before they shared one.
export function wrap(event) {
  wrapStreamRenderForDismiss(event)
  wrapStreamRenderForEffects(event)
}

// Schedule every dismissing flash already in the document: what the core runs
// once when the module arrives late (a flash rendered while it was loading).
export function sweep() {
  scheduleReactiveDismissals()
}

// Document-level self-dismissing flashes (issue #100). A flash rendered with
// dismiss_after: carries data-reactive-dismiss-after="<ms>"; after the timeout
// it removes itself. This is deliberately NOT a Stimulus controller — the flash
// container is a plain host-app div (Response#flash appends into it) with no
// controller attached, so nothing would honor the attr. A document-level scan
// on turbo:before-stream-render (which fires for EVERY <turbo-stream> render —
// a reply AND a broadcast) schedules removal for any newly-arrived dismissing
// flash. Each is marked data-reactive-dismiss-scheduled so re-scans (a later
// stream render) never double-schedule the same node.
//
// turbo:before-stream-render fires BEFORE the stream is applied — and Turbo
// then does `await nextRepaint(); await event.detail.render(this)`, so a bare
// setTimeout(0) can run BEFORE the node is inserted (observed under Falcon).
// WRAP event.detail.render instead: run Turbo's own render, then scan once it
// has resolved — timing-independent and correct on every server. detail.render
// may be absent on exotic streams — guard it.

// Chain the dismissing-flash scan after Turbo's own stream render resolves, so
// the scan sees the freshly-inserted node. Idempotent per event (marks
// detail.render as already-wrapped) and defensive if detail/render is missing.
function wrapStreamRenderForDismiss(event) {
  const detail = event.detail
  const original = detail?.render
  if (typeof original !== "function" || original.__reactiveDismissWrapped) {
    // No render to wrap (or already wrapped) — fall back to a post-repaint scan.
    if (typeof requestAnimationFrame === "function") requestAnimationFrame(scheduleReactiveDismissals)
    else setTimeout(scheduleReactiveDismissals, 0)
    return
  }
  const wrapped = async (streamElement) => {
    await original(streamElement)
    scheduleReactiveDismissals()
  }
  wrapped.__reactiveDismissWrapped = true
  detail.render = wrapped
}

// Scan for un-scheduled dismissing flashes and schedule each one's removal.
// Kept a module function so the scan logic is testable and re-run on every
// stream render.
function scheduleReactiveDismissals() {
  const flashes = document.querySelectorAll("[data-reactive-dismiss-after]")
  for (const el of flashes) {
    if (el.hasAttribute("data-reactive-dismiss-scheduled")) continue
    const ms = Number(el.getAttribute("data-reactive-dismiss-after"))
    if (!Number.isFinite(ms) || ms <= 0) continue
    el.setAttribute("data-reactive-dismiss-scheduled", "")
    setTimeout(() => el.remove(), ms)
  }
}


// Reactive effects (issue #215): animate ENTER (append/prepend), EXIT (remove)
// and UPDATE (replace/update, plain or morph) when a <turbo-stream> renders.
// Document-level and render-wrapping like the dismiss hook above, so ONE
// interceptor covers both delivery paths (a reply and a broadcast). Strictly
// data-driven and default-deny: the per-call data-reactive-effect on the
// stream element wins ("off" suppresses), else the carrier element's
// data-reactive-effect-<hook> — the DOM target for exit/update, the INCOMING
// template root for enter. No attribute → no work; unknown names and
// malformed legs warn + skip (a newer or forged attr must never break the
// page). prefers-reduced-motion disables everything (the shipped CSS is also
// media-wrapped — defense in depth).
//
// Timing:
//   * exit — the animation runs BEFORE Turbo's render (the removal), awaited
//     via animationend/transitionend with a timeout fallback; a ZERO computed
//     duration (no effects CSS loaded, reduced-motion CSS gate) skips the wait
//     entirely, so a missing stylesheet can never freeze a removal.
//   * enter/update — Turbo renders first, then the effect class is applied to
//     the inserted/updated element(s) and removed on settle (fire-and-forget).
//     Re-applying an update effect restarts it (class off → reflow → on).
//
// A named effect maps to the shipped CSS class reactive-fx--<name>-<hook>
// (app/assets/stylesheets/phlex/reactive/effects.css); "random" picks a
// built-in per application; a "["-prefixed value is a custom
// [during, from, to] class-legs triple (the #96/#186 vocabulary), run with
// runTransition's add → frame → swap → settle choreography.
const EFFECT_HOOKS = Object.freeze({
  append: "enter",
  prepend: "enter",
  replace: "update",
  update: "update",
  remove: "exit",
})
const EFFECT_BUILT_INS = Object.freeze(["fade", "slide", "scale", "highlight", "shake"])
// Marks an incoming template root so the post-render scan finds the inserted
// CLONE (Turbo clones template content on render — attrs ride the clone).
const EFFECT_PENDING_ATTR = "data-reactive-fx-pending"
// The hard ceiling on any effect wait — an exit's removal is delayed at most
// this long even if animationend/transitionend never fire.
const EFFECT_SETTLE_FALLBACK_MS = 1000


// Wrap event.detail.render (the dismiss-hook pattern) when this stream both
// maps to a hook AND resolves to an effect. Resolution happens HERE, before
// the render, because exit must read the target while it is still in the DOM
// and enter must read (and mark) the template content before Turbo clones it.
function wrapStreamRenderForEffects(event) {
  const detail = event.detail
  const original = detail?.render
  if (typeof original !== "function" || original.__reactiveEffectsWrapped) return
  const streamEl = detail?.newStream ?? event.target
  const hook = EFFECT_HOOKS[streamEl?.getAttribute?.("action")]
  if (!hook || effectsReducedMotion()) return
  const effect = resolveStreamEffect(streamEl, hook)
  if (!effect) return

  const wrapped =
    hook === "exit"
      ? async (el) => {
          await runExitEffect(effectTarget(streamEl), effect)
          await original(el)
        }
      : async (el) => {
          const container = hook === "enter" ? markIncomingRoots(streamEl) : null
          await original(el)
          if (hook === "enter") animateMarkedRoots(container, effect)
          else runEnterOrUpdateEffect(effectTarget(streamEl), effect)
        }
  wrapped.__reactiveEffectsWrapped = true
  detail.render = wrapped
}

// The effect for this stream: per-call data-reactive-effect first ("off" →
// none), else the carrier's declared data-reactive-effect-<hook>.
function resolveStreamEffect(streamEl, hook) {
  const perCall = streamEl.getAttribute?.("data-reactive-effect")
  if (perCall === "off") return null
  if (perCall) return parseEffect(perCall, hook)
  const carrier = hook === "enter" ? incomingEffectRoot(streamEl) : effectTarget(streamEl)
  const declared = carrier?.getAttribute?.(`data-reactive-effect-${hook}`)
  return declared ? parseEffect(declared, hook) : null
}

// The stream's CURRENT DOM target (re-queried at use, so a post-replace call
// sees the freshly-swapped element). Our builders always emit `target` —
// multi-`targets` streams are not ours and pass through unanimated.
function effectTarget(streamEl) {
  const target = streamEl.getAttribute?.("target")
  return target ? (document.getElementById?.(target) ?? null) : null
}

// The incoming content's root element (an append/prepend's arriving
// component) — the carrier of a declared enter effect.
function incomingEffectRoot(streamEl) {
  return streamEl.querySelector?.("template")?.content?.firstElementChild ?? null
}

// A wire value → an executable effect: { className } for a shipped built-in
// ("random" picks one per application), { legs } for a custom triple. null +
// console.warn for anything else (default-deny).
function parseEffect(value, hook) {
  if (value.startsWith("[")) {
    let legs = null
    try {
      const parsed = JSON.parse(value)
      if (Array.isArray(parsed) && parsed.length === 3) legs = parsed.map(String)
    } catch {
      // malformed JSON → the shared warn below
    }
    if (legs) return { legs }
    console.warn(`[phlex-reactive] malformed effect legs ${JSON.stringify(value)} — skipped`)
    return null
  }
  const name =
    value === "random" ? EFFECT_BUILT_INS[Math.floor(Math.random() * EFFECT_BUILT_INS.length)] : value
  if (!EFFECT_BUILT_INS.includes(name)) {
    console.warn(`[phlex-reactive] unknown effect ${JSON.stringify(value)} — skipped`)
    return null
  }
  return { className: `reactive-fx--${name}-${hook}` }
}

function effectsReducedMotion() {
  try {
    return typeof matchMedia === "function" && matchMedia("(prefers-reduced-motion: reduce)").matches
  } catch {
    return false
  }
}

// Stamp each incoming template root with the pending marker (Turbo's render
// clones the content, so the marker rides the inserted clone) and return the
// container the post-render scan searches. Pre-render on purpose.
function markIncomingRoots(streamEl) {
  const content = streamEl.querySelector?.("template")?.content
  if (!content) return null
  for (const child of Array.from(content.children ?? [])) child.setAttribute?.(EFFECT_PENDING_ATTR, "")
  return effectTarget(streamEl)
}

// Post-render: find the just-inserted clones by their marker, unmark, animate.
function animateMarkedRoots(container, effect) {
  if (typeof container?.querySelectorAll !== "function") return
  for (const el of Array.from(container.querySelectorAll(`[${EFFECT_PENDING_ATTR}]`))) {
    el.removeAttribute(EFFECT_PENDING_ATTR)
    runEnterOrUpdateEffect(el, effect)
  }
}

// EXIT: animate on the still-present element, resolve when settled, and only
// then does the wrapper run Turbo's removal. Zero computed duration (no
// effects CSS) resolves immediately — never a dead 1s freeze.
async function runExitEffect(el, effect) {
  if (!el?.classList) return
  if (effect.legs) {
    await runLegsEffect(el, effect.legs)
    return
  }
  el.classList.add(effect.className)
  const duration = effectDurationMs(el)
  if (duration <= 0) {
    el.classList.remove(effect.className)
    return
  }
  await effectSettled(el, duration)
  el.classList.remove(effect.className)
}

// ENTER/UPDATE: fire-and-forget after the render. A re-applied class is
// removed + reflowed first so rapid successive updates restart the flash; the
// per-element token keeps an older settle from clearing a newer application.
function runEnterOrUpdateEffect(el, effect) {
  if (!el?.classList) return
  if (effect.legs) {
    runLegsEffect(el, effect.legs)
    return
  }
  if (el.classList.contains(effect.className)) {
    el.classList.remove(effect.className)
    void el.offsetWidth // force a reflow so re-adding restarts the animation
  }
  el.classList.add(effect.className)
  const duration = effectDurationMs(el)
  if (duration <= 0) {
    el.classList.remove(effect.className)
    return
  }
  const token = (el.__reactiveFxToken = (el.__reactiveFxToken ?? 0) + 1)
  effectSettled(el, duration).then(() => {
    if (el.__reactiveFxToken === token) el.classList.remove(effect.className)
  })
}

// Custom class legs — runTransition's choreography (add during+from, swap
// from→to on the next frame, settle, clean up), promise-shaped so an exit can
// await it. Class lists are space-separated (the #96/#186 wire).
//
// Rapid re-application on the same element RESTARTS, mirroring the named
// path's token guard: each run takes the per-element token, clears any
// earlier run's leg classes, and a superseded run stops touching the element
// the moment a newer run owns it — so a stale settle can never strip classes
// mid-animation or double-swap the legs. A superseded EXIT run resolves
// early, which only lets Turbo's removal proceed sooner (never later).
async function runLegsEffect(el, legs) {
  const [during, from, to] = legs.map(splitEffectClasses)
  const token = (el.__reactiveFxToken = (el.__reactiveFxToken ?? 0) + 1)
  el.classList.remove(...during, ...from, ...to)
  el.classList.add(...during, ...from)
  await effectNextFrame()
  if (el.__reactiveFxToken !== token) return
  el.classList.remove(...from)
  el.classList.add(...to)
  const duration = effectDurationMs(el)
  if (duration > 0) await effectSettled(el, duration)
  if (el.__reactiveFxToken !== token) return
  el.classList.remove(...during, ...to)
}

function splitEffectClasses(list) {
  return String(list ?? "")
    .split(/\s+/)
    .filter(Boolean)
}

// The longest computed animation/transition (duration + delay, comma lists
// included) in ms, capped at the hard fallback. 0 when getComputedStyle is
// unavailable or nothing animates — callers skip the wait entirely.
function effectDurationMs(el) {
  if (typeof getComputedStyle !== "function") return 0
  try {
    const style = getComputedStyle(el)
    const longest = (value) =>
      String(value ?? "")
        .split(",")
        .reduce((max, part) => Math.max(max, parseFloat(part) || 0), 0)
    const animation = longest(style.animationDuration) + longest(style.animationDelay)
    const transition = longest(style.transitionDuration) + longest(style.transitionDelay)
    return Math.min(Math.max(animation, transition) * 1000, EFFECT_SETTLE_FALLBACK_MS)
  } catch {
    return 0
  }
}

// Resolve on animationend/transitionend — whichever fires first — with a
// timeout slightly past the computed duration, so a canceled animation (a
// display:none ancestor, an interrupted transition) can't hang an exit.
function effectSettled(el, durationMs) {
  return new Promise((resolve) => {
    let done = false
    const settle = () => {
      if (done) return
      done = true
      resolve()
    }
    el.addEventListener?.("animationend", settle, { once: true })
    el.addEventListener?.("transitionend", settle, { once: true })
    setTimeout(settle, Math.min(durationMs + 50, EFFECT_SETTLE_FALLBACK_MS))
  })
}

function effectNextFrame() {
  return new Promise((resolve) => {
    if (typeof requestAnimationFrame === "function") requestAnimationFrame(() => resolve())
    else setTimeout(resolve, 16)
  })
}
