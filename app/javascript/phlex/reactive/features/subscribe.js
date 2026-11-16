// phlex/reactive/features/subscribe — a root subscribed to its own broadcast
// stream (issue #474). One of the feature modules the core imports on demand
// (issue #275); in the default client it is part of the one file.
//
// The markup is the Ruby side's (reactive_subscribe):
//
//   data-reactive-subscribe="<signed src>"   the stream's signed SSE src
//
// While the root is on the page, the module keeps a <pgbus-stream-source> for
// that src in <body> (marked data-reactive-subscribe-source); pgbus's element
// applies what arrives as Turbo Stream actions. Two roots with the same src
// share ONE source (an append lands once, not once per root): it closes when
// the last of them goes. A replace of the root disconnects and reconnects the
// controller: the source is released only a microtask after a disconnect, so
// the same root id coming back keeps the connection. A change of the src (a
// morph that re-keys the root) moves the root to the new stream; a morph that
// keeps it changes nothing. A page refresh by morph (Turbo 8) drops the
// minted source from <body> while the roots stay connected: after it the
// module mints a fresh source for every stream a live root still needs.
//
// This module never imports the core.

const ATTR = "data-reactive-subscribe"
const MARK = "data-reactive-subscribe-source"

// src -> { source, ids }: one source per stream, and the root ids on it.
const streams = new Map()
// root id -> { root, src, removing, observer }: kept across a replace.
const roots = new Map()
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
  if (!entry) roots.set(root.id, (entry = { src: null }))
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
  const entry = roots.get(root.id)
  if (!entry || entry.root !== root) return
  entry.observer.disconnect()
  entry.removing = true
  queueMicrotask(() => {
    if (!entry.removing) return
    roots.delete(root.id)
    follow(entry, null)
  })
}

// Move the root to `src` (null: no stream): join the new one first, so a
// shared source is never closed and reopened, then leave the old.
function follow(entry, src) {
  const previous = entry.src
  entry.src = src || null
  if (entry.src) join(entry.src, entry.root.id)
  if (previous && previous !== entry.src) leave(previous, entry.root.id)
}

// After a page render, re-mint each source the page lost while a root on its
// stream is still on the page (a root that left releases it on its own).
function rejoin() {
  for (const entry of roots.values()) {
    if (entry.src && !entry.removing && entry.root.isConnected) join(entry.src, entry.root.id)
  }
}

function join(src, id) {
  let stream = streams.get(src)
  if (!stream?.source.isConnected) streams.set(src, (stream = { source: mint(src), ids: stream?.ids ?? new Set() }))
  stream.ids.add(id)
}

function leave(src, id) {
  const stream = streams.get(src)
  if (!stream) return
  stream.ids.delete(id)
  if (stream.ids.size) return
  streams.delete(src)
  stream.source.remove()
}

function mint(src) {
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
  minted.add(source)
  document.body.appendChild(source)
  return source
}

const defined = () => !!globalThis.customElements?.get?.("pgbus-stream-source")
