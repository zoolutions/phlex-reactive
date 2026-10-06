// Deferred and lazy renders — a FEATURE MODULE of the reactive controller
// (issue #275). The core imports it only when a root on the page is a
// reactive_lazy shell (it carries data-reactive-defer-token, -defer-src,
// -lazy-on or -lazy-visible), when a morph turns a root into one, or when a
// `reactive:defer` stream arrives.
//
// Three things live here:
//
//   reply.defer (issue #165)      the client half: the server's reply carries a
//     `<turbo-stream action="reactive:defer" target="<id>">` directive and the
//     real render reaches the SAME actor later — via a parallel fetch (pull) or
//     a pgbus one-shot stream (push).
//   reactive_lazy (issue #165)    a shell that fetches its real content when it
//     connects; with cache: (issue #277) from a stable, privately cacheable URL.
//   reactive_lazy(on:) (issue #276) a shell that loads on an event, or when it
//     scrolls into view.
//
// Everything about a delivery is MODULE-level, deliberately OFF the
// per-controller request queue: the whole point is that the expensive segment
// never blocks the actor's next action.
//
// Supersession is the correctness core: pendingDefers keys one in-flight
// delivery per target id. A newer directive for the same target aborts the
// older fetch (or removes the older stream source), and an arrival applies
// ONLY while its entry is still current — so a fast typist's debounced
// keystrokes can never paint stale totals over fresh ones.
//
// The feature contract (reactive_controller.js "Feature modules"):
//   install(shared)                     once, when the module has loaded
//   connect(controller, core, morphed)  per root connection
//   disconnect(controller)              before the core's own teardown
// A feature never imports the core. `shared` carries the core's single-
// instance counters (the activity signal, the request totals); `core` is the
// per-controller handle: core.emit, core.proceed (the action pipeline) and
// core.forgetToken.

// The core's module-level counters, handed over once by install(): there must
// be ONE activity count and one request total on a page, whoever adds to them.
let shared

export function install(given) {
  shared = given
}

const pendingDefers = new Map()

// Register/drop a target's pending defer entry, keeping the GLOBAL activity
// counter (issue #201) balanced against the Map's ACTUAL key presence — a defer
// is one in-flight reactive operation for as long as its registry entry lives.
// Keying enter/exit on the presence TRANSITION (not the raw call) means a
// re-set of an already-present key, or a delete of an absent one, can never
// unbalance the count. Both the fetch (pull) and stream (push) lane route their
// registry mutations through here, so the push lane is counted correctly even
// though its DOM pending markers clear by a node swap, not clearDeferPending.
function setPendingDefer(targetId, entry) {
  const isNew = !pendingDefers.has(targetId)
  pendingDefers.set(targetId, entry)
  if (isNew) shared.enter()
}

function deletePendingDefer(targetId) {
  if (pendingDefers.delete(targetId)) shared.exit()
}

// Test seam: clear the module-level registry between unit tests. Also resets
// the one-shot settle-listener guard so a test's fresh document re-registers
// the turbo:before-stream-render settler. Does NOT touch the activity counter —
// resetReactiveActivity is its own seam (the two are reset together in tests).
export function resetReactiveDefers() {
  pendingDefers.clear()
  deferStreamSettleRegistered = false
}

// Test seam: the `via` of a target's pending defer entry (or undefined) — lets
// tests assert an entry was SETTLED (dropped) on arrival without exposing the
// Map. Not used by the runtime.
export function pendingDeferVia(targetId) {
  return pendingDefers.get(targetId)?.via
}

let deferStreamSettleRegistered = false

// The body of the `reactive:defer` Turbo stream action. The core registers the
// action itself (a stream can arrive on a page that has not loaded this module
// yet) and hands each <turbo-stream> element over once the module is here —
// its attributes outlive Turbo removing the element from the document.
export function streamAction(streamEl) {
  registerSettleOnRender()
  const target = streamEl.getAttribute("target")
  if (!target) return
  if (streamEl.getAttribute("data-reactive-defer-via") === "stream") {
    startStreamDefer(target, streamEl)
    return
  }
  const token = streamEl.getAttribute("data-reactive-defer-token")
  if (!token) return
  startFetchDefer(target, token)
}

// Settle a STREAM-lane pendingDefers entry when its arrival lands: the job's
// broadcast is a turbo-stream that replaces the target and then removes the
// source. A document-level turbo:before-stream-render hook drops the Map
// entry the moment that removal renders — so the entry never outlives the
// delivery (the fetch lane settles inline; the stream lane's arrival is a
// broadcast nothing here awaits, so it needs this hook). Registered once; a
// no-op without document.
function registerSettleOnRender() {
  if (deferStreamSettleRegistered || typeof document === "undefined" || !document.addEventListener) return
  deferStreamSettleRegistered = true
  document.addEventListener("turbo:before-stream-render", settleStreamDeferOnRender)
}

// Drop a stream-lane pendingDefers entry when a turbo-stream targets its
// source element, reactive-defer-src-<target>: only the job's broadcast does
// (every payload, render or cleanup, ends with that removal). A stream to the
// target ITSELF settles nothing (issue #292): an unrelated update of #<target>
// between the enqueue and the job's broadcast is not the delivery. Pure Map
// cleanup — the DOM apply is Turbo's; this only releases our bookkeeping.
function settleStreamDeferOnRender(event) {
  const target = event.target?.getAttribute?.("target")
  if (!target?.startsWith("reactive-defer-src-")) return
  const targetId = target.slice("reactive-defer-src-".length)
  if (pendingDefers.get(targetId)?.via === "stream") deletePendingDefer(targetId)
}

// The pull lane: mark the target pending and fetch the real render, in
// parallel with everything else the page is doing. `source` is what to fetch:
// a signed defer token (a string — POSTed to the defer endpoint) or `{ src }`,
// a `reactive_lazy cache:` component's stable fragment URL (issue #277) —
// fetched with a plain GET so the browser's private HTTP cache can answer it.
// Returns the fetch's promise (it never rejects), or undefined when skipped.
function startFetchDefer(targetId, source) {
  const el = document.getElementById(targetId)
  if (!el) {
    console.warn(`[phlex-reactive] reactive:defer target #${targetId} is not on the page — skipped`)
    return
  }
  supersedeDefer(targetId)
  markDeferPending(el)
  const entry = { via: "fetch", abort: new AbortController(), timedOut: false }
  setPendingDefer(targetId, entry)
  return performDeferFetch(targetId, entry, source)
}

// The fetch() arguments for a pull-lane source. A fragment URL is a GET with
// no CSRF token and no body: rendering has no side effects, and anything that
// varied per request would defeat the cache (the response is keyed on the URL,
// Vary: Cookie). The default cache mode is what we want — reuse a fresh copy,
// revalidate a stale one with its ETag. A fallback GET (see
// fallbackFragmentSource) is the exception: the server never issued that URL,
// so its reply is kept out of the HTTP cache.
function deferRequest(source, signal) {
  if (typeof source !== "string") {
    const init = { headers: { Accept: "text/vnd.turbo-stream.html" }, credentials: "same-origin", signal }
    if (source.fallback) init.cache = "no-store"
    return [source.src, init]
  }
  return [
    deferPath(),
    {
      method: "POST",
      headers: {
        Accept: "text/vnd.turbo-stream.html",
        "Content-Type": "application/json",
        "X-CSRF-Token": deferCsrfToken(),
      },
      body: JSON.stringify({ token: source }),
      credentials: "same-origin",
      signal,
    },
  ]
}

// A `cache:` shell's fragment URL as a pull-lane source, or undefined (no
// URL). Unlike a token (opaque, POSTed to one fixed path) this is a URL read
// from the DOM, and its response is rendered as a turbo-stream — so it is
// fetched ONLY when it resolves to this origin's fragment endpoint. Markup that
// smuggled the attribute in (user HTML that kept data-* attributes) must not be
// able to point the client at another origin, an upload, or any other
// same-origin path. A refused URL is logged and loads through the fallback GET
// below (issue #306); with no fallback the shell is failed, and this answers
// undefined.
function fragmentSource(el) {
  const src = el.getAttribute?.("data-reactive-defer-src")
  if (!src) return
  if (isFragmentUrl(src)) return { src }
  console.error(refusedFragmentMessage(src))
  return fallbackFragmentSource(src) || failRefusedFragment(el)
}

function refusedFragmentMessage(src) {
  return (
    `[phlex-reactive] refused data-reactive-defer-src="${src}" — it is not under this app's fragment path ` +
    `(${fragmentPath()}). If you changed Phlex::Reactive.fragment_path, add ` +
    '<meta name="phlex-reactive-fragment-path" content="…your path…"> to the layout <head>.'
  )
}

// The way a shell with a refused URL still loads (issue #306): a GET of the
// SAME signed id under the fragment path this client knows — so the request
// can only ever reach this app's own fragment endpoint, which verifies the id.
// It catches an app that renders absolute fragment URLs for another host
// name, or moved fragment_path without the meta (then the GET answers 404 and
// the shell fails with retry(), like any failed load). Undefined when the
// URL's last path segment cannot be a fragment id.
function fallbackFragmentSource(src) {
  let url
  try {
    url = new URL(src, window.location.href)
  } catch {
    return
  }
  const id = url.pathname.split("/").pop()
  const fallback = `${fragmentPath()}/${id}${url.search}`
  // Held to the same check as any fragment URL, whatever the meta says.
  if (/^[\w-]+$/.test(id) && isFragmentUrl(fallback)) return { src: fallback, fallback: true }
}

// A shell whose URL was refused and has no fallback has no other way to load,
// so it must not shimmer forever: clear pending, mark the root, and emit the same
// bubbling reactive:error a failed load does (no retry() — the URL won't change).
// It supersedes whatever load is in flight for this root first (issue #293):
// that load was for the shell this morph replaced, and its late arrival must
// neither paint over this one nor clear its error marker.
function failRefusedFragment(el) {
  supersedeDefer(el.id)
  clearDeferPending(el)
  el.setAttribute("data-reactive-error", "defer")
  el.dispatchEvent(
    new CustomEvent("reactive:error", {
      bubbles: true,
      composed: true,
      detail: { kind: "defer", target: el.id, reason: "refused-url" },
    }),
  )
}

function isFragmentUrl(src) {
  try {
    const here = new URL(window.location.href)
    const url = new URL(src, here)
    return url.origin === here.origin && url.pathname.startsWith(`${fragmentPath()}/`)
  } catch {
    return false
  }
}

// Phlex::Reactive.fragment_path, for the check above. An app that moves the
// endpoint renders <meta name="phlex-reactive-fragment-path"> (as for the
// action and defer paths); the URL itself always comes from the shell. Read
// from <head> ONLY: this meta widens what the client will fetch and render, so
// one injected into the body must not count.
function fragmentPath() {
  return document.head?.querySelector?.('meta[name="phlex-reactive-fragment-path"]')?.content || "/reactive/fragment"
}

// The push lane: subscribe a <pgbus-stream-source> to the server-signed
// one-shot stream. Arrival + teardown need no client logic — the job's
// broadcast carries the replace AND a remove of this source element (its
// disconnectedCallback closes the SSE connection). since-id=0 on a fresh key
// replays a broadcast that beat the subscription (the durable-lane guarantee).
function startStreamDefer(targetId, directive) {
  const el = document.getElementById(targetId)
  if (!el) {
    console.warn(`[phlex-reactive] reactive:defer target #${targetId} is not on the page — skipped`)
    return
  }
  const src = directive.getAttribute("data-reactive-defer-src")
  if (!src) return
  if (!globalThis.customElements?.get?.("pgbus-stream-source")) {
    // The server chose push on server-side capability, but this page has no
    // pgbus client. Degrade to the fetch lane using the fallback token the push
    // directive carries — rather than dead-end the shimmer. No token (an app on
    // a bespoke transport) is a loud no-op.
    const fallbackToken = directive.getAttribute("data-reactive-defer-token")
    if (fallbackToken) {
      startFetchDefer(targetId, fallbackToken)
      return
    }
    console.error(
      "[phlex-reactive] reactive:defer via=stream but <pgbus-stream-source> is not registered " +
        "and no fallback token was provided — is the pgbus client loaded on this page?",
    )
    return
  }
  supersedeDefer(targetId)
  markDeferPending(el)
  const source = document.createElement("pgbus-stream-source")
  // Deterministic id: the JOB's broadcast removes it by this exact id — the
  // subscription tears itself down with the payload it delivered.
  source.id = deferSourceId(targetId)
  source.setAttribute("src", src)
  source.setAttribute("since-id", directive.getAttribute("data-reactive-defer-since-id") ?? "0")
  source.setAttribute("hidden", "")
  document.body.appendChild(source)
  // Record only { via } — NOT a strong ref to the source element. The job's
  // broadcast removes the source by its deterministic id (its
  // disconnectedCallback closes the SSE), so holding srcEl here would pin the
  // detached node in this module-level Map forever (a leak). Supersession
  // re-finds the element by id instead. The entry is dropped on
  // supersession or when the arriving broadcast removes the source (a
  // turbo:before-stream-render hook, below).
  setPendingDefer(targetId, { via: "stream" })
}

// The deterministic id of a target's one-shot <pgbus-stream-source>.
function deferSourceId(targetId) {
  return `reactive-defer-src-${targetId}`
}

async function performDeferFetch(targetId, entry, source) {
  // Bound the wait like the action fetch (issue #101) — a hung defer must not
  // shimmer forever. A manual timer (not AbortSignal.timeout) so the catch can
  // tell a TIMEOUT (fail loudly) from a SUPERSEDED abort (stay silent).
  const timer = setTimeout(() => {
    entry.timedOut = true
    entry.abort.abort()
  }, deferTimeoutMs())

  // The timeout is cleared ONLY after the body is fully read (below), not the
  // moment headers arrive — a server that streams headers then stalls the body
  // must still abort, or the shimmer hangs forever (the abort signal covers the
  // whole fetch + body read, mirroring #perform's AbortSignal.timeout).
  let response
  try {
    // Counted per fetch() CALL — a fragment GET the browser answers from its
    // HTTP cache still counts (it is a request the client issued; whether it
    // touched the network is Resource Timing's transferSize).
    shared.count("defer")
    response = await fetch(...deferRequest(source, entry.abort.signal))
  } catch (error) {
    clearTimeout(timer)
    if (pendingDefers.get(targetId) !== entry) return // superseded — silent
    console.error("[phlex-reactive] deferred render failed", error)
    failDefer(targetId, source)
    return
  }
  if (pendingDefers.get(targetId) !== entry) {
    clearTimeout(timer)
    return // superseded mid-flight
  }

  // The body is about to be rendered as a turbo-stream, so it must BE one, from
  // the URL we asked for. A base-controller filter that redirects to a sign-in
  // page ends in a 200 HTML document — a failed load, never rendered.
  if (response.redirected) {
    clearTimeout(timer)
    console.error(`[phlex-reactive] deferred render failed: redirected to ${response.url ?? "another URL"}`)
    failDefer(targetId, source, response.status)
    return
  }

  if (response.status === 204) {
    clearTimeout(timer)
    // render? false — keep the current content, just clear the pending state.
    settleDefer(targetId)
    return
  }
  if (!response.ok) {
    clearTimeout(timer)
    console.error(`[phlex-reactive] deferred render failed: HTTP ${response.status}`)
    failDefer(targetId, source, response.status)
    return
  }
  const contentType = response.headers?.get?.("Content-Type") || ""
  if (!contentType.includes("turbo-stream")) {
    clearTimeout(timer)
    console.error(`[phlex-reactive] deferred render failed: expected a turbo-stream, got "${contentType}"`)
    failDefer(targetId, source, response.status)
    return
  }

  let html
  try {
    html = await response.text()
  } catch (error) {
    clearTimeout(timer)
    if (pendingDefers.get(targetId) !== entry) return
    console.error("[phlex-reactive] deferred render failed reading the body", error)
    failDefer(targetId, source)
    return
  }
  clearTimeout(timer)
  if (pendingDefers.get(targetId) !== entry) return // superseded during read

  settleDefer(targetId)
  // A normal replace/morph of the target — the fresh root carries no pending
  // markers and a fresh action token, so the component lands interactive.
  window.Turbo.renderStreamMessage(html)
}

// Abort/unsubscribe whatever delivery is in flight for this target. The
// deleted entry makes every late arrival fail its identity check — stale
// content can never paint.
function supersedeDefer(targetId) {
  const existing = pendingDefers.get(targetId)
  if (!existing) return
  deletePendingDefer(targetId)
  if (existing.via === "fetch") existing.abort.abort()
  // Stream lane: re-find the old source by its deterministic id and remove it
  // (unsubscribe) — we deliberately don't hold a strong ref to the detached
  // node. Its disconnectedCallback closes the SSE.
  else document.getElementById(deferSourceId(targetId))?.remove?.()
}

function markDeferPending(el) {
  el.setAttribute("data-reactive-defer-pending", "true")
  el.setAttribute("aria-busy", "true")
}

function clearDeferPending(el) {
  el.removeAttribute("data-reactive-defer-pending")
  el.removeAttribute("aria-busy")
}

// Success/204: drop the registry entry, clear pending, and clear any prior
// defer failure marker (recovery resets error-driven CSS, issue #100 style).
function settleDefer(targetId) {
  deletePendingDefer(targetId)
  const el = document.getElementById(targetId)
  if (!el) return
  clearDeferPending(el)
  el.removeAttribute("data-reactive-error")
}

// Failure: clear pending (the shimmer must not lie), mark the root
// (data-reactive-error="defer" — style it in pure CSS), and emit a bubbling
// reactive:error whose retry() re-enters the defer fetch with the SAME source
// (a token is still valid inside the TTL; an expired one 400s into this same
// path. A fragment URL never expires).
function failDefer(targetId, source, status) {
  deletePendingDefer(targetId)
  const el = document.getElementById(targetId)
  if (!el) return
  clearDeferPending(el)
  el.setAttribute("data-reactive-error", "defer")
  const retry = () => {
    const fresh = document.getElementById(targetId)
    if (!fresh) {
      console.warn("[phlex-reactive] defer retry() ignored — the target left the DOM")
      return
    }
    fresh.removeAttribute("data-reactive-error")
    startFetchDefer(targetId, source)
  }
  el.dispatchEvent(
    new CustomEvent("reactive:error", {
      bubbles: true,
      composed: true,
      detail: { kind: "defer", target: targetId, status, retry },
    }),
  )
}

function deferPath() {
  return document.querySelector('meta[name="phlex-reactive-defer-path"]')?.content || "/reactive/defer"
}

// CSRF is read LIVE per request (Rails can rotate it) — same contract as the
// controller's #csrfToken.
function deferCsrfToken() {
  return document.querySelector('meta[name="csrf-token"]')?.content ?? ""
}

// Same page-stable meta + default as the controller's #timeoutMs (issue #101),
// parsed defensively so a typo'd meta can never disable the bound.
function deferTimeoutMs() {
  const raw = document.querySelector('meta[name="phlex-reactive-timeout"]')?.content
  const ms = Number(raw)
  return Number.isFinite(ms) && ms > 0 ? ms : 30000
}

// --- Per-root wiring -------------------------------------------------------

export const LAZY_MATERIALIZE_ACTION = "__materialize"

// controller -> this connection's { load, off }: its materialize and its
// teardown, closures over the connection's lazy state (locals of connect(),
// not a record's fields — the minifier renames a local, never a property,
// issue #310):
//   wasShell  whether the root was a trigger shell when last looked at
//             (connect, then every morph) — a morph that turns REAL content
//             back into a shell re-materializes; one that leaves a shell a
//             shell only re-arms it.
//   inFlight  the ONE dedupe point every materialize passes (the Stimulus
//             binding, the observer, the re-armed listener, a morph-back).
//   observer, eventName, onProbe, onMorph  held for teardown.
const wired = new WeakMap()

// Which reactive_lazy(on:) shell this root currently is — read live, because
// a morph rewrites the attributes on a connected element. null = real content
// (or a fetch-on-connect shell).
function shellKind(el) {
  if (el.getAttribute?.("data-reactive-lazy-visible") != null) return "visible"
  if (el.getAttribute?.("data-reactive-lazy-on")) return "event"
  return null
}

// `morphed` is true when this connect follows a MORPH of an already connected
// root (the core re-scans for feature markers on a morph of the root): the
// root showed real content and the morph turned it into a shell.
export function connect(controller, core, morphed) {
  registerSettleOnRender()
  const el = controller.element
  let wasShell = false
  let inFlight = false
  let observer = null
  let eventName = null
  let onProbe
  let onMorph
  // Every trigger goes through the exported materialize, so one that fires
  // after disconnect (a queued microtask) finds nothing wired and does nothing.
  const onEvent = () => materialize(controller)

  // Arm the shell's trigger. A :visible shell gets (at most one) observer. An
  // event shell's FIRST event rides its Stimulus `once` binding, so on connect
  // there is nothing to add; after a morph (`rearm`) that binding may be spent
  // — Stimulus only re-binds when the descriptor attribute itself changed — so
  // this listens for the event itself. Both can fire for one event; materialize
  // dedupes. Either trigger is consumed when a request starts (like `once`):
  // one morph buys one attempt.
  const arm = (rearm) => {
    if (shellKind(el) === "visible") {
      if (!observer) observeVisible()
    } else if (rearm) {
      const name = el.getAttribute("data-reactive-lazy-on")
      if (eventName === name) return
      disarm()
      el.addEventListener?.(name, onEvent)
      eventName = name
    }
  }

  const disarm = () => {
    observer?.disconnect()
    observer = null
    if (eventName) el.removeEventListener?.(eventName, onEvent)
    eventName = null
  }

  // reactive_lazy(on: :visible) (issue #276): materialize the first time the
  // shell intersects the viewport (grown or shrunk by the rendered
  // rootMargin). Without IntersectionObserver (very old engines) materialize
  // right away: the content still loads, just not lazily.
  const observeVisible = () => {
    if (typeof IntersectionObserver === "undefined") return queueMicrotask(onEvent)
    const rootMargin = el.getAttribute("data-reactive-lazy-visible") || "0px"
    observer = new IntersectionObserver(
      (entries) => {
        if (entries.some((entry) => entry.isIntersecting)) onEvent()
      },
      { rootMargin },
    )
    observer.observe(el)
  }

  // turbo:morph-element OF the root: the morph is server truth arriving on a
  // CONNECTED element. Four outcomes:
  //   * now real content            → nothing to load; drop any armed trigger.
  //   * a load is in flight         → leave it; its reply replaces the shell.
  //   * was real, now a shell       → it was loaded and the morph wiped it, so
  //                                   re-materialize now (for an event shell
  //                                   the event — a panel opening — already
  //                                   happened and won't fire again).
  //   * was a shell, still a shell  → never triggered, or a failed load: re-arm
  //                                   it (this is a failed load's retry path).
  const afterMorph = () => {
    const shell = shellKind(el) !== null
    const was = wasShell
    wasShell = shell
    if (!shell) return disarm()
    if (inFlight) return
    // The morphed-in shell's token is the page's current identity; a token
    // cached from an earlier reply would materialize stale state.
    core.forgetToken()
    if (!was) return onEvent()
    arm(true)
  }

  wired.set(controller, {
    // See materialize() below.
    load() {
      if (inFlight) return
      const source = fragmentSource(el)
      // A URL refused with no fallback has already failed the shell: never POST.
      if (!source && el.getAttribute("data-reactive-defer-src") != null) return
      // The GET skips the action pipeline, so raise its veto here: an app's
      // reactive:before-dispatch listener controls a materialize either way.
      if (source && materializeVetoed(el, core)) return
      const run = source ? startFetchDefer(el.id, source) : core.proceed(el, LAZY_MATERIALIZE_ACTION, "{}")
      if (!run) return // vetoed by reactive:before-dispatch (or the root has no id)
      inFlight = true
      // Consume the armed trigger (observer or re-armed listener): a failed load
      // is retried by the NEXT morph, not by every later event.
      disarm()
      const done = () => {
        inFlight = false
      }
      run.then(done, done)
      return run
    },
    off() {
      if (onProbe) el.removeEventListener?.("turbo:morph-element", onProbe)
      if (onMorph) el.removeEventListener?.("turbo:morph-element", onMorph)
      disarm()
    },
  })

  // Lazy initial mount (issue #165): a reactive_lazy shell carries its defer
  // token as a ROOT attribute — enter the SAME module-level fetch path a
  // reply directive uses (supersession, pending markers, error handling
  // included). Probe on connect (a plain replace / cache restoration
  // re-connects) AND on turbo:morph-element: a Turbo page-refresh MORPH
  // re-shows the shell while keeping the element CONNECTED and firing no
  // Stimulus lifecycle, so a connect-only probe would leave the morphed-in
  // shell shimmering forever. turbo:morph-element BUBBLES, and a re-probe
  // supersedes (aborts and re-issues) the fetch in flight, so only a morph of
  // the root itself counts (issue #294). The attribute stays on the shell
  // precisely so a re-appearance re-fires.
  // A `cache:` shell (issue #277) carries a fragment URL instead of the token
  // and takes the same path; an on: shell with a URL is NOT probed — it waits
  // for its trigger (its root has no pending marker).
  const fetches = el.getAttribute?.("data-reactive-defer-token") || el.getAttribute?.("data-reactive-defer-src")
  if (fetches && shellKind(el) === null) {
    probe(el)
    onProbe = (event) => event.target === el && probe(el)
    el.addEventListener?.("turbo:morph-element", onProbe)
  }

  // reactive_lazy(on:) shells (issue #276) carry NO defer token, so the probe
  // above skips them: an event shell waits for its once-bound __materialize
  // trigger, a :visible shell for the observer armed here. An on: shell
  // carries either the identity token or (with cache:, issue #306) its
  // fragment URL; a root with neither is client-only, never an on: shell.
  const tokenless = el.getAttribute?.("data-reactive-token-value") == null
  if (tokenless && el.getAttribute?.("data-reactive-defer-src") == null) return
  // turbo:morph-element BUBBLES: only a morph of the root itself counts, never
  // one of a descendant (a morphed skeleton child, a nested root). The same
  // morph can turn real content into a FETCH-ON-CONNECT shell (plain
  // reactive_lazy, or cache: without on:): probe it too, unless this root
  // connected as such a shell and already re-probes on every morph.
  onMorph = (event) => {
    if (event.target !== el) return
    if (!onProbe) probe(el)
    afterMorph()
  }
  el.addEventListener?.("turbo:morph-element", onMorph)
  if (morphed) return afterMorph()
  wasShell = shellKind(el) !== null
  if (wasShell) arm(false)
}

export function disconnect(controller) {
  const wiring = wired.get(controller)
  wired.delete(controller)
  wiring?.off()
}

// THE materialize entry point: the shell's Stimulus binding (the core's
// dispatch routes its __materialize action here), the :visible observer, the
// re-armed event listener and a morph-back all land here, so one in-flight
// flag makes "exactly one request" hold no matter how many of them fire. It
// rides the ordinary action pipeline (core.proceed → the serialized queue →
// the request): the reactive:before-dispatch veto, busy markers, error
// marker/events and the request counter all apply.
//
// A `cache:` shell (issue #277) carries its fragment URL: the load is then a
// GET on the defer pull lane (pending markers, timeout, reactive:error with
// retry()) instead of the action POST, so the browser's cache can answer —
// on the first trigger of a later page view, and on every morph-back.
export function materialize(controller) {
  return wired.get(controller)?.load()
}

function materializeVetoed(el, core) {
  return core.emit("reactive:before-dispatch", { action: LAZY_MATERIALIZE_ACTION, params: {}, element: el }, { cancelable: true })
    .defaultPrevented
}

// Lazy initial mount probe (issue #165): fetch the real content when THIS
// root is a reactive_lazy shell that still carries its defer token AND the
// pending marker. Gating on the pending marker is what makes a re-probe (a
// Turbo morph re-showing the shell) fire while a re-probe of an already
// RESOLVED root (real content, no token, no marker) is a no-op. The
// module-level supersession registry dedupes a duplicate in-flight fetch for
// the same id, so calling this on both connect and every morph is safe.
function probe(el) {
  if (!el?.id) return
  if (el.getAttribute?.("data-reactive-defer-pending") !== "true") return
  const source = el.getAttribute?.("data-reactive-defer-token") || fragmentSource(el)
  if (source) startFetchDefer(el.id, source)
}
