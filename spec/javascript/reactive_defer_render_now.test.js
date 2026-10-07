// A defer reply renders as soon as it is read (issue #336). The defer lane
// hands the body to Turbo.renderStreamMessage, whose <turbo-stream> elements
// dispatch turbo:before-stream-render synchronously as they connect and then
// `await nextRepaint()` (an animation frame) before `event.detail.render(this)`.
// The lane catches those events, and once every listener has run, calls the
// final detail.render itself — in the same task, in order — and leaves Turbo a
// no-op render for its frame. Turbo's contract is kept: its own event (shape,
// target, cancelable), its own render, preventDefault cancels.
//
// The <turbo-stream> below mirrors Turbo 8's StreamElement (vendored turbo.js
// and turbo-rails 2.0.23: connectedCallback / render / beforeRenderEvent /
// renderElement) and renderStreamMessage (parse, importNode, append), with
// requestAnimationFrame that only runs when a test says so.
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll, beforeEach } from "bun:test"
import { Window } from "happy-dom"

const window = new Window()
let registerReactiveDefer
let resetReactiveDefers
let frames

class TurboStream extends window.HTMLElement {
  static async renderElement(newElement) {
    await newElement.performAction()
  }

  async connectedCallback() {
    try {
      await this.render()
    } catch (error) {
      console.error(error)
    } finally {
      this.remove()
    }
  }

  async render() {
    return (this.renderPromise ??= (async () => {
      const event = this.beforeRenderEvent
      if (this.dispatchEvent(event)) {
        await new Promise((resolve) => requestAnimationFrame(() => resolve()))
        await event.detail.render(this)
      }
    })())
  }

  get performAction() {
    return ACTIONS[this.getAttribute("action")]
  }

  get targetElement() {
    return this.ownerDocument.getElementById(this.getAttribute("target"))
  }

  get templateContent() {
    return this.firstElementChild.content.cloneNode(true)
  }

  get beforeRenderEvent() {
    return new window.CustomEvent("turbo:before-stream-render", {
      bubbles: true,
      cancelable: true,
      detail: { newStream: this, render: TurboStream.renderElement },
    })
  }
}

const ACTIONS = {
  replace() {
    this.targetElement.replaceWith(this.templateContent)
  },
  append() {
    this.targetElement.append(this.templateContent)
  },
}

window.customElements.define("turbo-stream", TurboStream)

function renderStreamMessage(html) {
  const template = document.createElement("template")
  template.innerHTML = html
  const fragment = template.content
  for (const element of fragment.querySelectorAll("turbo-stream")) {
    element.replaceWith(document.importNode(element, true))
  }
  document.documentElement.appendChild(fragment)
}

beforeAll(async () => {
  globalThis.document = window.document
  globalThis.CustomEvent = window.CustomEvent
  mock.module("@hotwired/stimulus", () => ({ Controller: class {} }))
  const mod = await import("../../app/javascript/phlex/reactive/reactive_controller.js")
  await import("../../app/javascript/phlex/reactive/core.js")
  registerReactiveDefer = mod.registerReactiveDefer
  resetReactiveDefers = (await mod.__loadReactiveFeatureForTest("defer")).resetReactiveDefers
})

let rendered
let listeners

beforeEach(() => {
  globalThis.document = window.document
  globalThis.CustomEvent = window.CustomEvent
  globalThis.window = window
  frames = []
  globalThis.requestAnimationFrame = (fn) => frames.push(fn)
  rendered = []
  window.Turbo = {
    StreamActions: {},
    renderStreamMessage: (html) => {
      rendered.push(html)
      renderStreamMessage(html)
    },
  }
  for (const [name, fn] of listeners ?? []) document.removeEventListener(name, fn)
  listeners = []
  // A stream whose frame never ran is still on <html>, as it would be in Turbo.
  document.querySelectorAll("turbo-stream").forEach((stream) => stream.remove())
  document.body.innerHTML = '<div id="menu">loading</div><ul id="list"></ul>'
  resetReactiveDefers()
  registerReactiveDefer()
})

function listen(name, fn) {
  listeners.push([name, fn])
  document.addEventListener(name, fn)
}

function reply(body) {
  globalThis.fetch = () =>
    Promise.resolve({
      ok: true,
      status: 200,
      redirected: false,
      headers: { get: () => "text/vnd.turbo-stream.html" },
      text: () => Promise.resolve(body),
    })
}

async function defer(target = "menu") {
  const attrs = { target, "data-reactive-defer-via": "fetch", "data-reactive-defer-token": "signed" }
  window.Turbo.StreamActions["reactive:defer"].call({ getAttribute: (name) => attrs[name] ?? null })
  for (let i = 0; i < 10; i++) await Promise.resolve()
}

function runFrames() {
  const due = frames
  frames = []
  due.forEach((fn) => fn())
}

const settle = async () => {
  for (let i = 0; i < 10; i++) await Promise.resolve()
}

const REPLACE = '<turbo-stream action="replace" target="menu"><template><div id="menu"><li>item</li></div></template></turbo-stream>'
const append = (text) => `<turbo-stream action="append" target="list"><template><li>${text}</li></template></turbo-stream>`

test("a defer reply lands before the next animation frame", async () => {
  reply(REPLACE)
  await defer()

  expect(rendered).toEqual([REPLACE])
  expect(document.querySelector("#menu li")?.textContent).toBe("item")
})

test("Turbo's frame-later render is a no-op: the stream applies once", async () => {
  reply(append("a"))
  await defer("list")
  expect(document.querySelectorAll("#list li").length).toBe(1)

  runFrames()
  await settle()

  expect(document.querySelectorAll("#list li").length).toBe(1)
  expect(document.querySelector("turbo-stream")).toBeNull()
})

test("turbo:before-stream-render fires once per stream with Turbo's own event", async () => {
  const seen = []
  listen("turbo:before-stream-render", (event) => seen.push(event))
  reply(append("a") + append("b"))
  await defer("list")

  expect(seen.length).toBe(2)
  for (const event of seen) {
    expect(event.cancelable).toBe(true)
    expect(event.bubbles).toBe(true)
    expect(event.detail.newStream).toBe(event.target)
    expect(event.target.localName).toBe("turbo-stream")
    expect(typeof event.detail.render).toBe("function")
  }
})

test("preventDefault() on the event cancels that stream's render", async () => {
  listen("turbo:before-stream-render", (event) => {
    if (event.target.getAttribute("target") === "menu") event.preventDefault()
  })
  reply(REPLACE)
  await defer()
  runFrames()
  await settle()

  expect(document.getElementById("menu").textContent).toBe("loading")
})

test("a listener's replacement detail.render is the one that runs, now", async () => {
  const calls = []
  listen("turbo:before-stream-render", (event) => {
    const original = event.detail.render
    event.detail.render = async (stream) => {
      calls.push(stream.getAttribute("target"))
      await original(stream)
    }
  })
  reply(REPLACE)
  await defer()

  expect(calls).toEqual(["menu"])
  expect(document.querySelector("#menu li")).not.toBeNull()
  runFrames()
  await settle()
  expect(calls).toEqual(["menu"])
})

test("a multi-stream reply keeps its order", async () => {
  reply(append("a") + append("b") + append("c"))
  await defer("list")

  expect([...document.querySelectorAll("#list li")].map((li) => li.textContent)).toEqual(["a", "b", "c"])
})

test("a render that throws is logged, and the next stream still applies", async () => {
  const errors = []
  const realError = console.error
  console.error = (...args) => errors.push(args)
  try {
    reply('<turbo-stream action="nope" target="list"><template><li>x</li></template></turbo-stream>' + append("b"))
    await defer("list")
    await settle()
  } finally {
    console.error = realError
  }

  expect(errors.length).toBeGreaterThan(0)
  expect([...document.querySelectorAll("#list li")].map((li) => li.textContent)).toEqual(["b"])
})

test("without a synchronous event (a Turbo that dispatches later), Turbo renders after its frame", async () => {
  window.Turbo.renderStreamMessage = (html) => {
    rendered.push(html)
    // Nothing connects now: the streams reach the page on a later tick.
    queueMicrotask(() => queueMicrotask(() => renderStreamMessage(html)))
  }
  reply(REPLACE)
  await defer()
  expect(document.getElementById("menu").textContent).toBe("loading")

  await settle()
  runFrames()
  await settle()

  expect(rendered).toEqual([REPLACE])
  expect(document.querySelector("#menu li")?.textContent).toBe("item")
})

test("a Turbo without a <turbo-stream> element still gets the body (renderStreamMessage fallback)", async () => {
  window.Turbo.renderStreamMessage = (html) => rendered.push(html)
  reply(REPLACE)
  await defer()

  expect(rendered).toEqual([REPLACE])
  expect(document.getElementById("menu").textContent).toBe("loading")
})
