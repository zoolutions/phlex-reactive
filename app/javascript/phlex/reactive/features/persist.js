// Client-only drafts (issue #239) — reactive_persist. A FEATURE MODULE of the
// reactive controller (issue #275): the core imports it only when a root on
// the page declares data-reactive-persist, or when a persist_state /
// persist_clear client op runs.
//
// A root that declares
// data-reactive-persist='{"key","ttl","debounce"[,"fields"][,"restore"]}'
// keeps a localStorage draft of every persistable OWNED control (write on
// input/change, restore on connect, clear on a successful submit / TTL / the
// persist_clear op). The storage layer is MODULE-LEVEL and keyed on the root
// element — the per-root connect/write path and the persist_state /
// persist_clear client ops (which receive only the element) share it. Every
// storage access is try/catch'd: a private window, a quota error or blocked
// storage degrades to "no draft", never a thrown bootstrap. Nothing here
// leaves the browser: no token, no POST, and phlex-reactive never writes
// markup into the DOM: native controls are replayed via
// .value/.checked/.selected, a bare [contenteditable] via textContent, and a
// rich editor (lexxy-editor, trix-editor — issue #241) through its OWN
// `value` setter, the same sanitizing import path a paste takes. Never
// innerHTML.
//
// The feature contract (reactive_controller.js "Feature modules"):
//   connect(controller, core)     once per root connection, after the import
//   disconnect(controller, core)  before the core's own teardown
// `core` is the controller's handle for features: core.emit(name, detail)
// raw-dispatches a lifecycle event from the root; core.reseed() re-runs the
// connect-time seeds that read field values (dirty baseline, show bindings,
// on-complete arming, filter, tags, nested JSON, compute).
//
// TIMING. The restore used to run inside connect(), before those seeds. It
// now runs when this module has arrived — a moment later on a first visit,
// the same task on any later one — so after writing the draft into the
// controls it asks the core to reseed. Until the restore has run the root
// writes no draft (a keystroke typed in that window is kept in its field and
// drafted by the next one), the core holds the root's action requests back
// (they would post the server's blanks), and a persist_state op waits (its
// snapshot would overwrite the draft with those blanks). The core also stands
// in for the submit listener below while the import is on its way (forget()).

const PERSIST_VERSION = 1
const PERSIST_PREFIX = "phlex-reactive:persist:"
// Never persisted regardless of author intent: no server default to restore
// into (hidden, file), secrets (password), and non-value controls.
const PERSIST_EXCLUDED_TYPES = new Set(["hidden", "file", "password", "submit", "button", "reset", "image"])
const PERSIST_NO_VALUE = Symbol("persist-no-value")
const PERSIST_STATE_ATTR = "data-reactive-persist-state"
// The editor query the core's #collectFields reads (minus the [name] guard —
// an editor's name may live on its IDL `name` getter: Trix's `input=`-paired
// hidden input). The core holds the same two constants (EDITOR_SELECTOR,
// EDITOR_TAGS); a feature never imports the core, so they are repeated here
// and spec/javascript/reactive_persist.test.js pins that they stay equal.
export const PERSIST_EDITOR_SELECTOR =
  ":is(lexxy-editor, trix-editor, [contenteditable=''], [contenteditable=true], [contenteditable=plaintext-only])"
export const PERSIST_EDITOR_TAGS = new Set(["lexxy-editor", "trix-editor"])
// An editor's own chrome: Lexxy renders its toolbar (a `lexxy-code-language`
// select, the link dialog's `href` input) INSIDE <lexxy-editor>, Trix as a
// sibling <trix-toolbar>. Those are named native controls that are not the
// user's fields — never drafted, never restored into.
const PERSIST_EDITOR_CHROME = "lexxy-editor, trix-editor, trix-toolbar"
// The editors' own bubbling change events — the keystroke signal for the
// draft write, since neither lets its contenteditable's native `input` bubble.
const PERSIST_EDITOR_CHANGE_EVENTS = ["lexxy:change", "trix-change"]
// "Is this editor empty" when it exposes no predicate of its own (Lexxy's
// `isEmpty`, Trix's `editor.getDocument().isEmpty()`): Lexxy's own empty
// list plus the Trix / contenteditable empties. Exact strings, no HTML
// parsing — an attachment-only body stays non-blank.
const PERSIST_EMPTY_HTML = new Set(["", "<p></p>", "<p><br></p>", "<div><br></div>"])
// Once-per-root guards: a malformed payload warns once; the storage-failure
// and editor-restore dev notes (debug mode only) print once each.
const persistPayloadWarned = new WeakSet()
const persistFailureNoted = new WeakSet()
const persistEditorNoted = new WeakSet()

// The root's parsed payload, or null (undeclared / malformed → warned once).
// A control-level "off" (reactive_persist_skip) is never a root payload.
function persistPayload(root) {
  const raw = root?.getAttribute?.("data-reactive-persist")
  if (!raw || raw === "off") return null
  try {
    const payload = JSON.parse(raw)
    if (payload && typeof payload === "object" && typeof payload.key === "string" && payload.key !== "") return payload
  } catch {
    // fall through to the warn
  }
  if (!persistPayloadWarned.has(root)) {
    persistPayloadWarned.add(root)
    console.warn(`[phlex-reactive] malformed reactive_persist payload ${JSON.stringify(raw)} — persistence disabled`)
  }
  return null
}

function persistStorage() {
  try {
    return typeof localStorage === "undefined" ? null : localStorage
  } catch {
    return null // the accessor itself can throw (blocked site data)
  }
}

// The dev lens for "why did nothing come back": ONLY under data-reactive-debug
// (Phlex::Reactive.debug), once per root — production stays silent.
function persistNoteFailure(root, error) {
  if (root?.getAttribute?.("data-reactive-debug") !== "true" || persistFailureNoted.has(root)) return
  persistFailureNoted.add(root)
  console.info(`[phlex-reactive] reactive_persist: storage unavailable — draft skipped (${error?.name ?? error})`)
}

function persistKeyFor(payload) {
  return PERSIST_PREFIX + payload.key
}

// Read + validate the draft: null when absent, unparsable, another schema
// version, or expired (an expired draft is REMOVED on read). Returns
// { fields, state } with state null when the draft carries none.
function persistRead(root, payload) {
  const store = persistStorage()
  if (!store) return null
  let raw
  try {
    raw = store.getItem(persistKeyFor(payload))
  } catch (error) {
    persistNoteFailure(root, error)
    return null
  }
  if (!raw) return null
  let draft
  try {
    draft = JSON.parse(raw)
  } catch {
    return null
  }
  if (!draft || typeof draft !== "object" || draft.v !== PERSIST_VERSION) return null
  const ttlMs = Number(payload.ttl) * 1000
  if (!(Number(draft.savedAt) + ttlMs > Date.now())) {
    persistRemove(root, payload)
    return null
  }
  const fields = draft.fields && typeof draft.fields === "object" ? draft.fields : {}
  const state = draft.state && typeof draft.state === "object" ? draft.state : null
  return { fields, state }
}

function persistWrite(root, payload, { fields, state }) {
  const store = persistStorage()
  if (!store) return false
  const draft = { v: PERSIST_VERSION, savedAt: Date.now(), fields }
  if (state) draft.state = state
  try {
    store.setItem(persistKeyFor(payload), JSON.stringify(draft))
    return true
  } catch (error) {
    persistNoteFailure(root, error)
    return false
  }
}

function persistRemove(root, payload) {
  root?.removeAttribute?.(PERSIST_STATE_ATTR)
  const store = persistStorage()
  if (!store) return
  try {
    store.removeItem(persistKeyFor(payload))
  } catch (error) {
    persistNoteFailure(root, error)
  }
}

// The persistable controls this root OWNS (#15: a nested reactive root's
// controls are its own), minus the excluded types, the reactive_persist_skip
// marker, and — when `fields` narrows the set — any undeclared name. Each
// entry is { el, name, kind } with kind "native" (input/select/textarea),
// "editor" (lexxy-editor / trix-editor) or "contenteditable" (a bare named
// editable element) — issue #241.
function persistControls(root, payload) {
  const allow = Array.isArray(payload.fields) ? new Set(payload.fields) : null
  const out = []
  const owned = (el) =>
    el.closest('[data-controller~="reactive"]') === root && el.getAttribute("data-reactive-persist") !== "off"
  for (const el of root.querySelectorAll("input[name], select[name], textarea[name]")) {
    if (!owned(el) || PERSIST_EXCLUDED_TYPES.has(el.type) || el.closest(PERSIST_EDITOR_CHROME)) continue
    if (allow && !allow.has(el.name)) continue
    out.push({ el, name: el.name, kind: "native" })
  }
  for (const el of root.querySelectorAll(PERSIST_EDITOR_SELECTOR)) {
    if (!owned(el)) continue
    const name = persistEditorName(el)
    if (!name || (allow && !allow.has(name))) continue
    out.push({ el, name, kind: PERSIST_EDITOR_TAGS.has(el.localName) ? "editor" : "contenteditable" })
  }
  return out
}

// The attribute first (Lexxy, a bare contenteditable — which has no `name`
// IDL property at all), then the IDL getter (Trix resolves it through its
// `input=`-paired hidden input, which is itself excluded as type=hidden).
function persistEditorName(el) {
  return el.getAttribute("name") || (typeof el.name === "string" && el.name) || null
}

// An editor is READY once its custom element has upgraded and connected: only
// then does it expose the string `value` accessor (Lexxy's setter throws
// before connectedCallback created its editor; Trix's discards the value).
function persistEditorReady(el) {
  return typeof el.value === "string"
}

// Ask the editor whether it is empty (Lexxy `isEmpty`; Trix
// `editor.getDocument().isEmpty()`), else the exact-string fallback. An
// attachment-only server body is therefore NON-blank and never overwritten.
function persistEditorBlank(el) {
  if (typeof el.isEmpty === "boolean") return el.isEmpty
  const doc = el.editor?.getDocument?.()
  if (typeof doc?.isEmpty === "function") return doc.isEmpty()
  return PERSIST_EMPTY_HTML.has(el.value.trim())
}

// The editor-restore dev lens: ONLY under data-reactive-debug, once per root.
function persistNoteEditorFailure(root, name, error) {
  if (root?.getAttribute?.("data-reactive-debug") !== "true" || persistEditorNoted.has(root)) return
  persistEditorNoted.add(root)
  console.info(
    `[phlex-reactive] reactive_persist: could not restore editor ${JSON.stringify(name)} — ${error?.message ?? error}`,
  )
}

function persistSelectMultiple(el) {
  return el.tagName === "SELECT" && el.multiple
}

// How many controls can contribute a value under each `[]` name, counted the
// way persistSnapshot fills the slot — a radio is the exception there and here.
// A group of ONE is unambiguous: its single entry can only have come from that
// control.
function persistGroupSizes(controls) {
  const sizes = new Map()
  for (const { el, name } of controls) {
    if (el.type === "radio" || !String(name).endsWith("[]")) continue
    sizes.set(name, (sizes.get(name) ?? 0) + 1)
  }
  return sizes
}

// The value a control that cannot pick its own entry out of a list may take.
// A list belongs to a `[]` group, and in a group of two or more nothing says
// which entry came from which control — restoring it would paste
// "freeform,news" into a text field. A group of ONE has no such ambiguity, and
// refusing it would silently drop the draft of a plain field whose name merely
// ends in `[]` (a list JS maintains), which worked before groups existed.
// Returns PERSIST_NO_VALUE when the control must keep what the server rendered.
function persistGenericValue(value, name, sizes) {
  if (!Array.isArray(value)) return value
  if (sizes.get(name) !== 1 || value.length !== 1) return PERSIST_NO_VALUE

  return value[0]
}

// Snapshot the owned controls: radio → the checked value (null when the group
// has none, so a restore leaves it alone), checkbox → checked, multi-select →
// the selected values, a rich editor → its serialized `value` (omitted while
// the element hasn't upgraded — never a phantom ""), a bare contenteditable →
// its textContent, else .value. Mirrors the core's #collectFields reads.
function persistSnapshot(root, payload) {
  const fields = {}
  // A `[]` name is a group for every control that can contribute a value —
  // checkboxes, selects, text inputs, editors and contenteditables all append
  // to one array, mirroring #collectFields. The one exception is a RADIO group,
  // which means "pick one" and keeps its single value with or without the
  // suffix, exactly as the collector treats it.
  //
  // Reading the slot without this (fields[name] ?? []) breaks as soon as a
  // non-checkbox shares the group's name: a text input or an editor leaves a
  // string there, `.push` on it throws inside the draft write, and that write
  // is swallowed — the root then persists nothing at all, silently. Editors
  // are collected AFTER the native controls, so they always land last.
  const groupSlot = (name) => {
    const existing = fields[name]
    return Array.isArray(existing) ? existing : (fields[name] = [])
  }
  for (const { el, name, kind } of persistControls(root, payload)) {
    const group = String(name).endsWith("[]")
    if (kind === "editor") {
      if (persistEditorReady(el)) {
        if (group) groupSlot(name).push(el.value)
        else fields[name] = el.value
      }
    } else if (kind === "contenteditable") {
      const text = el.textContent ?? ""
      if (group) groupSlot(name).push(text)
      else fields[name] = text
    } else if (el.type === "radio") {
      if (el.checked) fields[name] = el.value
      else if (!Object.hasOwn(fields, name)) fields[name] = null
    } else if (el.type === "checkbox") {
      // A `[]` group drafts the list of ticked values, mirroring #collectFields
      // (issue #258). Without this the boxes overwrote each other and the draft
      // held one boolean, which the restore then applied to every box of the
      // group. A lone checkbox keeps the boolean it has always been.
      if (group) {
        const slot = groupSlot(name)
        if (el.checked) slot.push(el.value)
      } else {
        fields[name] = el.checked
      }
    } else if (persistSelectMultiple(el)) {
      const selected = [...el.options].filter((o) => o.selected).map((o) => o.value)
      if (group) groupSlot(name).push(...selected)
      else fields[name] = selected
    } else if (group) {
      groupSlot(name).push(el.value)
    } else {
      fields[name] = el.value
    }
  }
  return fields
}

// Replay the draft into the owned controls. Default (restore: blank): a
// control the server rendered NON-BLANK keeps its value — a 422 re-render's
// submitted values beat an older draft. restore: "always" lets the draft win.
// Values land via .value/.checked/.selected, textContent, or the editor's own
// `value` setter — never HTML written by us.
function persistApply(root, payload, fields) {
  const always = payload.restore === "always"
  const controls = persistControls(root, payload)
  // Which group names the SERVER rendered with a box already ticked. Computed
  // BEFORE the loop on purpose: the loop writes `checked`, so asking this
  // question from inside it would read THIS restore's own work — the first box
  // it ticks makes every later box of the same group look server-rendered, and
  // a draft of two values comes back as one. The radio branch below asks the
  // same question inline and stays correct only because a radio group holds a
  // single value.
  const groupSizes = persistGroupSizes(controls)
  const serverTicked = new Set()
  for (const control of controls) {
    if (control.kind === "native" && control.el.type === "checkbox" && control.el.checked) {
      serverTicked.add(control.name)
    }
  }
  for (const { el, name, kind } of controls) {
    if (!Object.hasOwn(fields, name)) continue
    let value = fields[name]
    if (value === null || value === undefined) continue
    // A multi-select reads a list by matching option values, which is only
    // sound when the list is ITS list. In a group with another contributor the
    // entries are mixed, and a text value that happens to equal an option
    // would select it — measured, a draft of ["blue","freitext"] from a select
    // plus a text field selected both options. `?? 0` because a name without
    // the suffix is not in the map at all, and a plain `<select multiple
    // name="colors">` must keep restoring.
    if (Array.isArray(value) && persistSelectMultiple(el) && (groupSizes.get(name) ?? 0) > 1) continue

    // An array belongs to a `[]` group, and only a control that can pick ITS
    // entry out of the list may read it: a checkbox matches by value, a
    // multi-select by option. Everything else — editors, contenteditables,
    // text inputs — keeps what the server rendered, because the list does not
    // record which entry came from which control. This sits ABOVE the branch
    // chain on purpose: below the editor branch it would never fire for the
    // very controls that land last in the snapshot.
    if (Array.isArray(value) && !(el.type === "checkbox" || persistSelectMultiple(el))) {
      value = persistGenericValue(value, name, groupSizes)
      if (value === PERSIST_NO_VALUE) continue
    }
    // The mirror, for a draft written BEFORE a group was drafted as a list
    // (#258): there `features[]` held ONE boolean, and applying it here ticks
    // every box of the group — precisely the state this fix removes, for as
    // long as the draft lives (default ttl 7 days). A group key that is not a
    // list is stale by definition, so the control keeps what the server
    // rendered and the next snapshot overwrites the key. It reads for a
    // multi-select too: 0.13.2 wrote last-writer-wins per name, so a checkbox
    // in a mixed group could leave its boolean under the select's name, and
    // under `restore: "always"` the select would then deselect everything —
    // `wanted` being Set{"true"} matches no option. Asking for the `[]` suffix
    // is what leaves a lone `gift` checkbox on the boolean it has always held —
    // and scoping the rule to the one key whose meaning changed is why
    // PERSIST_VERSION stays at 1: bumping it would also throw away the drafted
    // prose of every form that has no checkbox group at all.
    if ((el.type === "checkbox" || persistSelectMultiple(el)) && String(name).endsWith("[]") && !Array.isArray(value)) {
      continue
    }
    if (kind === "editor") {
      persistApplyEditor(root, el, name, value, always)
    } else if (kind === "contenteditable") {
      if (!always && (el.textContent ?? "").trim() !== "") continue
      el.textContent = String(value)
    } else if (el.type === "radio") {
      if (!always && controls.some((c) => c.kind === "native" && c.el.type === "radio" && c.name === name && c.el.checked)) continue
      el.checked = el.value === String(value)
    } else if (el.type === "checkbox" && Array.isArray(value)) {
      // A drafted group ticks exactly the boxes it held. One box the SERVER
      // rendered ticked means it had a say, and the draft yields for the whole
      // group.
      if (!always && serverTicked.has(name)) continue
      el.checked = value.map(String).includes(el.value)
    } else if (el.type === "checkbox") {
      if (!always && el.checked) continue
      el.checked = Boolean(value)
    } else if (persistSelectMultiple(el)) {
      if (!always && [...el.options].some((o) => o.selected)) continue
      const wanted = new Set((Array.isArray(value) ? value : [value]).map(String))
      for (const o of el.options) o.selected = wanted.has(o.value)
    } else {
      if (!always && el.value !== "") continue
      el.value = String(value)
    }
  }
  persistDeferEditors(root, payload, fields)
}

// A ready editor takes the value through its own setter; the setter is the
// editor's sanitizing import (Trix HTMLParser, Lexxy $generateNodesFromDOM +
// sanitizer). A throw (Lexxy before its editor exists) never escapes connect.
function persistApplyEditor(root, el, name, value, always) {
  // A list never reaches here: both callers resolve it through
  // persistGenericValue first — the group of two or more has no mapping back to
  // this editor, the group of one does. Belt and braces, because this is the
  // one apply path with a second entry point.
  if (Array.isArray(value)) return
  if (!persistEditorReady(el)) return // not upgraded yet — persistDeferEditors re-applies after define
  if (!always && !persistEditorBlank(el)) return
  try {
    el.value = String(value)
  } catch (error) {
    persistNoteEditorFailure(root, name, error)
  }
}

// An editor whose custom element is not defined yet (Trix defines its elements
// in a setTimeout after load; a lazily imported Lexxy) cannot take a value now.
// Re-apply per TAG once it is defined — re-querying the controls (the upgrade
// may replace the node) and re-checking restore: blank at that moment — unless
// the root has left the document meanwhile.
function persistDeferEditors(root, payload, fields) {
  const registry = globalThis.customElements
  if (typeof registry?.whenDefined !== "function") return
  const pending = new Set()
  for (const el of root.querySelectorAll("lexxy-editor, trix-editor")) {
    if (!persistEditorReady(el) && !registry.get?.(el.localName)) pending.add(el.localName)
  }
  const always = payload.restore === "always"
  for (const tag of pending) {
    registry.whenDefined(tag).then(() => {
      if (!root.isConnected) return
      const deferred = persistControls(root, payload)
      const sizes = persistGroupSizes(deferred)
      for (const { el, name, kind } of deferred) {
        if (kind !== "editor" || el.localName !== tag || !Object.hasOwn(fields, name)) continue
        const value = persistGenericValue(fields[name], name, sizes)
        if (value === null || value === undefined || value === PERSIST_NO_VALUE) continue
        persistApplyEditor(root, el, name, value, always)
      }
    })
  }
}

// The persist_state op body: merge a FLAT bag into the root's draft (re-
// snapshotting the fields so the write is whole) and mirror it on the root.
// A root without reactive_persist is a call-site bug — warn and skip.
function persistWriteState(root, state) {
  const payload = persistPayload(root)
  if (!payload) {
    console.warn("[phlex-reactive] persist_state on a root without reactive_persist — skipped")
    return
  }
  if (!state || typeof state !== "object") return
  const current = persistRead(root, payload)
  const merged = { ...(current?.state ?? {}), ...state }
  if (persistWrite(root, payload, { fields: persistSnapshot(root, payload), state: merged })) {
    root.setAttribute?.(PERSIST_STATE_ATTR, JSON.stringify(merged))
  }
}

function persistClearRoot(root) {
  const payload = persistPayload(root)
  if (payload) persistRemove(root, payload)
}

// --- Per-root wiring -------------------------------------------------------

// controller -> { payload, timer, onInput, onChange, onSubmitEnd } for the
// connection this feature is wired to.
const wired = new WeakMap()
// Root elements whose restore has run (and whose controller is connected).
const restored = new WeakSet()
// root element -> persist ops that arrived before its restore.
const waiting = new WeakMap()

// Restore the draft into the owned controls, expose the state bag, announce,
// then arm the write listeners. The restore reads ONCE and never writes back:
// nothing is wired until it has completed, so no listener can clobber the
// draft with the server's blanks. The submit-end listener is DOCUMENT-level
// (the event fires on the form, which is usually an ANCESTOR of this root)
// and gated on the form containing this root.
export function connect(controller, core) {
  const root = controller.element
  const payload = persistPayload(root)
  if (!payload) return
  const draft = persistRead(root, payload)
  if (draft) {
    persistApply(root, payload, draft.fields)
    if (draft.state) root.setAttribute?.(PERSIST_STATE_ATTR, JSON.stringify(draft.state))
    core.emit("reactive:persist-restored", { key: payload.key, fields: draft.fields, state: draft.state ?? {} })
    // The connect-time seeds ran on the server's values; they read fields.
    core.reseed()
  }

  const state = { payload, timer: null }
  state.onInput = () => scheduleWrite(root, state)
  state.onChange = () => writeNow(root, state)
  state.onSubmitEnd = (event) => submitEnd(root, state, event)
  root.addEventListener?.("input", state.onInput)
  root.addEventListener?.("change", state.onChange)
  // Rich editors (#241): Lexical and Trix swallow the native `input` of
  // their contenteditable, so their own bubbling change events are the
  // keystroke signal — same trailing-edge debounce as `input`.
  for (const event of PERSIST_EDITOR_CHANGE_EVENTS) root.addEventListener?.(event, state.onInput)
  document.addEventListener?.("turbo:submit-end", state.onSubmitEnd)
  wired.set(controller, state)

  restored.add(root)
  const ops = waiting.get(root)
  waiting.delete(root)
  for (const op of ops ?? []) op()
}

// Flush a pending write while the fields are still readable (Turbo
// disconnects before leaving the page — a fast visit otherwise loses the last
// keystrokes), then drop every listener.
export function disconnect(controller) {
  const root = controller.element
  const state = wired.get(controller)
  restored.delete(root)
  waiting.delete(root)
  if (!state) return
  wired.delete(controller)
  if (state.timer !== null) writeNow(root, state)
  root.removeEventListener?.("input", state.onInput)
  root.removeEventListener?.("change", state.onChange)
  for (const event of PERSIST_EDITOR_CHANGE_EVENTS) root.removeEventListener?.(event, state.onInput)
  document.removeEventListener?.("turbo:submit-end", state.onSubmitEnd)
}

// Trailing-edge debounce for keystrokes — ONE timer per root (a snapshot is
// a full pass, so per-field timers would only multiply writes).
function scheduleWrite(root, state) {
  const ms = Number(state.payload.debounce) || 0
  if (ms <= 0) return writeNow(root, state)
  if (state.timer !== null) clearTimeout(state.timer)
  state.timer = setTimeout(() => {
    state.timer = null
    writeNow(root, state)
  }, ms)
}

// Snapshot every persistable owned control and write. Re-reads the current
// draft first so a state bag written by persist_state survives the write
// (the bag lives in storage, not on the connection — the op has none).
function writeNow(root, state) {
  if (state.timer !== null) {
    clearTimeout(state.timer)
    state.timer = null
  }
  const current = persistRead(root, state.payload)
  persistWrite(root, state.payload, { fields: persistSnapshot(root, state.payload), state: current?.state ?? null })
}

// A SUCCESSFUL Turbo form submission of the form that owns this root
// forgets the draft. tagName (not instanceof) so a cross-realm form counts.
function submitEnd(root, state, event) {
  if (!event?.detail?.success) return
  const form = event.target
  if (form?.tagName !== "FORM" || typeof form.contains !== "function") return
  if (!form.contains(root)) return
  // Drop a pending keystroke write too — the disconnect flush that follows
  // Turbo's redirect visit would otherwise resurrect the just-cleared draft.
  if (state.timer !== null) {
    clearTimeout(state.timer)
    state.timer = null
  }
  persistRemove(root, state.payload)
}

// --- The persist_state / persist_clear client ops --------------------------

// A root whose controller has connected but whose restore has not run yet
// still shows the server's blanks: an op that snapshots or clears it now
// would destroy the draft the restore is about to read. Such an op waits for
// the restore. Any other root (never connected, or restored) runs it at once.
function afterRestore(root, op) {
  const connected = globalThis[Symbol.for("phlex-reactive.early")]?.connected
  if (!connected?.has(root) || restored.has(root) || !persistPayload(root)) return op()
  waiting.set(root, [...(waiting.get(root) ?? []), op])
}

export function writeState(root, state) {
  afterRestore(root, () => persistWriteState(root, state))
}

export function clearRoot(root) {
  afterRestore(root, () => persistClearRoot(root))
}

// The form around `root` was submitted successfully while this module was
// still loading (the core's stand-in listener saw it): forget the draft NOW,
// not after a restore — the restore that follows then finds nothing, and a
// root that has already left takes no stale draft into its next visit.
export function forget(root) {
  persistClearRoot(root)
}
