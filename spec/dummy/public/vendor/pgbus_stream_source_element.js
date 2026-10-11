// <pgbus-stream-source> — the browser-side counterpart to
// Pgbus::StreamsHelper#pgbus_stream_from. Drop-in replacement for
// turbo-rails' <turbo-cable-stream-source> that speaks SSE + pgbus
// instead of WebSocket + ActionCable.
//
// Attributes (set by the view helper):
//   src                 — absolute path to the SSE endpoint, including
//                         the URL-safe signed stream name
//   since-id            — PGMQ msg_id watermark at render time; the
//                         client sends this as ?since= on the FIRST
//                         connect so the server can replay any
//                         broadcasts from the render-to-connect gap
//                         (rails/rails#52420 fix)
//   signed-stream-name  — present for parity with turbo-rails; unused
//                         by this element because the signed name is
//                         already in the URL path
//   channel             — compatibility shim; ignored
//   presence            — boolean; when present the element sends this
//                         document's presence seat as ?seat= on every
//                         connect (issue #515)
//
// Events (dispatched on the element):
//   message            (MessageEvent) data = turbo-stream HTML;
//                      lastEventId = the frame's msg_id (revision)
//   pgbus:message      { msgId, data } — same frame, for optimistic-UI
//                      reconciliation (skip morph if a newer rev for the
//                      target was already applied). See #168.
//   pgbus:event        { event, data, msgId } — a typed broadcast (any SSE
//                      event name other than turbo-stream). See #170.
//   pgbus:<event>      { data, msgId } — the same typed broadcast, named
//                      for ergonomic addEventListener("pgbus:presence").
//   pgbus:open         { lastEventId, connectionId }
//   pgbus:connected    { connectionId }
//   pgbus:replay-start { fromId, toId }
//   pgbus:replay-end   {}
//   pgbus:gap-detected { lastSeenId, archiveOldestId }
//   pgbus:close        { code, reason }
//
// Connection id (issue #165 — actor-echo suppression): the server sends a
// `pgbus:connected` frame right after the open handshake carrying the
// server-minted connection id. This element captures it, reflects it onto
// the `connection-id` attribute, and re-dispatches it as `pgbus:connected`.
// A page reads it (from the element or a `<meta name="pgbus-connection-id">`
// the app mirrors it to) and sends it back as the `X-Pgbus-Connection`
// header on action requests. The broadcaster then passes
// `exclude: request.headers["X-Pgbus-Connection"]` so the actor does not
// receive the echo of its own broadcast.
//
// The element integrates with Turbo via connectStreamSource /
// disconnectStreamSource + dispatching MessageEvent("message") so Turbo
// Stream HTML is automatically consumed by the existing StreamObserver.
//
// Presence seat (issue #515): with the `presence` attribute, the element
// appends `?seat=<id>` to the SSE request. The seat is minted once per
// document (shared by every presence element on the page and kept across
// Turbo Drive visits, so it names the browser tab) and stays the same across
// reconnects. The server stores it on the connection's presence row, which
// lets a page tell its own tab apart from the member's other tabs. Read it
// from `element.pgbusSeat`.
//
// Transport strategy:
//   - FIRST connect: use fetch() + ReadableStream to include ?since=
//     in the URL. Native EventSource cannot send Last-Event-ID on the
//     initial request, so we need fetch to carry the watermark.
//   - RECONNECT: switch to native EventSource, which sends Last-Event-ID
//     automatically based on the last id: we observed. The native
//     client is more battle-tested for reconnection backoff.

import { Turbo } from "@hotwired/turbo-rails"
const { connectStreamSource, disconnectStreamSource } = Turbo

let documentSeat = null

// One seat per document, minted on first use (see "Presence seat" above).
function seatForDocument() {
  if (!documentSeat) {
    documentSeat = globalThis.crypto && crypto.randomUUID
      ? crypto.randomUUID()
      : `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 12)}`
  }
  return documentSeat
}

class PgbusStreamSourceElement extends HTMLElement {
  static get observedAttributes() {
    return ["src", "since-id"]
  }

  constructor() {
    super()
    this.abortController = null
    this.eventSource = null
    this.lastEventId = null
    this.connectionId = null
    this.closed = false
  }

  // The server-minted connection id for this SSE connection, or null
  // until the `pgbus:connected` frame arrives. Public read accessor so
  // a reactive runtime can grab it without poking at attributes.
  get pgbusConnectionId() {
    return this.connectionId
  }

  // This document's presence seat when the element has the `presence`
  // attribute, otherwise null.
  get pgbusSeat() {
    return this.hasAttribute("presence") ? seatForDocument() : null
  }

  connectedCallback() {
    this.closed = false
    connectStreamSource(this)
    const sinceId = this.getAttribute("since-id")
    this.lastEventId = sinceId && sinceId !== "" ? sinceId : null
    this.openFetchStream()
  }

  disconnectedCallback() {
    this.closed = true
    disconnectStreamSource(this)
    this.teardown()
  }

  teardown() {
    if (this.abortController) {
      this.abortController.abort()
      this.abortController = null
    }
    if (this.eventSource) {
      this.eventSource.close()
      this.eventSource = null
    }
  }

  // First connect: use fetch() so we can include ?since=<watermark> on
  // the URL. Parses the SSE event stream by hand because EventSource
  // doesn't expose custom query strings uniformly across browsers.
  async openFetchStream() {
    // Each transport open is a fresh connection: the server mints a new id
    // and sends a new pgbus:connected frame. Clear the previous id so
    // pgbus:open (which fires before that frame arrives) can't surface a
    // stale connection id — a stale id would produce a wrong X-Pgbus-Connection
    // exclude header during reconnect windows.
    this.resetConnectionId()
    const url = this.buildUrl({ includeSince: true })
    this.abortController = new AbortController()

    try {
      const response = await fetch(url, {
        headers: { Accept: "text/event-stream" },
        credentials: "same-origin",
        signal: this.abortController.signal
      })

      if (!response.ok) {
        this.dispatchEvent(new CustomEvent("pgbus:close", {
          detail: { code: response.status, reason: response.statusText }
        }))
        return
      }

      this.setAttribute("connected", "")
      this.dispatchEvent(new CustomEvent("pgbus:open", {
        detail: { lastEventId: this.lastEventId, connectionId: this.connectionId }
      }))

      const reader = response.body.getReader()
      const decoder = new TextDecoder("utf-8")
      let buffer = ""

      while (!this.closed) {
        const { value, done } = await reader.read()
        if (done) {
          this.removeAttribute("connected")
          this.switchToEventSource()
          return
        }

        buffer += decoder.decode(value, { stream: true })
        const events = buffer.split("\n\n")
        buffer = events.pop() // last chunk may be incomplete

        for (const block of events) {
          this.handleBlock(block)
        }
      }
    } catch (err) {
      if (err.name !== "AbortError") {
        this.removeAttribute("connected")
        // Fall through to reconnect via native EventSource, which
        // will carry Last-Event-ID from this.lastEventId forward.
        this.switchToEventSource()
      }
    }
  }

  // Reconnect path: native EventSource with Last-Event-ID baked into
  // the initial handshake by the browser.
  switchToEventSource() {
    if (this.closed) return

    // Fresh connection on reconnect — drop the previous connection id so
    // pgbus:open can't emit a stale one before the new pgbus:connected
    // frame lands. See openFetchStream.
    this.resetConnectionId()
    const url = this.buildUrl({ includeSince: true })
    this.eventSource = new EventSource(url, { withCredentials: true })

    this.eventSource.addEventListener("open", () => {
      this.setAttribute("connected", "")
      this.dispatchEvent(new CustomEvent("pgbus:open", {
        detail: { lastEventId: this.lastEventId, connectionId: this.connectionId }
      }))
    })

    this.eventSource.addEventListener("error", () => {
      this.removeAttribute("connected")
    })

    this.eventSource.addEventListener("turbo-stream", (event) => {
      this.lastEventId = event.lastEventId
      this.emitTurboStream(event.data, event.lastEventId)
    })

    this.eventSource.addEventListener("pgbus:connected", (event) => {
      this.handleConnected(event.data)
    })

    this.eventSource.addEventListener("pgbus:gap-detected", (event) => {
      const detail = this.safeJsonParse(event.data)
      this.dispatchEvent(new CustomEvent("pgbus:gap-detected", { detail }))
    })

    this.eventSource.addEventListener("pgbus:shutdown", () => {
      this.dispatchEvent(new CustomEvent("pgbus:close", {
        detail: { code: "shutdown", reason: "worker restart" }
      }))
    })

    // Typed broadcasts (issue #170): EventSource only fires listeners
    // registered by name, so we register one per declared typed event.
    for (const name of this.declaredTypedEvents()) {
      this.eventSource.addEventListener(name, (event) => {
        if (event.lastEventId) this.lastEventId = event.lastEventId
        this.emitTypedEvent(name, event.data, event.lastEventId)
      })
    }
  }

  // Parses a single SSE event block (: comment | id: ... | event: ... | data: ...)
  handleBlock(block) {
    if (!block || block.startsWith(":")) return // comment

    let id = null
    let event = "message"
    const dataLines = []

    for (const line of block.split("\n")) {
      if (line.startsWith("id:")) id = line.slice(3).trim()
      else if (line.startsWith("event:")) event = line.slice(6).trim()
      // Per the SSE spec: strip only a single leading space after the colon
      // (never trim — payload whitespace is significant, issue #392) and
      // rejoin consecutive data: lines with \n, matching native EventSource.
      else if (line.startsWith("data:")) dataLines.push(line.slice(5).replace(/^ /, ""))
    }
    const data = dataLines.join("\n")

    if (id !== null) this.lastEventId = id

    if (event === "turbo-stream") {
      this.emitTurboStream(data, id)
    } else if (event === "pgbus:connected") {
      this.handleConnected(data)
    } else if (event === "pgbus:gap-detected") {
      this.dispatchEvent(new CustomEvent("pgbus:gap-detected", {
        detail: this.safeJsonParse(data)
      }))
    } else if (event === "pgbus:shutdown") {
      this.dispatchEvent(new CustomEvent("pgbus:close", {
        detail: { code: "shutdown", reason: "worker restart" }
      }))
    } else {
      // A typed broadcast (issue #170): event: presence | reactive | ...
      this.emitTypedEvent(event, data, id)
    }
  }

  // Captures the server-minted connection id from a `pgbus:connected`
  // frame: stores it, reflects it onto the `connection-id` attribute (so
  // it's visible in the DOM / to MutationObservers), and re-dispatches it
  // as a `pgbus:connected` CustomEvent. Idempotent across reconnects — the
  // server mints a fresh id per connection, so a reconnect updates it.
  handleConnected(data) {
    const detail = this.safeJsonParse(data)
    const connectionId = detail && detail.connectionId
    if (!connectionId) return

    this.connectionId = connectionId
    this.setAttribute("connection-id", connectionId)
    this.dispatchEvent(new CustomEvent("pgbus:connected", {
      detail: { connectionId }
    }))
  }

  // Clears the cached connection id and its reflected attribute. Called at
  // the start of every transport open so a reconnect doesn't carry the
  // previous connection's id into pgbus:open before the new pgbus:connected
  // frame arrives.
  resetConnectionId() {
    this.connectionId = null
    this.removeAttribute("connection-id")
  }

  // Delivers a turbo-stream frame to two audiences (issue #168):
  //
  //   1. Turbo's StreamObserver, via a `message` MessageEvent whose `data`
  //      is the turbo-stream HTML. The MessageEvent's standard
  //      `lastEventId` field carries the frame's msg_id, so a reactive
  //      runtime that listens for `message` can read the revision without
  //      any pgbus-specific API. (Turbo ignores lastEventId.)
  //
  //   2. A reactive runtime doing optimistic-UI reconciliation, via a
  //      `pgbus:message` CustomEvent carrying { msgId, data }. msgId is the
  //      monotonic per-stream revision (a negative value marks an ephemeral
  //      frame that was never persisted). Pattern: track the highest msgId
  //      you have applied per target; when a frame arrives, skip the morph
  //      if you have already applied a newer revision for that target —
  //      this stops a late echo from clobbering a newer optimistic edit.
  //      Complements #165: exclude handles the actor; this handles
  //      out-of-order delivery for everyone else.
  //
  // msgId is parsed to a Number when numeric so consumers can compare
  // revisions with `>` directly; left as-is otherwise.
  emitTurboStream(data, id) {
    const msgId = id === null || id === undefined || id === "" ? null
      : (Number.isNaN(Number(id)) ? id : Number(id))

    const message = new MessageEvent("message", { data, lastEventId: id == null ? "" : String(id) })
    this.dispatchEvent(message)

    this.dispatchEvent(new CustomEvent("pgbus:message", {
      detail: { msgId, data }
    }))
  }

  // Delivers a typed broadcast (issue #170) — a frame whose SSE event name
  // is something other than turbo-stream (e.g. "presence", "reactive").
  // The payload is still whatever the broadcaster sent (usually a Turbo
  // Stream); the typed name lets a client route without sniffing the HTML.
  // Dispatched two ways for ergonomics:
  //   - a generic `pgbus:event` { event, data, msgId } (one listener for all)
  //   - a named `pgbus:<event>`  { data, msgId }      (addEventListener by name)
  emitTypedEvent(event, data, id) {
    const msgId = id === null || id === undefined || id === "" ? null
      : (Number.isNaN(Number(id)) ? id : Number(id))

    this.dispatchEvent(new CustomEvent("pgbus:event", {
      detail: { event, data, msgId }
    }))
    this.dispatchEvent(new CustomEvent(`pgbus:${event}`, {
      detail: { data, msgId }
    }))
  }

  // Typed event names the EventSource (reconnect) path should listen for,
  // declared by the app via the `listen-events` attribute (comma- or
  // space-separated). EventSource only invokes listeners registered by
  // name, so unlike the fetch path it cannot route unknown typed events
  // generically; declaring them here keeps typed delivery working across
  // reconnects. The fetch (initial) path always routes typed events.
  declaredTypedEvents() {
    const raw = this.getAttribute("listen-events")
    if (!raw) return []
    return raw.split(/[\s,]+/).filter((name) => name && name !== "turbo-stream")
  }

  buildUrl({ includeSince }) {
    const src = this.getAttribute("src")
    const since = includeSince && this.lastEventId ? this.lastEventId : null
    const seat = this.pgbusSeat
    if (!since && !seat) return src

    const url = new URL(src, window.location.origin)
    if (since) url.searchParams.set("since", since)
    if (seat) url.searchParams.set("seat", seat)
    return url.toString()
  }

  safeJsonParse(str) {
    try { return JSON.parse(str) } catch { return null }
  }
}

if (!customElements.get("pgbus-stream-source")) {
  customElements.define("pgbus-stream-source", PgbusStreamSourceElement)
}

export { PgbusStreamSourceElement }
