// phlex/reactive/features/presence — who is viewing a stream, one seat per
// tab (issue #358). One of the feature modules the core imports on demand
// (issue #275); in the default client it is part of the one file.
//
// The markup is the Ruby side's (reactive_presence and its helpers):
//
//   data-reactive-presence="<signed src>"    the roster root; its stream
//   data-reactive-presence-roster="<seats>"  on the root: the seats rendered
//   data-reactive-presence-peer="<seat>"     a tab's element
//   data-reactive-presence-member="<id>"     a person's (or a tab's) element
//
// and what this module sets, for the app's CSS, after the first paint and
// after every morph of the root:
//
//   data-reactive-presence-me                this tab's own peer element
//   data-reactive-presence-same-member       this person's other elements
//
// The roster is rendered ONCE for every viewer (one broadcast), so the server
// cannot say which row is "me": the module does, from the tab's seat.
//
// The subscription. The root carries its presence stream's signed src; the
// module mints a <pgbus-stream-source presence> for it in <body>, with a
// deterministic id (reactive-presence-src-<root id>), as the defer push lane
// mints its one-shot source. pgbus's element mints the tab's seat (one per
// document), sends it as ?seat= and exposes it as element.pgbusSeat: the
// transport stores it on the tab's presence row, a reconnect (a new
// connection id) keeps it, and this module reads it to find "me". A plain
// replace of the root disconnects and
// reconnects the controller: the source is removed only a microtask after a
// disconnect, and kept when the same root id comes back.
//
// Announcing. On every pgbus:connected (the first one and each reconnect) the
// module sends presence_set with the tab's last state ({} at first), through
// the root's own pipeline (core.proceed): the signed token, the typed state,
// the request queue. That write puts the tab on the roster for everyone (and
// the actor's own reply shows it), and a reconnect, which is a fresh row with
// no state, gets its state back. The runtime sends the source's connection id
// as X-Reactive-Presence, so the write lands on this tab's row.
//
// Events. The module keeps the seats it last saw in the root (the root's
// data-reactive-presence-roster list); when a morph changes them it dispatches
// reactive:presence on the root with { joined, left, me } — from the DOM, so a
// replayed frame that changes nothing fires nothing.
//
// This module never imports the core: it reaches a controller through the
// `core` handle (core.proceed, core.emit).

const SOURCE = "reactive-presence-src-"
const PEER = "data-reactive-presence-peer"
const MEMBER = "data-reactive-presence-member"
const ROSTER = "data-reactive-presence-roster"

// root id -> { root, core, state, seats, removing, off }: what a root's
// connection left behind, kept across a replace of the root.
const roots = new Map()
// The sources this module minted and listens to (a Turbo cache restore brings
// back a clone without the listener).
const minted = new WeakSet()

export function connect(controller, core) {
  const root = controller.element
  let entry = roots.get(root.id)
  if (!entry) roots.set(root.id, (entry = { state: null, seats: null }))
  entry.root = root
  entry.core = core
  entry.removing = false
  subscribe(root)
  const morphed = (event) => event.target === root && queueMicrotask(() => paint(entry))
  root.addEventListener("turbo:morph-element", morphed)
  entry.off = () => root.removeEventListener("turbo:morph-element", morphed)
  paint(entry)
}

export function disconnect(controller) {
  const root = controller.element
  const entry = roots.get(root.id)
  if (!entry || entry.root !== root) return
  entry.off()
  entry.removing = true
  queueMicrotask(() => {
    if (!entry.removing) return
    roots.delete(root.id)
    root.ownerDocument.getElementById(SOURCE + root.id)?.remove()
  })
}

// js.presence(**state): merge into the tab's state and send it. Before the
// tab has a connection the state waits for the announce on connect.
export function set(root, state) {
  if (!root?.hasAttribute?.("data-reactive-presence")) {
    console.warn("[phlex-reactive] js.presence ran outside a reactive_presence root — ignored")
    return
  }
  let entry = roots.get(root.id)
  if (!entry) roots.set(root.id, (entry = { root, state: null, seats: null }))
  entry.state = { ...entry.state, ...state }
  send(entry)
}

function subscribe(root) {
  const id = SOURCE + root.id
  const found = document.getElementById(id)
  if (found && minted.has(found)) return
  found?.remove()
  // pgbus's client is an async module script, so this controller can connect
  // before <pgbus-stream-source> is defined: mint the element anyway (it
  // upgrades when pgbus defines it), and call a still-missing client a
  // misconfiguration only after a grace period.
  if (!defined()) {
    setTimeout(() => {
      if (!defined()) {
        console.error(
          "[phlex-reactive] reactive_presence needs the pgbus client (<pgbus-stream-source>) on this page — " +
            `#${root.id} is not subscribed to its presence stream`,
        )
      }
    }, 5000)
  }
  const source = document.createElement("pgbus-stream-source")
  source.id = id
  source.setAttribute("src", root.getAttribute("data-reactive-presence"))
  source.setAttribute("presence", "")
  source.hidden = true
  source.addEventListener("pgbus:connected", () => {
    const entry = roots.get(root.id)
    if (!entry || entry.removing) return
    send(entry)
    check(entry)
  })
  minted.add(source)
  document.body.appendChild(source)
}

const defined = () => !!globalThis.customElements?.get?.("pgbus-stream-source")

// pgbus fires pgbus:connected only after the tab's seat has joined, so the
// announce lands on its row. A tab still off its roster a moment later has no
// identity (pgbus joins an anonymous connection to nothing): say so once.
function check(entry) {
  clearTimeout(entry.timer)
  entry.timer = setTimeout(() => {
    const root = entry.root
    if (entry.removing || !root.isConnected) return
    const mine = root.ownerDocument.getElementById(SOURCE + root.id)?.pgbusSeat
    if (mine && seatsOf(root).has(mine)) return
    console.warn(
      `[phlex-reactive] #${root.id} never appeared on its presence roster — does config.streams_authorize ` +
        "return the viewer's identity for this stream?",
    )
  }, 2500)
}

// Send the tab's state through presence_set — only once the source has a
// connection (the row the write lands on). Until then the announce on
// pgbus:connected sends it.
function send(entry) {
  const root = entry.root
  if (!entry.core || !root.ownerDocument.getElementById(SOURCE + root.id)?.getAttribute("connection-id")) return
  entry.core.proceed(root, "presence_set", JSON.stringify(entry.state ?? {}))
}

// The seats the root's render saw: the list the server names on the root
// (data-reactive-presence-roster: a template need not render an element per
// tab), or, without it, the tabs' own elements.
function seatsOf(root) {
  const named = root.getAttribute(ROSTER)
  if (named != null) return new Set(named.split(" ").filter(Boolean))
  return new Set([...root.querySelectorAll(`[${PEER}]`)].map((el) => el.getAttribute(PEER)))
}

// Mark "me" and this person's other elements, then report the seats that
// joined or left since the last paint.
function paint(entry) {
  const root = entry.root
  // The seat pgbus's element minted (undefined on a pgbus without seats).
  const mine = root.ownerDocument.getElementById(SOURCE + root.id)?.pgbusSeat
  const marked = root.querySelectorAll(`[${PEER}],[${MEMBER}]`)
  const seats = seatsOf(root)
  let member
  for (const el of marked) {
    if (el.getAttribute(PEER) === mine) member = el.getAttribute(MEMBER)
  }
  for (const el of marked) {
    const me = el.getAttribute(PEER) === mine
    el.toggleAttribute("data-reactive-presence-me", me)
    el.toggleAttribute("data-reactive-presence-same-member", !me && member != null && el.getAttribute(MEMBER) === member)
  }
  const before = entry.seats
  entry.seats = seats
  if (!before) return
  const joined = [...seats].filter((s) => !before.has(s))
  const left = [...before].filter((s) => !seats.has(s))
  if (joined.length || left.length) entry.core.emit("reactive:presence", { joined, left, me: mine ?? null })
}
