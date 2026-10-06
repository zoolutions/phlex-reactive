// phlex/reactive/features/form — what a form root sets up when it connects
// and re-syncs after a morph, with no round trip: dirty tracking and the
// navigate-away guard (issue #103), and the paste-trigger availability gate
// (issue #228). One of the feature modules the core imports on demand (issue
// #275); in the default client it is part of the one file.
//
// The two share a module because they share a shape, not a page: a marker
// check at connect, one pass over the root's own controls, the same pass
// again on turbo:morph-element. The gate alone is smaller than what a module
// of its own costs the core.
//
// This module never imports the core: it reaches a controller through the
// `core` handle (core.owns — is this control this root's own, issue #15).

// controller -> the removals of what connect() added, for disconnect() to run.
const wired = new WeakMap()
// The turbo:before-visit events a warn_unsaved root already prompted for: one
// prompt per visit, however many dirty roots guard the page (issue #298).
const askedVisits = new WeakSet()

export function connect(controller, core) {
  const root = controller.element
  const offs = []
  wired.set(controller, offs)
  // Add a listener and keep its removal. Closures, not a record of named
  // handlers: the minifier renames a local, never a property (issue #310).
  const listen = (target, type, handler) => {
    target.addEventListener?.(type, handler)
    offs.push(() => target.removeEventListener?.(type, handler))
  }

  // Dirty tracking (issue #103) — ONLY when this root opts in (track_dirty: or a
  // reactive_field(dirty:)), so a component that never uses it pays nothing (no
  // baseline scan, no morph listener on every broadcast). A plain (outerHTML)
  // replace re-connects the controller, so seed the baseline scan here — the root
  // reflects current-vs-default WITHOUT waiting for the first input. An in-place
  // morph / broadcast morph keeps the element CONNECTED and fires no Stimulus
  // lifecycle, so ALSO listen for turbo:morph-element on the root to re-scan
  // after the morph writes fresh default* attributes (reactive:applied is NOT a
  // valid hook — it fires when streams are handed to Turbo, BEFORE the DOM
  // mutation). Both listeners are torn down in disconnect().
  if (dirtyTrackingEnabled(root, core)) {
    const rescan = () => scan(controller, core)
    listen(root, "turbo:morph-element", rescan)
    rescan()

    // warn_unsaved: arm a navigate-away guard gated on a LIVE dirty-count read
    // (never a cached snapshot — the count is re-derived from the DOM each time).
    // beforeunload covers a real browser unload; turbo:before-visit covers a
    // Turbo in-app navigation (it does NOT fire on restoration visits — the
    // documented gap). Registered on window only when the marker is present.
    if (root.getAttribute?.("data-reactive-warn-unsaved") === "true") armUnsavedGuard(root, listen)
  }

  // Clipboard-trigger availability gate (issue #228) — ONLY when this root
  // owns a paste trigger (on_client marks one with data-reactive-clipboard).
  // The Async Clipboard API is absent in insecure contexts and some webviews;
  // a paste button that can never work must not show. The gate OWNS a marked
  // trigger's `hidden` flag: author the trigger `hidden` and this pass reveals
  // it where the API exists (a dead button never paints); turbo:morph-element
  // re-syncs because a morph rewrites the trigger back to its authored hidden
  // state. The decision is made ONCE at connect — render the paste trigger
  // unconditionally: a trigger first INTRODUCED by a later morph of a root
  // that already tracks dirtiness stays ungated (hidden) until a full replace
  // re-connects the controller.
  if (clipboardGateEnabled(root, core)) {
    const sync = () => syncClipboardTriggers(root, core)
    listen(root, "turbo:morph-element", sync)
    sync()
  }
}

// Remove the listeners on disconnect (Turbo morph/navigation) so a morph
// re-scan or a navigate-away guard never runs against a detached root.
export function disconnect(controller) {
  for (const off of wired.get(controller) ?? []) off()
  wired.delete(controller)
}

// Whether this root opts into dirty tracking (issue #103): track_dirty: puts the
// trackDirty descriptor on the ROOT's data-action; a per-field reactive_field(
// dirty:) puts it on a descendant field. Either turns tracking on. A quick
// attribute read + one scoped query, evaluated once per connect (a cold path).
function dirtyTrackingEnabled(root, core) {
  if ((root.getAttribute?.("data-action") ?? "").includes("reactive#trackDirty")) return true
  const nodes = root.querySelectorAll?.('[data-action*="reactive#trackDirty"]') ?? []
  for (const el of nodes) if (core.owns(el)) return true
  return false
}

// Dirty tracking (issue #103). Wired by reactive_field(dirty: true) /
// reactive_root(track_dirty: true): an `input` on an owned field runs a FULL
// re-scan of every field this root owns (the controller's trackDirty action
// calls this). NO round trip, NO shipped state.
//
// Re-compute the dirty flag for EVERY field this root owns in one pass, then
// reflect the total onto the root. Called on an owned field's input, on
// connect (baseline seed), and after a turbo:morph-element re-render (fresh
// default* attrs). dirty = current ≠ the DOM's own default:
//   checkbox/radio → checked  !== defaultChecked
//   select         → some option.selected !== its reset state (issue #297)
//   else           → value    !== defaultValue
// A full pass (not per-target) is REQUIRED: a radio group's previously-checked
// radio flips to checked=false with NO input event, so per-target toggling
// would leave its flag stale. File inputs are skipped — a file has no server
// default baseline. Per-dirty-field data-reactive-dirty="true" ("true" STRING,
// not a valueless boolean attr — mirrors the on() flag convention); the root
// carries data-reactive-dirty="<count>" and DROPS the attr at zero, so
// `[data-reactive-dirty]` styles the whole form and `[data-reactive-dirty]`
// on a field styles just the changed control — both pure CSS, zero JS.
export function scan(controller, core) {
  const root = controller.element
  // Runs at bootstrap (the connect baseline seed) as well as on input/morph, so
  // it must never throw — degrade to a no-op if the root can't be queried (a real
  // reactive root always can; this guards minimal/test element stubs).
  if (typeof root?.querySelectorAll !== "function") return

  let count = 0
  root.querySelectorAll("input[name], select[name], textarea[name]").forEach((field) => {
    if (!core.owns(field)) return // skip a nested reactive root's fields (issue #15)
    if (field.type === "file") return // no server default baseline to diff against

    if (fieldDirty(field)) {
      field.setAttribute("data-reactive-dirty", "true")
      count++
    } else {
      field.removeAttribute("data-reactive-dirty")
    }
  })

  if (count > 0) root.setAttribute("data-reactive-dirty", String(count))
  else root.removeAttribute("data-reactive-dirty")
}

// Whether a single owned control differs from its server-rendered default.
function fieldDirty(field) {
  if (field.type === "checkbox" || field.type === "radio") {
    return field.checked !== field.defaultChecked
  }
  if (field.tag === "select" || field.options) {
    // Any option whose selected state diverges from the select's RESET state.
    // Guard for a stub/absent options list (degrade to clean). A one-row single
    // select resets to its last defaultSelected option or, with none, to its
    // first enabled one — the browser selects it while its defaultSelected stays
    // false, so a pristine form must not read as dirty (issue #297). A multiple
    // (or size > 1) select resets to exactly its defaultSelected options. An
    // option inside a disabled <optgroup> is disabled too (the browser skips it).
    const options = Array.from(field.options ?? [])
    const single = !field.multiple && !(field.size > 1)
    const reset = options.filter((o) => o.defaultSelected).pop() ?? options.find((o) => !o.closest?.("optgroup")?.disabled && !o.disabled)
    return options.some((o) => o.selected !== (single ? o === reset : o.defaultSelected))
  }
  return field.value !== field.defaultValue
}

// The live dirty-field count, re-derived from the DOM (never a cached snapshot)
// — the source of truth for the warn_unsaved guard's gate.
function dirtyCount(root) {
  const raw = root.getAttribute?.("data-reactive-dirty")
  const n = Number(raw)
  return Number.isFinite(n) && n > 0 ? n : 0
}

// Arm the navigate-away guard (warn_unsaved: true, issue #103). beforeunload
// blocks a real browser unload; turbo:before-visit blocks a Turbo in-app
// navigation (it does NOT fire on restoration visits — the documented gap).
// Both read the LIVE dirty count, so a clean form never blocks. Added through
// connect()'s `listen`, so disconnect() removes exactly them.
function armUnsavedGuard(root, listen) {
  if (typeof window === "undefined" || typeof window.addEventListener !== "function") return

  listen(window, "beforeunload", (event) => {
    if (dirtyCount(root) === 0) return undefined
    // The spec dance: preventDefault + a truthy returnValue triggers the native
    // "leave site?" prompt. The string is legacy (modern browsers show their own
    // copy) but must be non-empty/truthy to arm the dialog.
    event.preventDefault()
    event.returnValue = "You have unsaved changes."
    return event.returnValue
  })
  // Every warn_unsaved root arms its own turbo:before-visit handler, and one
  // visit is one event dispatched to all of them: the first DIRTY root asks,
  // and the rest see the event already asked (issue #298). A clean root never
  // claims the event, so any dirty root on the page can still veto the visit.
  listen(window, "turbo:before-visit", (event) => {
    if (dirtyCount(root) === 0 || askedVisits.has(event)) return
    askedVisits.add(event)
    const ok = typeof window.confirm === "function" ? window.confirm("You have unsaved changes. Leave anyway?") : true
    if (!ok) event.preventDefault?.()
  })
}

// Whether this root owns a clipboard-marked paste trigger (issue #228). The
// ROOT itself counts (a button-only component that mixes on_client(paste_into)
// onto reactive_root), then one scoped query; a NESTED root's triggers are
// its own controller's to gate (issue #15 ownership).
function clipboardGateEnabled(root, core) {
  if (root.getAttribute?.("data-reactive-clipboard")) return true
  const nodes = root.querySelectorAll?.("[data-reactive-clipboard]") ?? []
  for (const el of nodes) if (core.owns(el)) return true
  return false
}

// Set every owned paste trigger's `hidden` from clipboard availability
// (issue #228): available → revealed (the authored `hidden` was only the
// no-dead-button first paint), missing → hidden (insecure context /
// webview). The gate owns the flag on MARKED elements only — nothing else
// is ever touched. A marked ROOT is gated too: when the component IS the
// paste button, hiding the root is exactly "the dead button never shows".
function syncClipboardTriggers(root, core) {
  const available = typeof globalThis.navigator?.clipboard?.readText === "function"
  if (root.getAttribute?.("data-reactive-clipboard")) root.hidden = !available
  for (const el of root.querySelectorAll?.("[data-reactive-clipboard]") ?? []) {
    if (core.owns(el)) el.hidden = !available
  }
}
