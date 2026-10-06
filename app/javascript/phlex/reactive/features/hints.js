// phlex/reactive/features/hints — the pending-state hint engine behind
// `optimistic:` (issue #98) and `busy:` (issue #181): class/hide/show ops on
// the trigger or a `to:` target, the disable + text swap, the native-toggle
// keep, and the debug-only "optimistic hide undone by the reply" check. One
// of the feature modules the opt-in client imports on demand (issue #275); in
// the default client it is part of the one file.
//
// What is NOT here is the always-on busy vocabulary — data-reactive-busy on
// the trigger and the root, aria-busy, busy_on, the activity signal — which
// every request gets with no hint declared, and which the runtime applies the
// moment a request is enqueued. This module only runs for a trigger that
// DECLARED a hint. With the opt-in client such a request waits for this
// module (at most the feature timeout) before it goes out, so the hint is on
// the page for the whole pending window; the busy markers cover the wait.
//
// Nothing here is per root: there is no connect. A root whose triggers carry
// a hint loads the module when it connects, so the first click rarely waits.
// This module never imports the runtime: it reaches a controller through the
// `core` handle.

// trigger -> { count, disabled, html } refcounted text/disable snapshot
// (issue #181), per element across every controller.
const textDisableSnapshots = new WeakMap()

// The busy hint, applied now; returns the undo ops SETTLE replays. A page
// still rendered by the previous gem emits the old `loading` param, whose
// `class:` key is remapped here (legacyLoadingHint).
export function busy(_controller, core, hint, trigger) {
  const normalized = hint && typeof hint === "object" ? legacyLoadingHint(hint) : hint
  return normalized ? applyHint(core, normalized, trigger, false) : []
}

// Apply the OPTIMISTIC hint (issue #98) NOW and return its `undo` closure — the
// exact ops to replay on FAILURE (optimistic reverts only when the round trip
// fails; success leaves server truth or the deliberately-standing hint). It is
// the same op vocabulary busy: uses (issue #181) via the one #applyHint engine;
// the ONLY optimistic-specific op is checked: :keep (honorChecked = true).
// Returns null when there is nothing to undo.
export function optimistic(_controller, core, hint, trigger) {
  if (!hint) return null
  const undo = applyHint(core, hint, trigger, true)
  return undo.length ? undo : null
}

// The ONE pending-state hint engine (issue #181), shared by optimistic: (revert
// on failure) and busy: (revert on settle) — they differ only in WHEN the
// returned undo ops run, never in the ops themselves. Applies the hint's
// cosmetic ops to their targets (the trigger by default, or a `to:` selector
// scoped to the root) and returns an array of undo closures. Class ops and
// hide/show use a DELTA inverse (undo only what THIS call changed, so it
// composes across overlapping enqueues); disable/text use a REFCOUNTED snapshot
// (the true pre-hint value survives an overlapping enqueue that would otherwise
// capture the already-swapped label as the "original"). `honorChecked` gates
// checked: :keep — an optimistic-only native-control revert.
function applyHint(core, hint, trigger, honorChecked) {
  const undo = []
  for (const el of hintTargets(core, hint, trigger)) {
    if (hint.add_class) {
      // Undo only the classes this op ACTUALLY added — a class already present
      // was not our change, so reverting it would strip a class the element
      // legitimately had. Capture the real delta now.
      const added = hint.add_class.filter((c) => !el.classList.contains(c))
      el.classList.add(...added)
      if (added.length) undo.push(() => el.classList.remove(...added))
    }
    if (hint.remove_class) {
      // Symmetric: undo only the classes actually removed.
      const removed = hint.remove_class.filter((c) => el.classList.contains(c))
      el.classList.remove(...removed)
      if (removed.length) undo.push(() => el.classList.add(...removed))
    }
    if (hint.toggle_class) {
      // toggle_class is its own inverse regardless of prior state.
      hint.toggle_class.forEach((c) => el.classList.toggle(c))
      undo.push(() => hint.toggle_class.forEach((c) => el.classList.toggle(c)))
    }
    // hide/show: a delta too (issue #300) — a target already in the hinted
    // state was not our change, so the undo must not force the opposite.
    if (hint.hide && !el.hidden) {
      el.hidden = true
      undo.push(() => (el.hidden = false))
    }
    if (hint.show && el.hidden) {
      el.hidden = false
      undo.push(() => (el.hidden = true))
    }
  }

  // disable/text swap the TRIGGER (a `to:` retargets only the class/hide/show
  // ops above — disable/text are inherently trigger affordances). Refcounted so
  // overlapping enqueues restore correctly.
  if (trigger && (hint.disable || hint.text != null)) {
    undo.push(applyTextDisable(hint, trigger))
  }

  // checked: :keep — the native flip already happened on the trigger; record
  // the inverse (flip it back) so a revert restores the control's state.
  if (honorChecked && hint.checked === "keep" && trigger && "checked" in trigger) {
    const flipped = trigger.checked
    undo.push(() => (trigger.checked = !flipped))
  }

  return undo
}

// The elements a hint's class/hide/show ops apply to: the `to:` selector
// (resolved like an op target — "@root" is the root, a selector is scoped to
// this root's owned matches) or, with no `to:`, the trigger itself.
function hintTargets(core, hint, trigger) {
  if (hint.to == null) return trigger ? [trigger] : []
  const targets = core.opTargets({ to: hint.to })
  // Issue #237: a hint aimed at nothing is the same silent trap as an op.
  if (targets.length === 0) core.diagnose("busy/optimistic hint", { to: hint.to })
  return targets
}

// Swap the trigger's disabled/innerHTML for a pending hint, snapshotting the
// ORIGINAL once per trigger (refcounted so an overlapping enqueue never
// snapshots the already-swapped "Saving…" as the original), and return the undo
// closure. text swaps innerHTML (issue #181), NOT textContent: a composite
// trigger like `<button><svg/> Save</button>` has child nodes, and
// textContent = "Saving…" would DESTROY the icon; innerHTML preserves the
// markup structure and restores it byte-for-byte.
function applyTextDisable(hint, trigger) {
  const snap = textDisableSnapshots.get(trigger)
  if (snap) {
    snap.count++
  } else {
    textDisableSnapshots.set(trigger, {
      count: 1,
      disabled: trigger.disabled,
      html: trigger.innerHTML,
      hadText: hint.text != null,
      swappedTo: hint.text,
    })
  }

  if (hint.disable) trigger.disabled = true
  if (hint.text != null) trigger.innerHTML = hint.text

  return () => restoreTextDisable(trigger, hint)
}

// Restore the trigger's disabled/innerHTML from its snapshot when the LAST
// enqueue for that trigger settles (refcount → 0). GUARDED: skip a disconnected
// trigger (a plain replace detached it — the node is gone), and do NOT restore
// the label if it no longer equals what we swapped IN (a morph rendered a new
// server label — clobbering it with the old markup would fight server truth).
// The comparison + restore both use innerHTML so a composite trigger (icon +
// label) round-trips its full markup, not a flattened text run (issue #181).
function restoreTextDisable(trigger, hint) {
  const snap = textDisableSnapshots.get(trigger)
  if (!snap) return
  if (--snap.count > 0) return // another enqueue for this trigger is still pending
  textDisableSnapshots.delete(trigger)

  if (!trigger.isConnected) return // detached — nothing to restore

  if (hint.disable) trigger.disabled = snap.disabled
  if (snap.hadText && trigger.innerHTML === snap.swappedTo) trigger.innerHTML = snap.html
}

// Deploy-overlap read shim (issue #181): a page still rendered by the PREVIOUS
// gem emits the old data-reactive-loading-param, whose `class:` key is the busy
// vocabulary's `add_class:`. Remap it so an in-flight legacy page keeps its
// pending affordance through the one #applyHint engine. Returns null for the
// common (no legacy param) case so the fast path is untouched. Drop this shim
// one minor after #181 ships (no page can still carry the old attr by then).
function legacyLoadingHint(loading) {
  if (!loading || typeof loading !== "object") return null
  const { class: cls, ...rest } = loading
  return cls == null ? loading : { ...rest, add_class: cls }
}

// Snapshot the elements an optimistic hide: targeted (the trigger, or the `to:`
// selector) so the success path can detect a resurrection. Returns null unless
// a hide: hint is present — nothing else can be "resurrected". Debug only:
// the success path runs the check after the morph.
export function resurrection(_controller, core, hint, target) {
  if (!hint?.hide) return null
  const hidden = hintTargets(core, hint, target)
  if (!hidden.length) return null
  return () => {
    const back = hidden.filter((el) => el.isConnected && !el.hidden)
    if (!back.length) return
    console.warn(
      "[phlex-reactive] optimistic: { hide: true } was undone by the reply's re-render — " +
        "the element is visible again. For an instant delete, return reply.remove so the " +
        "server removes it; otherwise the hide only flashes.",
      back,
    )
  }
}
