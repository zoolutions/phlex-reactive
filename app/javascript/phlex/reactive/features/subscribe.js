// phlex/reactive/features/subscribe — a root subscribed to its own broadcast
// stream (issue #474). One of the feature modules the core imports on demand
// (issue #275); in the default client it is part of the one file.
//
// The markup is the Ruby side's (reactive_subscribe):
//
//   data-reactive-subscribe="<signed src>"   the stream's signed SSE src
//   data-reactive-subscribe-since="<id>"     a durable stream's watermark at
//                                            render (issue #478)
//
// While the root is on the page, the module keeps a <pgbus-stream-source> for
// that src in a hidden box at the end of <body> (marked
// data-reactive-subscribe-source); pgbus's element
// applies what arrives as Turbo Stream actions. Two roots with the same src
// share ONE source (an append lands once, not once per root): it closes when
// the last of them goes. A replace of the root disconnects and reconnects the
// controller: the source is released only a microtask after a disconnect, so
// the same root id coming back keeps the connection. A change of the src (a
// morph that re-keys the root) moves the root to the new stream; a morph that
// keeps it changes nothing. A page refresh by morph (Turbo 8) keeps the
// source, connection and all (see box). Should a render drop it anyway while
// the roots stay connected, the module mints a fresh source for every stream
// a live root still needs.
//
// Catching up (issue #478). A source opens with since-id set to the lowest
// watermark of the roots on its src, so pgbus replays a durable broadcast
// sent between the render and the connection. A source minted again after a
// page render resumes from the last frame the dropped one applied, for a root
// that was on the page then (a re-rendered root keeps its own). Each time
// a source connects (its pgbus:connected), every root on it gets
// reactive:subscribed (detail { connectionId, reconnect }; reconnect is false
// on the stream's first connection), not bubbling, so a component can refetch
// what an ephemeral stream could not replay. A root that joins a source
// already connected gets no event: the source is live, and a root that comes
// back under the same id (a replace) must not refresh again and again.
//
// This module never imports the core.

const ATTR = "data-reactive-subscribe"
const SINCE = "data-reactive-subscribe-since"
const MARK = "data-reactive-subscribe-source"

// src -> { source, ids, connected, lastId, seen }: one source per stream, the
// root ids on it, whether it ever connected, the last durable frame it
// applied, and the root elements that were on the page when it did.
const streams = new Map()
// root id -> { id, root, src, removing, observer }: kept across a replace.
// The id is the one the root had at connect: a root whose id changes while
// connected still releases what it holds (byRoot finds its entry).
const roots = new Map()
const byRoot = new WeakMap()
// The sources this module minted (a Turbo cache restore brings back clones).
const minted = new WeakSet()
let listening = false

export function connect(controller) {
  if (!listening) {
    listening = true
    document.addEventListener("turbo:morph", rejoin)
    document.addEventListener("turbo:render", rejoin)
  }
  const root = controller.element
  let entry = roots.get(root.id)
  if (!entry) roots.set(root.id, (entry = { id: root.id, src: null }))
  byRoot.set(root, entry)
  entry.observer?.disconnect()
  entry.root = root
  entry.removing = false
  for (const clone of document.querySelectorAll(`pgbus-stream-source[${MARK}]`)) {
    if (!minted.has(clone)) clone.remove()
  }
  follow(entry, root.getAttribute(ATTR))
  entry.observer = new MutationObserver(() => follow(entry, root.getAttribute(ATTR)))
  entry.observer.observe(root, { attributes: true, attributeFilter: [ATTR] })
}

export function disconnect(controller) {
  const root = controller.element
  const entry = byRoot.get(root)
  if (!entry || entry.root !== root) return
  entry.observer.disconnect()
  entry.removing = true
  queueMicrotask(() => {
    if (!entry.removing) return
    roots.delete(entry.id)
    follow(entry, null)
  })
}

// Move the root to `src` (null: no stream): join the new one first, so a
// shared source is never closed and reopened, then leave the old.
function follow(entry, src) {
  const previous = entry.src
  entry.src = src || null
  if (entry.src) join(entry.src, entry.id)
  if (previous && previous !== entry.src) leave(previous, entry.id)
}

// After a page render, re-mint each source the page lost while a root on its
// stream is still on the page (a root that left releases it on its own).
function rejoin() {
  for (const entry of roots.values()) {
    if (entry.src && !entry.removing && entry.root.isConnected) join(entry.src, entry.id)
  }
}

function join(src, id) {
  let stream = streams.get(src)
  if (!stream) streams.set(src, (stream = { source: null, ids: new Set(), connected: false, lastId: null, seen: null }))
  stream.ids.add(id)
  if (!stream.source?.isConnected) stream.source = mint(src, stream)
}

function leave(src, id) {
  const stream = streams.get(src)
  if (!stream) return
  stream.ids.delete(id)
  if (stream.ids.size) return
  streams.delete(src)
  stream.source.remove()
}

function mint(src, stream) {
  // pgbus's client is an async module script: mint the element anyway (it
  // upgrades when pgbus defines it), and call a still-missing client a
  // misconfiguration only after a grace period.
  if (!defined()) {
    setTimeout(() => {
      if (!defined()) {
        console.error(
          "[phlex-reactive] reactive_subscribe needs the pgbus client (<pgbus-stream-source>) on this page: " +
            'import "pgbus/stream_source_element"',
        )
      }
    }, 5000)
  }
  const source = document.createElement("pgbus-stream-source")
  source.setAttribute("src", src)
  source.setAttribute(MARK, "")
  source.hidden = true
  // Before the append: pgbus reads since-id once, when the element connects.
  const since = resumeFrom(src, stream)
  if (since != null) source.setAttribute("since-id", String(since))
  const applied = (event) => {
    const id = event.detail?.msgId
    // A negative id is an ephemeral frame, never persisted: nothing to resume from.
    if (typeof id !== "number" || id <= 0 || stream.lastId >= id) return
    stream.lastId = id
    stream.seen = new WeakSet()
    for (const rootId of stream.ids) {
      const root = roots.get(rootId)?.root
      if (root?.isConnected) stream.seen.add(root)
    }
  }
  source.addEventListener("pgbus:message", applied)
  source.addEventListener("pgbus:event", applied)
  source.addEventListener("pgbus:connected", (event) => {
    if (stream.source !== source) return
    const reconnect = stream.connected
    stream.connected = true
    const connectionId = event.detail?.connectionId ?? null
    for (const id of stream.ids) {
      const entry = roots.get(id)
      if (!entry || entry.removing || entry.src !== src || !entry.root.isConnected) continue
      entry.root.dispatchEvent(new CustomEvent("reactive:subscribed", { detail: { connectionId, reconnect } }))
    }
  })
  minted.add(source)
  box().appendChild(source)
  return source
}

// Where a durable stream's source replays from: the lowest of what each root
// on its src still needs (two roots rendered apart share the source). A root
// needs what came after its watermark, or after the last frame a dropped
// source applied when that root was on the page then. A root rendered again
// (a Drive render under the same id) is a new element: its own watermark
// wins. null for an ephemeral stream (no root carries a watermark).
function resumeFrom(src, stream) {
  let since = null
  for (const root of document.querySelectorAll(`[${SINCE}]`)) {
    if (root.getAttribute(ATTR) !== src) continue
    let value = Number(root.getAttribute(SINCE))
    if (!Number.isFinite(value) || value < 0) continue
    if (stream.lastId > value && stream.seen?.has(root)) value = stream.lastId
    if (since == null || value < since) since = value
  }
  return since
}

// The minted sources live in one hidden <reactive-stream-sources> at the end
// of <body>, data-turbo-permanent: a page refresh by morph (Turbo 8) keeps
// it, sources and connections included. A tag no server page renders, so
// Idiomorph never pairs it with (and drops) a node the refreshed page adds.
function box() {
  let el = [...document.body.children].find((child) => child.localName === "reactive-stream-sources")
  if (!el) {
    el = document.createElement("reactive-stream-sources")
    el.hidden = true
    el.setAttribute("data-turbo-permanent", "")
    document.body.appendChild(el)
  }
  return el
}

const defined = () => !!globalThis.customElements?.get?.("pgbus-stream-source")
