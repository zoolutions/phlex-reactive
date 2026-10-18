// Unit tests for shortcut: on on() and on_client() (issue #357).
//
// The Ruby helper renders a `mod` chord as two window descriptors, a meta twin
// and a ctrl twin, and flags the shortcut (data-reactive-shortcut-param for
// on(), the record's "shortcut" for on_client). Stimulus does the key
// filtering; the client then:
//
//   * runs only the twin for its platform (meta on Apple, ctrl elsewhere) —
//     the other twin is a complete no-op: no dispatch, no preventDefault;
//   * skips an editable target (input, textarea, select, contenteditable,
//     plaintext-only included) unless the shortcut opts in (inEditable);
//   * prevents the chord, synchronously, before any confirm resolver runs —
//     unlike a plain window binding, which is never prevented (#80).
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll, afterEach } from "bun:test"
import { Window } from "happy-dom"

let ReactiveController
let setConfirmResolver

const dom = new Window()
const doc = dom.document

beforeAll(async () => {
  mock.module("@hotwired/stimulus", () => ({
    Controller: class {
      constructor() {}
    },
  }))
  ReactiveController = (await import("../../app/javascript/phlex/reactive/reactive_controller.js")).default
  setConfirmResolver = (await import("../../app/javascript/phlex/reactive/confirm.js")).setConfirmResolver
})

const realNavigator = globalThis.navigator

afterEach(() => {
  Object.defineProperty(globalThis, "navigator", { value: realNavigator, configurable: true, writable: true })
  setConfirmResolver((message) =>
    Promise.resolve(typeof globalThis.window?.confirm === "function" ? globalThis.window.confirm(message) : true)
  )
})

// Stub the platform the client reads (userAgentData first, then platform).
function onPlatform(platform, userAgentData) {
  Object.defineProperty(globalThis, "navigator", {
    value: { platform, userAgentData },
    configurable: true,
    writable: true,
  })
}

function makeRoot() {
  const events = []
  return {
    events,
    isConnected: true,
    id: "editor",
    contains: () => true,
    dispatchEvent: (event) => events.push(event),
    querySelectorAll: () => [],
    setAttribute: () => {},
    removeAttribute: () => {},
    getAttribute: () => null,
  }
}

function buildController(root = makeRoot()) {
  const controller = new ReactiveController()
  controller.element = root
  controller.tokenValue = "tok"
  let calls = 0
  globalThis.fetch = () => {
    calls++
    return Promise.resolve({
      redirected: false,
      ok: true,
      headers: { get: () => "text/vnd.turbo-stream.html" },
      text: () => Promise.resolve(""),
    })
  }
  globalThis.document = { querySelector: () => null, querySelectorAll: () => [], dispatchEvent: () => {} }
  globalThis.window = { Turbo: { renderStreamMessage: () => {} } }
  return { controller, root, calls: () => calls }
}

// A keydown as Stimulus's window listener hands it over.
function keydown(key, { mods = {}, target = doc.body, params = {} } = {}) {
  return {
    type: "keydown",
    key,
    metaKey: false,
    ctrlKey: false,
    altKey: false,
    shiftKey: false,
    ...mods,
    target,
    currentTarget: globalThis.window,
    params,
    defaultPrevented: false,
    preventDefault() {
      this.defaultPrevented = true
    },
  }
}

const undo = (extra = {}) => ({ action: "undo", params: "{}", window: true, shortcut: "mod+z", ...extra })
const flush = () => new Promise((resolve) => setTimeout(resolve, 0))

function editable(html) {
  doc.body.innerHTML = html
  return doc.querySelector("[data-focus]")
}

// --- on(): platform twins ------------------------------------------------------

test("on a Mac, meta+z dispatches once and prevents; ctrl+z is a complete no-op", async () => {
  onPlatform("MacIntel")
  const { controller, root, calls } = buildController()

  const ctrl = keydown("z", { mods: { ctrlKey: true }, params: undo() })
  await controller.dispatch(ctrl)
  expect(calls()).toBe(0)
  expect(ctrl.defaultPrevented).toBe(false)
  expect(root.events).toHaveLength(0)

  const meta = keydown("z", { mods: { metaKey: true }, params: undo() })
  await controller.dispatch(meta)
  await flush()
  expect(meta.defaultPrevented).toBe(true)
  expect(calls()).toBe(1)
})

test("on Windows, ctrl+z dispatches and meta+z does nothing", async () => {
  onPlatform("Win32")
  const { controller, calls } = buildController()

  const meta = keydown("z", { mods: { metaKey: true }, params: undo() })
  await controller.dispatch(meta)
  expect(meta.defaultPrevented).toBe(false)
  expect(calls()).toBe(0)

  const ctrl = keydown("z", { mods: { ctrlKey: true }, params: undo() })
  await controller.dispatch(ctrl)
  await flush()
  expect(ctrl.defaultPrevented).toBe(true)
  expect(calls()).toBe(1)
})

test("userAgentData.platform wins over navigator.platform", async () => {
  onPlatform("Win32", { platform: "macOS" })
  const { controller, calls } = buildController()

  const meta = keydown("z", { mods: { metaKey: true }, params: undo() })
  await controller.dispatch(meta)
  await flush()
  expect(calls()).toBe(1)
})

test("an iPad counts as Apple", async () => {
  onPlatform("iPad")
  const { controller, calls } = buildController()

  await controller.dispatch(keydown("z", { mods: { metaKey: true }, params: undo() }))
  await flush()
  expect(calls()).toBe(1)
})

test("a shortcut without mod runs on every platform", async () => {
  onPlatform("Linux x86_64")
  const { controller, calls } = buildController()

  const esc = keydown("Escape", { params: undo({ action: "close", shortcut: "esc" }) })
  await controller.dispatch(esc)
  await flush()
  expect(esc.defaultPrevented).toBe(true)
  expect(calls()).toBe(1)
})

test("a digit shortcut (typecast to a number by Stimulus) still matches", async () => {
  onPlatform("Linux x86_64")
  const { controller, calls } = buildController()

  await controller.dispatch(keydown("1", { params: undo({ action: "pick", shortcut: 1 }) }))
  await flush()
  expect(calls()).toBe(1)
})

// --- on(): the editable guard ----------------------------------------------------

for (const [label, html] of [
  ["an input", `<input data-focus>`],
  ["a textarea", `<textarea data-focus></textarea>`],
  ["a select", `<select data-focus><option>a</option></select>`],
  ["a child of [contenteditable=true]", `<div contenteditable="true"><p data-focus>x</p></div>`],
  ["a [contenteditable=plaintext-only]", `<div contenteditable="plaintext-only" data-focus></div>`],
]) {
  test(`inside ${label}, the chord dispatches nothing and is not prevented`, async () => {
    onPlatform("MacIntel")
    const target = editable(html)
    const { controller, root, calls } = buildController()

    const event = keydown("z", { mods: { metaKey: true }, target, params: undo() })
    await controller.dispatch(event)
    await flush()
    expect(event.defaultPrevented).toBe(false)
    expect(calls()).toBe(0)
    expect(root.events).toHaveLength(0)
  })
}

test("the Hash form with inEditable dispatches from inside a textarea", async () => {
  onPlatform("MacIntel")
  const target = editable(`<textarea data-focus></textarea>`)
  const { controller, calls } = buildController()

  const event = keydown("Escape", { target, params: undo({ action: "close", shortcut: { keys: "esc", inEditable: true } }) })
  await controller.dispatch(event)
  await flush()
  expect(event.defaultPrevented).toBe(true)
  expect(calls()).toBe(1)
})

test("the chord is prevented before the confirm resolver runs", async () => {
  onPlatform("MacIntel")
  let preventedWhenAsked = null
  const event = keydown("z", { mods: { metaKey: true }, params: undo({ confirm: "Undo?" }) })
  setConfirmResolver(() => {
    preventedWhenAsked = event.defaultPrevented
    return Promise.resolve(false)
  })
  const { controller } = buildController()

  await controller.dispatch(event)
  await flush()
  expect(preventedWhenAsked).toBe(true)
})

test("a plain window keydown binding without shortcut is neither prevented nor guarded (0.14.4 behaviour)", async () => {
  onPlatform("MacIntel")
  const target = editable(`<textarea data-focus></textarea>`)
  const { controller, calls } = buildController()

  const event = keydown("z", { mods: { metaKey: true }, target, params: { action: "undo", params: "{}", window: true } })
  await controller.dispatch(event)
  await flush()
  expect(event.defaultPrevented).toBe(false)
  expect(calls()).toBe(1)
})

// --- on_client --------------------------------------------------------------------

function opsRoot(panel) {
  return {
    ...makeRoot(),
    querySelectorAll: (sel) => (sel === "#palette" ? [panel] : []),
  }
}

const palette = (extra = {}) => ({ on: "keydown", window: true, shortcut: "mod+k", ops: [["toggle", { to: "#palette" }]], ...extra })

function paletteController() {
  const panel = { hidden: true, closest: () => null }
  const root = opsRoot(panel)
  panel.closest = () => root
  const { controller } = buildController(root)
  return { controller, panel }
}

test("on_client: the platform twin runs the ops once and prevents; the other twin is a no-op", () => {
  onPlatform("MacIntel")
  const { controller, panel } = paletteController()

  const ctrl = keydown("k", { mods: { ctrlKey: true }, params: { ops: palette() } })
  controller.runOps(ctrl)
  expect(panel.hidden).toBe(true)
  expect(ctrl.defaultPrevented).toBe(false)

  const meta = keydown("k", { mods: { metaKey: true }, params: { ops: palette() } })
  controller.runOps(meta)
  expect(panel.hidden).toBe(false)
  expect(meta.defaultPrevented).toBe(true)
})

test("on_client: an editable target is skipped unless inEditable", () => {
  onPlatform("Win32")
  const target = editable(`<input data-focus>`)
  const { controller, panel } = paletteController()

  const event = keydown("k", { mods: { ctrlKey: true }, target, params: { ops: palette() } })
  controller.runOps(event)
  expect(panel.hidden).toBe(true)
  expect(event.defaultPrevented).toBe(false)

  const opted = keydown("k", { mods: { ctrlKey: true }, target, params: { ops: palette({ shortcut: { keys: "mod+k", inEditable: true } }) } })
  controller.runOps(opted)
  expect(panel.hidden).toBe(false)
})

test("on_client: two shortcut records on one element — only the record whose chord fired runs", () => {
  onPlatform("MacIntel")
  const panel = { hidden: true, closest: () => null }
  const dialog = { hidden: false, closest: () => null }
  const root = {
    ...makeRoot(),
    querySelectorAll: (sel) => (sel === "#palette" ? [panel] : sel === "#dialog" ? [dialog] : []),
  }
  panel.closest = () => root
  dialog.closest = () => root
  const { controller } = buildController(root)
  const records = [palette(), { on: "keydown", window: true, shortcut: "esc", ops: [["hide", { to: "#dialog" }]] }]
  const wire = records.map((r) => JSON.stringify(r)).join(" ")

  controller.runOps(keydown("Escape", { params: { ops: wire } }))
  expect(dialog.hidden).toBe(true)
  expect(panel.hidden).toBe(true)

  // The wrong twin of mod+k matches its record (it IS that descriptor) but is
  // a no-op on this platform — no warning, no ops.
  const ctrl = keydown("k", { mods: { ctrlKey: true }, params: { ops: wire } })
  controller.runOps(ctrl)
  expect(panel.hidden).toBe(true)
  expect(ctrl.defaultPrevented).toBe(false)
})

// --- keys Stimulus does not know (issue #366) ------------------------------------
// delete and backspace render a BARE `keydown@window` descriptor (Stimulus
// would throw on an unknown key filter), so every keydown reaches the
// controller and the shortcut check alone matches the chord.

const remove = (extra = {}) => ({ action: "remove", params: "{}", window: true, shortcut: "delete", ...extra })

test("bare delete: Delete dispatches once and is prevented", async () => {
  onPlatform("Linux x86_64")
  const { controller, calls } = buildController()

  const event = keydown("Delete", { params: remove() })
  await controller.dispatch(event)
  await flush()
  expect(event.defaultPrevented).toBe(true)
  expect(calls()).toBe(1)
})

test("bare delete: any other key is a complete no-op (not prevented, nothing announced)", async () => {
  onPlatform("Linux x86_64")
  const { controller, root, calls } = buildController()

  for (const key of ["a", "Backspace", "Enter", "Escape"]) {
    const event = keydown(key, { params: remove() })
    await controller.dispatch(event)
    expect(event.defaultPrevented).toBe(false)
  }
  const shifted = keydown("Delete", { mods: { shiftKey: true }, params: remove() })
  await controller.dispatch(shifted)
  await flush()
  expect(shifted.defaultPrevented).toBe(false)
  expect(calls()).toBe(0)
  expect(root.events).toHaveLength(0)
})

for (const [label, html] of [
  ["an input", `<input data-focus>`],
  ["a textarea", `<textarea data-focus></textarea>`],
  ["a select", `<select data-focus><option>a</option></select>`],
  ["a contenteditable", `<div contenteditable="true" data-focus></div>`],
]) {
  test(`bare delete inside ${label} dispatches nothing unless inEditable`, async () => {
    onPlatform("Linux x86_64")
    const target = editable(html)
    const { controller, calls } = buildController()

    const typed = keydown("Delete", { target, params: remove() })
    await controller.dispatch(typed)
    await flush()
    expect(typed.defaultPrevented).toBe(false)
    expect(calls()).toBe(0)

    const opted = keydown("Delete", { target, params: remove({ shortcut: { keys: "delete", inEditable: true } }) })
    await controller.dispatch(opted)
    await flush()
    expect(opted.defaultPrevented).toBe(true)
    expect(calls()).toBe(1)
  })
}

test("bare mod+backspace: Meta+Backspace on a Mac, never Ctrl+Backspace", async () => {
  onPlatform("MacIntel")
  const { controller, calls } = buildController()

  const ctrl = keydown("Backspace", { mods: { ctrlKey: true }, params: remove({ shortcut: "mod+backspace" }) })
  await controller.dispatch(ctrl)
  expect(ctrl.defaultPrevented).toBe(false)
  const bare = keydown("Backspace", { params: remove({ shortcut: "mod+backspace" }) })
  await controller.dispatch(bare)
  expect(bare.defaultPrevented).toBe(false)
  expect(calls()).toBe(0)

  const meta = keydown("Backspace", { mods: { metaKey: true }, params: remove({ shortcut: "mod+backspace" }) })
  await controller.dispatch(meta)
  await flush()
  expect(meta.defaultPrevented).toBe(true)
  expect(calls()).toBe(1)
})

test("bare mod+backspace: Ctrl+Backspace elsewhere, never Meta+Backspace", async () => {
  onPlatform("Win32")
  const { controller, calls } = buildController()

  const meta = keydown("Backspace", { mods: { metaKey: true }, params: remove({ shortcut: "mod+backspace" }) })
  await controller.dispatch(meta)
  expect(meta.defaultPrevented).toBe(false)
  expect(calls()).toBe(0)

  const ctrl = keydown("Backspace", { mods: { ctrlKey: true }, params: remove({ shortcut: "mod+backspace" }) })
  await controller.dispatch(ctrl)
  await flush()
  expect(ctrl.defaultPrevented).toBe(true)
  expect(calls()).toBe(1)
})

test("on_client bare backspace: Backspace runs the ops and prevents; another key does nothing", () => {
  onPlatform("Linux x86_64")
  const { controller, panel } = paletteController()
  const record = palette({ shortcut: "backspace" })

  const other = keydown("x", { params: { ops: record } })
  controller.runOps(other)
  expect(panel.hidden).toBe(true)
  expect(other.defaultPrevented).toBe(false)

  const event = keydown("Backspace", { params: { ops: record } })
  controller.runOps(event)
  expect(panel.hidden).toBe(false)
  expect(event.defaultPrevented).toBe(true)
})

test("on_client bare backspace: a press in an input is left to the field", () => {
  onPlatform("Linux x86_64")
  const target = editable(`<input data-focus>`)
  const { controller, panel } = paletteController()

  const event = keydown("Backspace", { target, params: { ops: palette({ shortcut: "backspace" }) } })
  controller.runOps(event)
  expect(panel.hidden).toBe(true)
  expect(event.defaultPrevented).toBe(false)
})

// --- a key another handler already handled (issue #429) -----------------------
// A keydown whose default a NON-shortcut handler already prevented (the drag
// feature's Escape cancelling a drag, an element-bound keydown binding) is
// not the shortcut's: a complete no-op. A shortcut's OWN preventDefault does
// not count, so two shortcuts on one chord both run, as before. The Hash form
// `handled: true` runs regardless.

const close = (extra = {}) => ({ action: "close", params: "{}", window: true, shortcut: "esc", ...extra })

// Escape as a handler inside the page (a drag, a focused widget) left it.
function handledEscape(params) {
  const event = keydown("Escape", { params })
  event.preventDefault()
  return event
}

test("on(): a keydown another handler prevented dispatches nothing and announces nothing", async () => {
  onPlatform("Linux x86_64")
  const { controller, root, calls } = buildController()

  await controller.dispatch(handledEscape(close()))
  await flush()
  expect(calls()).toBe(0)
  expect(root.events).toHaveLength(0)
})

test("on(): the Hash form with handled: true dispatches after another handler prevented the key", async () => {
  onPlatform("Linux x86_64")
  const { controller, calls } = buildController()

  await controller.dispatch(handledEscape(close({ shortcut: { keys: "esc", handled: true } })))
  await flush()
  expect(calls()).toBe(1)
})

test("on(): an Escape nobody handled still dispatches and is prevented", async () => {
  onPlatform("Linux x86_64")
  const { controller, calls } = buildController()

  const event = keydown("Escape", { params: close() })
  await controller.dispatch(event)
  await flush()
  expect(event.defaultPrevented).toBe(true)
  expect(calls()).toBe(1)
})

test("on(): two shortcuts on one chord both dispatch — the first one's preventDefault does not stop the second", async () => {
  onPlatform("Linux x86_64")
  const first = buildController()
  const second = buildController()

  // Stimulus hands each window binding the SAME event object.
  const event = keydown("Escape", { params: close() })
  await first.controller.dispatch(event)
  await second.controller.dispatch(event)
  await flush()
  expect(event.defaultPrevented).toBe(true)
  // (Both controllers' requests go through the fetch the last build installed.)
  expect(second.calls()).toBe(2)
})

test("on(): handled: true running on a handled key does not make it a shortcut's for the next one", async () => {
  onPlatform("Linux x86_64")
  const first = buildController()
  const second = buildController()

  const event = handledEscape(close({ shortcut: { keys: "esc", handled: true } }))
  await first.controller.dispatch(event)
  event.params = close()
  await second.controller.dispatch(event)
  await flush()
  expect(second.calls()).toBe(1)
})

test("on() and on_client on one chord: the dispatch's preventDefault does not stop the ops", async () => {
  onPlatform("Linux x86_64")
  const { controller, panel } = paletteController()

  const event = keydown("Escape", { params: { ...close(), ops: palette({ shortcut: "esc" }) } })
  await controller.dispatch(event)
  controller.runOps(event)
  expect(event.defaultPrevented).toBe(true)
  expect(panel.hidden).toBe(false)
})

test("on_client: a lone shortcut record skips a key another handler prevented", () => {
  onPlatform("Linux x86_64")
  const { controller, panel } = paletteController()

  controller.runOps(handledEscape({ ops: palette({ shortcut: "esc" }) }))
  expect(panel.hidden).toBe(true)
})

test("on_client: a lone shortcut record with handled: true runs after another handler prevented the key", () => {
  onPlatform("Linux x86_64")
  const { controller, panel } = paletteController()

  controller.runOps(handledEscape({ ops: palette({ shortcut: { keys: "esc", handled: true } }) }))
  expect(panel.hidden).toBe(false)
})

test("on_client: of several records on a handled key, only the handled: true one runs", () => {
  onPlatform("Linux x86_64")
  const panel = { hidden: true, closest: () => null }
  const dialog = { hidden: false, closest: () => null }
  const root = {
    ...makeRoot(),
    querySelectorAll: (sel) => (sel === "#palette" ? [panel] : sel === "#dialog" ? [dialog] : []),
  }
  panel.closest = () => root
  dialog.closest = () => root
  const { controller } = buildController(root)
  const records = [
    palette({ shortcut: { keys: "esc", handled: true } }),
    { on: "keydown", window: true, shortcut: "esc", ops: [["hide", { to: "#dialog" }]] },
  ]
  const wire = records.map((r) => JSON.stringify(r)).join(" ")

  controller.runOps(handledEscape({ ops: wire }))
  expect(panel.hidden).toBe(false)
  expect(dialog.hidden).toBe(false)
})

test("on_client: two shortcut records on one chord both run on a key nobody else handled", () => {
  onPlatform("Linux x86_64")
  const panel = { hidden: true, closest: () => null }
  const dialog = { hidden: false, closest: () => null }
  const root = {
    ...makeRoot(),
    querySelectorAll: (sel) => (sel === "#palette" ? [panel] : sel === "#dialog" ? [dialog] : []),
  }
  panel.closest = () => root
  dialog.closest = () => root
  const { controller } = buildController(root)
  const records = [
    palette({ shortcut: "esc" }),
    { on: "keydown", window: true, shortcut: "esc", ops: [["hide", { to: "#dialog" }]] },
  ]
  const wire = records.map((r) => JSON.stringify(r)).join(" ")

  const event = keydown("Escape", { params: { ops: wire } })
  controller.runOps(event)
  expect(event.defaultPrevented).toBe(true)
  expect(panel.hidden).toBe(false)
  expect(dialog.hidden).toBe(true)
})
