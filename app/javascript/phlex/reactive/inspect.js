// The on-demand client inspector (issue #168) — the browser half of the
// debugging toolkit, the client twin of `phlex_reactive:actions` / the MCP tools.
//
// It is a STANDALONE module (the confirm.js / compute.js precedent): it does NOT
// touch the hot-path reactive_controller.js and costs NOTHING until you import
// it. Loaded on demand from the console (the engine pins it), it scans the live
// DOM and maps every reactive root + bound trigger back to the server
// Component#action names — so you can answer "what's reactive on this page, what
// does each control POST, and which component owns it?" without reading source.
//
//   (await import("phlex/reactive/inspect")).report()   // console.table
//   const roots = (await import("phlex/reactive/inspect")).scan()  // data
//
// The server↔client mapping is BY NAME: scan()'s `component` + each trigger's
// `action` are exactly the Component#action identifiers `phlex_reactive:actions`
// and the MCP tools list. The docs page shows the two side by side.
//
// It reads the SAME DOM contract reactive_controller.js writes (roots
// [data-controller~="reactive"] with id + data-reactive-token-value; triggers
// [data-reactive-action-param] with data-action/params/modifiers; client-only
// [data-reactive-ops-param]; computes [data-reactive-compute-reducer-param]; the
// show/filter/text binding families). It never mutates anything — pure read.

// Scan `root` (default the whole document) and return one entry per reactive
// root, deepest-scoped: each trigger is attributed to its NEAREST reactive root,
// so a nested root doesn't double-count its parent's triggers.
export function scan(root = document) {
  const roots = Array.from(root.querySelectorAll('[data-controller~="reactive"]'))
  return roots.map((el) => inspectRoot(el, roots))
}

// console.table the inventory (roots + a flattened trigger table), and return
// the same data scan() does so `report()` is also usable programmatically. Safe
// on an empty document (logs an empty table, throws nothing).
export function report(root = document) {
  const roots = scan(root)
  const console = globalThis.console

  // Guard each console method independently — a host page (or a test harness)
  // may ship a partial console, and report() must never throw over logging.
  if (console && typeof console.log === "function") {
    console.log(`[phlex-reactive] ${roots.length} reactive root(s)`)
  }
  if (console && typeof console.table === "function") {
    console.table(
      roots.map((r) => ({
        id: r.id,
        component: r.component ?? (r.opaque ? "(opaque token)" : null),
        actions: r.triggers.map((t) => t.action).join(", "),
        fields: r.fields.join(", "),
        computes: r.computes.join(", "),
      })),
    )
  }
  return roots
}

// --- one root --------------------------------------------------------------

function inspectRoot(el, allRoots) {
  const token = el.getAttribute("data-reactive-token-value")
  const payload = decodeToken(token)

  return {
    id: el.id || null,
    component: payload.opaque ? null : (payload.c ?? null),
    gid: payload.gid ?? null,
    stateKeys: payload.s ? Object.keys(payload.s) : [],
    tokenVersion: payload.v ?? null,
    opaque: !!payload.opaque,
    status: readStatus(el),
    triggers: ownedTriggers(el, allRoots),
    clientOps: ownedClientOps(el, allRoots),
    computes: ownedComputes(el, allRoots),
    fields: ownedFields(el, allRoots),
    show: ownedShow(el, allRoots),
    text: ownedText(el, allRoots),
    filter: readFilter(el),
  }
}

// The signed identity is base64(JSON)--signature under the Rails 7.1+ JSON
// message serializer. Decode the segment BEFORE the "--", JSON-parse it, and
// unwrap the MessageVerifier envelope ({_rails:{data:…}}) to the {c,gid,s,v}
// payload. Degrade to { opaque: true } on anything that isn't JSON-decodable —
// a Marshal-serialized payload (older apps) simply isn't readable client-side,
// and that's fine: the inspector shows "(opaque token)" rather than throwing.
function decodeToken(token) {
  if (!token) return { opaque: true }

  try {
    const segment = token.split("--")[0]
    const json = atobUtf8(segment)
    const parsed = JSON.parse(json)
    const data = parsed && parsed._rails && parsed._rails.data ? parsed._rails.data : parsed
    if (!data || typeof data !== "object") return { opaque: true }
    return data
  } catch {
    return { opaque: true }
  }
}

// base64 → string. Uses the platform atob; a malformed/urlsafe segment throws,
// which decodeToken catches and reports as opaque.
function atobUtf8(b64) {
  const decode = globalThis.atob || ((s) => Buffer.from(s, "base64").toString("binary"))
  return decode(b64)
}

// The at-a-glance runtime state the controller stamps on the root. Names/flags
// only — never a value that could be sensitive.
function readStatus(el) {
  return {
    error: el.getAttribute("data-reactive-error"),
    busy: el.getAttribute("aria-busy") === "true" || el.hasAttribute("data-reactive-busy"),
    dirty: el.hasAttribute("data-reactive-dirty"),
  }
}

// --- ownership scoping -----------------------------------------------------
//
// An element belongs to a root when its NEAREST reactive-root ancestor is that
// root (matching the controller's own ownership walk). closest() finds the
// nearest ancestor matching the selector; the element itself can be the root
// (for a root that also carries a binding), so we start the walk from the
// element and accept `el` as its own owner.

const ROOT_SELECTOR = '[data-controller~="reactive"]'

function ownedBy(node, root) {
  return node.closest(ROOT_SELECTOR) === root
}

// Query `root` for `selector`, keeping only elements whose nearest reactive
// root IS `root` — so a nested root's matches are excluded here and attributed
// to that inner root instead.
function scopedQuery(root, selector, allRoots) {
  return Array.from(root.querySelectorAll(selector)).filter((node) => ownedBy(node, root))
}

// --- the binding families --------------------------------------------------

function ownedTriggers(root, allRoots) {
  return scopedQuery(root, "[data-reactive-action-param]", allRoots).map((el) => ({
    action: el.getAttribute("data-reactive-action-param"),
    event: eventOf(el.getAttribute("data-action")),
    params: el.getAttribute("data-reactive-params-param"),
    debounce: el.getAttribute("data-reactive-debounce-param"),
    throttle: el.getAttribute("data-reactive-throttle-param"),
    confirm: el.getAttribute("data-reactive-confirm-param"),
    optimistic: el.getAttribute("data-reactive-optimistic-param"),
    loading: el.getAttribute("data-reactive-loading-param"),
  }))
}

// The Stimulus data-action descriptor is "event->controller#method"; the event
// is the part before "->" (a bare "controller#method" has an implicit default
// event, which we report as null).
function eventOf(dataAction) {
  if (!dataAction) return null
  const arrow = dataAction.indexOf("->")
  return arrow === -1 ? null : dataAction.slice(0, arrow)
}

// Client-only op triggers ([data-reactive-ops-param]) — a menu toggle, a DOM op
// chain that never round-trips. Issue #271: the attr holds one on_client
// binding record per call ({on, window?, ops, …}, space-joined when mix-ed),
// reported as one { event, ops } entry each. A legacy [[op, args]] list keeps
// the data-action prefix as its event; an undecodable attr is reported raw.
function ownedClientOps(root, allRoots) {
  return scopedQuery(root, "[data-reactive-ops-param]", allRoots).flatMap((el) => {
    const raw = el.getAttribute("data-reactive-ops-param")
    const event = eventOf(el.getAttribute("data-action"))
    const legacy = parseJson(raw)
    if (Array.isArray(legacy)) return [{ event, ops: legacy }]
    const records = (raw ?? "").split(" ").map(parseJson).filter((r) => r && typeof r === "object" && !Array.isArray(r))
    if (records.length === 0) return [{ event, ops: raw }]
    return records.map((r) => ({ event: r.on ? `${r.on}${r.window ? "@window" : ""}` : event, ops: r.ops }))
  })
}

// JSON.parse that answers undefined instead of throwing — a malformed attr
// must never break the scan.
function parseJson(raw) {
  try {
    return JSON.parse(raw)
  } catch {
    return undefined
  }
}

// Compute reducers bound on this root ([data-reactive-compute-reducer-param]) —
// the client-side data-binding twins of reactive_compute. Report reducer names.
function ownedComputes(root, allRoots) {
  return scopedQuery(root, "[data-reactive-compute-reducer-param]", allRoots).map((el) =>
    el.getAttribute("data-reactive-compute-reducer-param"),
  )
}

// The named form controls the dispatch would collect and send — the same
// selector the controller's field walk uses. Names only, never values.
function ownedFields(root, allRoots) {
  return scopedQuery(root, "input[name], select[name], textarea[name]", allRoots).map((el) =>
    el.getAttribute("name"),
  )
}

// reactive_show bindings: which owned field controls each element's visibility.
function ownedShow(root, allRoots) {
  return scopedQuery(root, "[data-reactive-show-field]", allRoots).map((el) => ({
    field: el.getAttribute("data-reactive-show-field"),
    equals: el.getAttribute("data-reactive-show-equals"),
    not: el.getAttribute("data-reactive-show-not"),
    in: el.getAttribute("data-reactive-show-in"),
  }))
}

// reactive_text spans (data-reactive-text=<name>) the client writes via
// textContent — report the binding names.
function ownedText(root, allRoots) {
  return scopedQuery(root, "[data-reactive-text]", allRoots).map((el) =>
    el.getAttribute("data-reactive-text"),
  )
}

// reactive_filter lives on the ROOT itself (the input/option/group/empty
// selectors it narrows client-side). Null when the root declares no filter.
function readFilter(el) {
  const input = el.getAttribute("data-reactive-filter-input")
  if (!input) return null
  return {
    input,
    option: el.getAttribute("data-reactive-filter-option"),
    group: el.getAttribute("data-reactive-filter-group"),
    empty: el.getAttribute("data-reactive-filter-empty"),
  }
}
