// Unit tests for reactive_persist (issue #239) — the client-only localStorage
// draft over a root's OWNED fields. The root carries ONE JSON attr
// (data-reactive-persist = {key, ttl, debounce[, fields][, restore]}); the
// controller writes a snapshot of every persistable owned control on `input`
// (trailing-edge debounce) and `change` (immediate), flushes a pending write on
// disconnect, restores the draft when its feature module has loaded and then
// has the core re-run the connect-time seeds (so show/on-complete/filter/
// compute read the restored DOM; no synthetic events, no morph re-restore),
// and clears it on a successful turbo:submit-end
// of the owning form, on TTL expiry, or via the persist_clear op. The
// persist_state op merges a flat state bag into the same draft.
//
// The draft code is a FEATURE MODULE (issue #275,
// app/javascript/phlex/reactive/features/persist.js). The FIRST root that
// needs it waits for the import; once the module is loaded a root restores
// inside connect() again. Every test awaits controller.featuresReady, which
// covers both, and the last section forces the first-root case to pin what
// that wait must not break.
//
// Uses happy-dom for a real DOM (closest/contains/select multiple/CustomEvent)
// and a Map-backed localStorage stub so storage failures can be simulated.
//
// Run with: bun test spec/javascript
import { test, expect, mock, describe, beforeAll, beforeEach, afterEach } from "bun:test"
import { Window } from "happy-dom"

let ReactiveController
let coldFeatures
let loadFeature

beforeAll(async () => {
  mock.module("@hotwired/stimulus", () => ({ Controller: class {} }))
  const mod = await import("../../app/javascript/phlex/reactive/reactive_controller.js")
  ReactiveController = mod.default
  // Forgets every loaded feature module: the next connect() imports again.
  coldFeatures = mod.__resetReactiveFeaturesForTest
  loadFeature = mod.__loadReactiveFeatureForTest
})

const REAL = {
  document: globalThis.document,
  window: globalThis.window,
  localStorage: globalThis.localStorage,
  setTimeout: globalThis.setTimeout,
  clearTimeout: globalThis.clearTimeout,
  now: Date.now,
  info: console.info,
  warn: console.warn,
  CustomEvent: globalThis.CustomEvent,
  HTMLFormElement: globalThis.HTMLFormElement,
}

let window, storage, timers, now, infos, warns

// Map-backed localStorage with call counters and a throw switch.
function makeStorage() {
  const map = new Map()
  const stub = {
    calls: { get: 0, set: 0, remove: 0 },
    throws: false,
    getItem(k) {
      stub.calls.get++
      if (stub.throws) throw new Error("SecurityError")
      return map.has(k) ? map.get(k) : null
    },
    setItem(k, v) {
      stub.calls.set++
      if (stub.throws) throw new Error("QuotaExceededError")
      map.set(k, String(v))
    },
    removeItem(k) {
      stub.calls.remove++
      if (stub.throws) throw new Error("SecurityError")
      map.delete(k)
    },
    raw: (k) => map.get(k),
    json: (k) => (map.has(k) ? JSON.parse(map.get(k)) : null),
    seed: (k, v) => map.set(k, JSON.stringify(v)),
  }
  return stub
}

beforeEach(() => {
  window = new Window()
  globalThis.document = window.document
  globalThis.window = window
  globalThis.CustomEvent = window.CustomEvent
  globalThis.HTMLFormElement = window.HTMLFormElement
  storage = makeStorage()
  globalThis.localStorage = storage
  timers = []
  globalThis.setTimeout = (fn, ms) => {
    timers.push({ fn, ms, id: timers.length + 1 })
    return timers.length
  }
  globalThis.clearTimeout = (id) => {
    timers = timers.filter((t) => t.id !== id)
  }
  now = 1_000_000
  Date.now = () => now
  infos = []
  warns = []
  console.info = (...a) => infos.push(a.join(" "))
  console.warn = (...a) => warns.push(a.join(" "))
})

afterEach(() => {
  globalThis.document = REAL.document
  globalThis.window = REAL.window
  globalThis.localStorage = REAL.localStorage
  globalThis.setTimeout = REAL.setTimeout
  globalThis.clearTimeout = REAL.clearTimeout
  globalThis.CustomEvent = REAL.CustomEvent
  globalThis.HTMLFormElement = REAL.HTMLFormElement
  Date.now = REAL.now
  console.info = REAL.info
  console.warn = REAL.warn
})

// connect() only STARTS the persist feature's import (issue #275); the restore
// and the write listeners exist once featuresReady has resolved.
async function connect(controller) {
  controller.connect()
  await controller.featuresReady
}

// The same, for "nothing may throw out of connect": a feature that threw is
// caught by the loader and reported on the root instead.
async function connectCleanly(controller) {
  await connect(controller)
  expect(controller.element.getAttribute("data-reactive-error")).toBeNull()
}

function drainTimers() {
  const due = timers
  timers = []
  due.forEach((t) => t.fn())
}

const KEY = "phlex-reactive:persist:apply"
const PAYLOAD = { key: "apply", ttl: 60, debounce: 300 }

function mount(html, { payload = PAYLOAD, rootAttrs = "", form = true } = {}) {
  const attr = payload === null ? "" : `data-reactive-persist='${JSON.stringify(payload)}'`
  const root = `<div id="pf" data-controller="reactive" ${attr} ${rootAttrs}>${html}</div>`
  document.body.innerHTML = form ? `<form id="f">${root}</form><form id="other"></form>` : root
  const el = document.getElementById("pf")
  const controller = new ReactiveController()
  controller.element = el
  controller.tokenValue = "tok"
  return { controller, el, q: (sel) => el.querySelector(sel) }
}

const FORM = `
  <input type="text" name="form[name]">
  <input type="radio" name="form[size]" value="s">
  <input type="radio" name="form[size]" value="l">
  <input type="checkbox" name="form[gift]">
  <select multiple name="form[tags][]"><option value="a">a</option><option value="b">b</option></select>
  <input type="hidden" name="form[tz]" value="UTC">
  <input type="password" name="form[pw]" value="secret">
  <input type="file" name="form[doc]">
  <input type="submit" name="commit" value="Go">
  <input type="text" name="fuckery" data-reactive-persist="off" value="">
  <div data-controller="reactive" id="nested"><input type="text" name="inner" value="x"></div>
`

function fire(el, type) {
  el.dispatchEvent(new window.Event(type, { bubbles: true }))
}

// --- gating ---------------------------------------------------------------

test("a root without reactive_persist touches no storage and installs no timer", async () => {
  const { controller, q } = mount(FORM, { payload: null })
  await connect(controller)
  q('[name="form[name]"]').value = "Ada"
  fire(q('[name="form[name]"]'), "input")
  drainTimers()
  expect(storage.calls).toEqual({ get: 0, set: 0, remove: 0 })
})

test("a malformed payload warns once and disables persistence", async () => {
  document.body.innerHTML = `<div id="pf" data-controller="reactive" data-reactive-persist="{oops"></div>`
  const controller = new ReactiveController()
  controller.element = document.getElementById("pf")
  await connect(controller)
  expect(warns.some((w) => w.includes("reactive_persist"))).toBe(true)
  expect(storage.calls.get).toBe(0)
})

// --- write ----------------------------------------------------------------

test("input debounces (trailing edge) and writes the owned, persistable snapshot", async () => {
  const { controller, q } = mount(FORM)
  await connect(controller)
  q('[name="form[name]"]').value = "Ada"
  fire(q('[name="form[name]"]'), "input")
  expect(storage.calls.set).toBe(0)
  expect(timers.at(-1).ms).toBe(300)
  q('[name="form[size]"][value="l"]').checked = true
  q('[name="form[gift]"]').checked = true
  q('option[value="b"]').selected = true
  drainTimers()
  const draft = storage.json(KEY)
  expect(draft.v).toBe(1)
  expect(draft.savedAt).toBe(now)
  expect(draft.fields).toEqual({
    "form[name]": "Ada",
    "form[size]": "l",
    "form[gift]": true,
    "form[tags][]": ["b"],
  })
  // never: hidden, password, file, submit, the skip marker, a nested root's field
  for (const absent of ["form[tz]", "form[pw]", "form[doc]", "commit", "fuckery", "inner"]) {
    expect(draft.fields).not.toHaveProperty(absent)
  }
})

test("change writes immediately and cancels a pending debounce", async () => {
  const { controller, q } = mount(FORM)
  await connect(controller)
  fire(q('[name="form[name]"]'), "input")
  expect(timers.length).toBe(1)
  q('[name="form[gift]"]').checked = true
  fire(q('[name="form[gift]"]'), "change")
  expect(timers.length).toBe(0)
  expect(storage.json(KEY).fields["form[gift]"]).toBe(true)
})

test("fields: narrows the snapshot to the declared names", async () => {
  const { controller, q } = mount(FORM, { payload: { ...PAYLOAD, fields: ["form[name]"] } })
  await connect(controller)
  q('[name="form[name]"]').value = "Ada"
  q('[name="form[gift]"]').checked = true
  fire(q('[name="form[gift]"]'), "change")
  expect(storage.json(KEY).fields).toEqual({ "form[name]": "Ada" })
})

test("an unchecked radio group is stored as null (so restore leaves it alone)", async () => {
  const { controller, q } = mount(FORM)
  await connect(controller)
  fire(q('[name="form[name]"]'), "change")
  expect(storage.json(KEY).fields["form[size]"]).toBeNull()
})

test("disconnect flushes a pending debounce synchronously", async () => {
  const { controller, q } = mount(FORM)
  await connect(controller)
  q('[name="form[name]"]').value = "Ad"
  fire(q('[name="form[name]"]'), "input")
  expect(storage.calls.set).toBe(0)
  controller.disconnect()
  expect(storage.json(KEY).fields["form[name]"]).toBe("Ad")
  expect(timers.length).toBe(0)
})

// --- restore --------------------------------------------------------------

function seedDraft(fields, extra = {}) {
  storage.seed(KEY, { v: 1, savedAt: now - 1000, fields, ...extra })
}

test("connect restores the draft into BLANK owned controls and leaves server values alone", async () => {
  seedDraft({ "form[name]": "Ada", "form[size]": "l", "form[gift]": true, "form[tags][]": ["a", "b"] })
  const { controller, q } = mount(FORM.replace('name="form[name]"', 'name="form[name]" value="Server"'))
  await connect(controller)
  expect(q('[name="form[name]"]').value).toBe("Server") // non-blank server value wins
  expect(q('[name="form[size]"][value="l"]').checked).toBe(true)
  expect(q('[name="form[gift]"]').checked).toBe(true)
  expect(q('option[value="a"]').selected).toBe(true)
  expect(q('option[value="b"]').selected).toBe(true)
  // the restore itself never writes back (no clobbering the draft with blanks)
  expect(storage.calls.set).toBe(0)
})

test("restore: always overwrites a server-rendered value", async () => {
  seedDraft({ "form[name]": "Ada" })
  const { controller, q } = mount(FORM.replace('name="form[name]"', 'name="form[name]" value="Server"'), {
    payload: { ...PAYLOAD, restore: "always" },
  })
  await connect(controller)
  expect(q('[name="form[name]"]').value).toBe("Ada")
})

test("a draft never reaches an excluded control", async () => {
  seedDraft({ "form[pw]": "leak", "form[tz]": "Mars", fuckery: "bot", inner: "nope", "form[name]": "" })
  const { controller, q } = mount(FORM.replace('name="form[pw]" value="secret"', 'name="form[pw]"'))
  await connect(controller)
  expect(q('[name="form[pw]"]').value).toBe("")
  expect(q('[name="form[tz]"]').value).toBe("UTC")
  expect(q('[name="fuckery"]').value).toBe("")
  expect(q('[name="inner"]').value).toBe("x")
})

test("restore stamps the state bag on the root and emits reactive:persist-restored", async () => {
  seedDraft({ "form[name]": "Ada" }, { state: { step: 2 } })
  const { controller, el } = mount(FORM)
  const seen = []
  el.addEventListener("reactive:persist-restored", (e) => seen.push(e.detail))
  await connect(controller)
  expect(el.getAttribute("data-reactive-persist-state")).toBe('{"step":2}')
  expect(seen).toEqual([{ key: "apply", fields: { "form[name]": "Ada" }, state: { step: 2 } }])
})

test("no event and no attr when there is no draft", async () => {
  const { controller, el } = mount(FORM)
  const seen = []
  el.addEventListener("reactive:persist-restored", (e) => seen.push(e.detail))
  await connect(controller)
  expect(seen).toEqual([])
  expect(el.hasAttribute("data-reactive-persist-state")).toBe(false)
})

test("an expired draft is removed on read and not restored", async () => {
  storage.seed(KEY, { v: 1, savedAt: now - 61_000, fields: { "form[name]": "Old" } })
  const { controller, q } = mount(FORM)
  await connect(controller)
  expect(q('[name="form[name]"]').value).toBe("")
  expect(storage.raw(KEY)).toBeUndefined()
})

test("a draft with another schema version or malformed JSON is discarded silently", async () => {
  storage.seed(KEY, { v: 2, savedAt: now, fields: { "form[name]": "Future" } })
  let m = mount(FORM)
  await connect(m.controller)
  expect(m.q('[name="form[name]"]').value).toBe("")

  storage.setItem(KEY, "{nope")
  m = mount(FORM)
  await connect(m.controller)
  expect(m.q('[name="form[name]"]').value).toBe("")
  expect(warns).toEqual([])
})

test("the show seed is re-run after the restore, so a reactive_show section reads the restored value", async () => {
  seedDraft({ "form[size]": "l" })
  const show = JSON.stringify({ any: [[{ field: "form[size]", equals: "l" }]] })
  const { controller, q } = mount(`${FORM}<div id="sec" data-reactive-show='${show}' hidden>large</div>`)
  await connect(controller)
  expect(q("#sec").hidden).toBe(false)
})

test("a restore never FIRES reactive_on_complete (arm-without-fire)", async () => {
  seedDraft({ "form[name]": "123456" })
  const oc = JSON.stringify([{ any: [[{ field: "form[name]", len_eq: 6 }]], ops: [["add_class", { to: "@root", name: "done" }]] }])
  const { controller, el } = mount(FORM, { rootAttrs: `data-reactive-on-complete='${oc}'` })
  await connect(controller)
  expect(el.classList.contains("done")).toBe(false)
})

test("turbo:morph-element does NOT re-restore (a morph is server truth)", async () => {
  const { controller, el, q } = mount(FORM)
  await connect(controller)
  seedDraft({ "form[name]": "Later" })
  el.dispatchEvent(new window.Event("turbo:morph-element", { bubbles: true }))
  expect(q('[name="form[name]"]').value).toBe("")
})

// --- clear ----------------------------------------------------------------

function submitEnd(form, success) {
  form.dispatchEvent(new window.CustomEvent("turbo:submit-end", { bubbles: true, detail: { success } }))
}

test("a successful turbo:submit-end on the owning form clears the draft", async () => {
  seedDraft({ "form[name]": "Ada" })
  const { controller } = mount(FORM)
  await connect(controller)
  submitEnd(document.getElementById("f"), true)
  expect(storage.raw(KEY)).toBeUndefined()
})

test("a successful submit also drops a pending keystroke write (no resurrection on the disconnect flush)", async () => {
  seedDraft({ "form[name]": "Ada" })
  const { controller, q } = mount(FORM)
  await connect(controller)
  q('[name="form[name]"]').value = "Ada!"
  fire(q('[name="form[name]"]'), "input")
  submitEnd(document.getElementById("f"), true)
  controller.disconnect()
  expect(storage.raw(KEY)).toBeUndefined()
})

test("a failed submit or an unrelated form leaves the draft", async () => {
  seedDraft({ "form[name]": "Ada" })
  const { controller } = mount(FORM)
  await connect(controller)
  submitEnd(document.getElementById("f"), false)
  submitEnd(document.getElementById("other"), true)
  expect(storage.json(KEY).fields["form[name]"]).toBe("Ada")
})

test("disconnect removes the document-level submit-end listener", async () => {
  seedDraft({ "form[name]": "Ada" })
  const { controller } = mount(FORM)
  await connect(controller)
  controller.disconnect()
  submitEnd(document.getElementById("f"), true)
  expect(storage.json(KEY).fields["form[name]"]).toBe("Ada")
})

// --- ops ------------------------------------------------------------------

test("persist_state merges the bag, re-snapshots the fields and stamps the root", async () => {
  seedDraft({ "form[name]": "" }, { state: { step: 1, mode: "wizard" } })
  const { controller, el, q } = mount(FORM)
  await connect(controller)
  q('[name="form[name]"]').value = "Ada"
  controller.runOps({ preventDefault() {}, params: { ops: JSON.stringify([["persist_state", { to: "@root", state: { step: 2 } }]]) } })
  await settle()
  const draft = storage.json(KEY)
  expect(draft.state).toEqual({ step: 2, mode: "wizard" })
  expect(draft.fields["form[name]"]).toBe("Ada")
  expect(el.getAttribute("data-reactive-persist-state")).toBe('{"step":2,"mode":"wizard"}')
})

test("persist_clear removes the draft and the state attr", async () => {
  seedDraft({ "form[name]": "Ada" }, { state: { step: 3 } })
  const { controller, el } = mount(FORM)
  await connect(controller)
  controller.runOps({ preventDefault() {}, params: { ops: JSON.stringify([["persist_clear", { to: "@root" }]]) } })
  await settle()
  expect(storage.raw(KEY)).toBeUndefined()
  expect(el.hasAttribute("data-reactive-persist-state")).toBe(false)
})

test("persist_state on a root without reactive_persist warns and skips", async () => {
  const { controller } = mount(FORM, { payload: null })
  await connect(controller)
  controller.runOps({ preventDefault() {}, params: { ops: JSON.stringify([["persist_state", { to: "@root", state: { step: 2 } }]]) } })
  await settle()
  expect(storage.calls.set).toBe(0)
  expect(warns.some((w) => w.includes("persist_state"))).toBe(true)
})

// --- storage failures -----------------------------------------------------

test("a throwing storage never throws out of connect/write and stays silent without debug", async () => {
  storage.throws = true
  const { controller, q } = mount(FORM)
  await connectCleanly(controller)
  q('[name="form[name]"]').value = "Ada"
  expect(() => fire(q('[name="form[name]"]'), "change")).not.toThrow()
  expect(infos).toEqual([])
})

test("with data-reactive-debug the storage failure is reported once via console.info", async () => {
  storage.throws = true
  const { controller, q } = mount(FORM, { rootAttrs: 'data-reactive-debug="true"' })
  await connect(controller)
  fire(q('[name="form[name]"]'), "change")
  fire(q('[name="form[name]"]'), "change")
  expect(infos.length).toBe(1)
  expect(infos[0]).toContain("reactive_persist")
})

test("a missing localStorage global disables persistence quietly", async () => {
  delete globalThis.localStorage
  const { controller, q } = mount(FORM)
  await connectCleanly(controller)
  expect(() => fire(q('[name="form[name]"]'), "change")).not.toThrow()
})

// --- rich editors (issue #241) --------------------------------------------
//
// Named rich-text editors (lexxy-editor, trix-editor) and bare [contenteditable]
// are persisted through their OWN value surface: an editor's `value`
// getter/setter (the same sanitizing import path a paste takes), a bare
// contenteditable's textContent. Never innerHTML. The stubs below mimic the
// VERIFIED upstream contracts (lexxy 0.9.31, action_text-trix 2.1.19):
//   lexxy-editor: name = attribute, form-associated (no hidden input),
//     `set value` throws before connectedCallback created `this.editor`,
//     `isEmpty` over ["<p><br></p>", "<p></p>", ""], fires lexxy:change.
//   trix-editor: name/value delegate to the `input=` hidden input (the Rails
//     rich_text_area shape) else the element's own name attribute,
//     `set value` → editor.loadHTML (stashed pre-connect), fires trix-change,
//     emptiness via editor.getDocument().isEmpty().
// Both are defined on the per-test happy-dom window's registry; a test that
// needs the "not yet upgraded" path defines them late.

const EMPTY_HTML = ["<p><br></p>", "<p></p>", ""]
let innerHTMLWrites, editorSets

// whenDefined resolves through happy-dom's own promise chain — let the real
// event loop turn (the stubbed global setTimeout is bypassed by Bun.sleep).
const settle = () => Bun.sleep(0)

function defineLexxy() {
  window.customElements.define(
    "lexxy-editor",
    class extends window.HTMLElement {
      connectedCallback() {
        this.editor = { update: () => {} } // upstream: the setter runs inside editor.update
        this.html ??= this.getAttribute("value") ?? "<p><br></p>"
      }
      get name() {
        return this.getAttribute("name")
      }
      get value() {
        return this.html
      }
      set value(html) {
        this.editor.update() // TypeError before connect, like upstream
        editorSets++
        this.html = html
        this.dispatchEvent(new window.CustomEvent("lexxy:change", { bubbles: true }))
      }
      get isEmpty() {
        return EMPTY_HTML.includes(this.value.trim())
      }
      set innerHTML(_html) {
        innerHTMLWrites++
      }
    },
  )
}

function defineTrix() {
  window.customElements.define(
    "trix-editor",
    class extends window.HTMLElement {
      connectedCallback() {
        this.setAttribute("contenteditable", "") // upstream makeEditable(this)
        this.editor = {
          loadHTML: (html) => this.setFormValue(html),
          getDocument: () => ({ isEmpty: () => this.value === "" }),
        }
      }
      get inputElement() {
        return this.hasAttribute("input") ? document.getElementById(this.getAttribute("input")) : undefined
      }
      get name() {
        return this.inputElement ? this.inputElement.name : this.getAttribute("name")
      }
      get value() {
        return this.inputElement ? this.inputElement.value : (this.formValue ?? "")
      }
      set value(html) {
        this.defaultValue = html
        editorSets++
        this.editor?.loadHTML(html)
      }
      setFormValue(html) {
        if (this.inputElement) this.inputElement.value = html
        else this.formValue = html
        this.dispatchEvent(new window.CustomEvent("trix-change", { bubbles: true }))
      }
      set innerHTML(_html) {
        innerHTMLWrites++
      }
    },
  )
}

function mountEditors(html, opts = {}) {
  globalThis.customElements = window.customElements
  innerHTMLWrites = 0
  editorSets = 0
  if (!opts.late) {
    defineLexxy()
    defineTrix()
  }
  return mount(html, opts)
}

const EDITORS = `
  <input type="text" name="draft[title]">
  <lexxy-editor name="draft[body]"></lexxy-editor>
  <input type="hidden" name="draft[notes]" id="notes_trix_input" value="">
  <trix-editor input="notes_trix_input"></trix-editor>
  <trix-editor name="draft[aside]"></trix-editor>
  <div contenteditable="true" name="draft[summary]"></div>
  <div contenteditable="true">unnamed inner editable</div>
  <lexxy-editor name="draft[private]" data-reactive-persist="off"></lexxy-editor>
  <div data-controller="reactive" id="nested"><lexxy-editor name="inner_body"></lexxy-editor></div>
`

test("the snapshot includes named editors under their resolved names, never the paired hidden input", async () => {
  const { controller, q } = mountEditors(EDITORS)
  await connect(controller)
  q("lexxy-editor[name='draft[body]']").value = "<p>Essay</p>"
  q("trix-editor[input]").value = "<div>Notes</div>"
  q("trix-editor[name='draft[aside]']").value = "<div>Aside</div>"
  q("[name='draft[summary]']").textContent = "Plain summary"
  q("[name='draft[private]']").value = "<p>secret</p>"
  fire(q("[name='draft[title]']"), "change")
  expect(storage.json(KEY).fields).toEqual({
    "draft[title]": "",
    "draft[body]": "<p>Essay</p>",
    "draft[notes]": "<div>Notes</div>",
    "draft[aside]": "<div>Aside</div>",
    "draft[summary]": "Plain summary",
  })
})

test("an editor's own chrome (toolbar selects/inputs inside lexxy-editor, a trix-toolbar) is never a control", async () => {
  const html = EDITORS.replace(
    '<lexxy-editor name="draft[body]"></lexxy-editor>',
    `<lexxy-editor name="draft[body]">
       <div class="lexxy-editor__content" contenteditable="true"><p>typed</p></div>
       <lexxy-toolbar><select name="lexxy-code-language"><option value="plain" selected>plain</option></select>
         <input type="url" name="href" value=""></lexxy-toolbar>
     </lexxy-editor>`,
  ).replace("<trix-editor", '<trix-toolbar><input type="url" name="href" value=""></trix-toolbar><trix-editor')
  seedDraft({ "lexxy-code-language": "ruby", href: "https://evil.example", "draft[body]": "<p>Draft</p>" })
  const { controller, q } = mountEditors(html)
  await connect(controller)
  expect(q('[name="lexxy-code-language"]').value).toBe("plain")
  for (const input of el_all(q, '[name="href"]')) expect(input.value).toBe("")
  fire(q("[name='draft[title]']"), "change")
  const fields = storage.json(KEY).fields
  expect(fields).not.toHaveProperty("lexxy-code-language")
  expect(fields).not.toHaveProperty("href")
  expect(fields["draft[body]"]).toBe("<p>Draft</p>")
})

const el_all = (q, sel) => [...q(sel).ownerDocument.querySelectorAll(sel)]

test("restore replays through the editors' own value setters / textContent — never innerHTML", async () => {
  seedDraft({
    "draft[body]": "<p>Essay</p>",
    "draft[notes]": "<div>Notes</div>",
    "draft[aside]": "<div>Aside</div>",
    "draft[summary]": "Plain <b>summary</b>",
  })
  const { controller, q } = mountEditors(EDITORS)
  await connect(controller)
  expect(q("lexxy-editor[name='draft[body]']").value).toBe("<p>Essay</p>")
  expect(q("trix-editor[input]").value).toBe("<div>Notes</div>")
  expect(q("#notes_trix_input").value).toBe("<div>Notes</div>") // via loadHTML → the hidden input
  expect(q("trix-editor[name='draft[aside]']").value).toBe("<div>Aside</div>")
  expect(q("[name='draft[summary]']").textContent).toBe("Plain <b>summary</b>") // text, not markup
  expect(q("[name='draft[summary]']").querySelector("b")).toBeNull()
  expect(innerHTMLWrites).toBe(0)
  expect(storage.calls.set).toBe(0) // the editors' own change events are not `input`/`change`
})

test("restore: blank asks the editor — an empty-looking Lexxy value restores, a non-empty server body wins", async () => {
  seedDraft({ "draft[body]": "<p>Draft</p>", "draft[notes]": "<div>Draft notes</div>", "draft[summary]": "Draft summary" })
  const html = EDITORS.replace(
    'id="notes_trix_input" value=""',
    'id="notes_trix_input" value="<div>Server notes</div>"',
  ).replace('name="draft[summary]">', 'name="draft[summary]">Server summary')
  const { controller, q } = mountEditors(html)
  // Lexxy's initial value is "<p><br></p>" — non-empty as a string, empty per isEmpty
  await connect(controller)
  expect(q("lexxy-editor[name='draft[body]']").value).toBe("<p>Draft</p>")
  expect(q("trix-editor[input]").value).toBe("<div>Server notes</div>")
  expect(q("[name='draft[summary]']").textContent).toBe("Server summary")
})

test("restore: always lets the draft overwrite a server-rendered editor value", async () => {
  seedDraft({ "draft[body]": "<p>Draft</p>", "draft[notes]": "<div>Draft notes</div>", "draft[summary]": "Draft summary" })
  const html = EDITORS.replace('name="draft[body]">', 'name="draft[body]" value="<p>Server</p>">')
    .replace('id="notes_trix_input" value=""', 'id="notes_trix_input" value="<div>Server notes</div>"')
    .replace('name="draft[summary]">', 'name="draft[summary]">Server summary')
  const { controller, q } = mountEditors(html, { payload: { ...PAYLOAD, restore: "always" } })
  await connect(controller)
  expect(q("lexxy-editor[name='draft[body]']").value).toBe("<p>Draft</p>")
  expect(q("trix-editor[input]").value).toBe("<div>Draft notes</div>")
  expect(q("[name='draft[summary]']").textContent).toBe("Draft summary")
})

test("fields:, reactive_persist_skip and nested-root ownership apply to editors", async () => {
  seedDraft({ "draft[body]": "<p>Draft</p>", "draft[private]": "<p>leak</p>", inner_body: "<p>leak</p>", "draft[summary]": "x" })
  const { controller, q } = mountEditors(EDITORS, { payload: { ...PAYLOAD, fields: ["draft[body]", "draft[private]"] } })
  await connect(controller)
  expect(q("lexxy-editor[name='draft[body]']").value).toBe("<p>Draft</p>")
  expect(q("[name='draft[private]']").value).toBe("<p><br></p>")
  expect(q("[name='inner_body']").value).toBe("<p><br></p>")
  expect(q("[name='draft[summary]']").textContent).toBe("")
  q("[name='draft[summary]']").textContent = "typed"
  fire(q("[name='draft[title]']"), "change")
  expect(storage.json(KEY).fields).toEqual({ "draft[body]": "<p>Draft</p>" })
})

test("an editor that has not upgraded yet is omitted from the snapshot and restored once it is defined", async () => {
  seedDraft({ "draft[body]": "<p>Draft</p>", "draft[notes]": "<div>Draft notes</div>", "draft[title]": "T" })
  const { controller, q } = mountEditors(EDITORS, { late: true })
  await connect(controller)
  expect(q("[name='draft[title]']").value).toBe("T")
  fire(q("[name='draft[title]']"), "change")
  expect(storage.json(KEY).fields).not.toHaveProperty("draft[body]")
  expect(storage.json(KEY).fields).not.toHaveProperty("draft[notes]")
  defineLexxy()
  defineTrix()
  await settle()
  expect(q("lexxy-editor[name='draft[body]']").value).toBe("<p>Draft</p>")
  expect(q("trix-editor[input]").value).toBe("<div>Draft notes</div>")
})

test("a deferred restore still honours restore: blank and skips a root that left the document", async () => {
  seedDraft({ "draft[body]": "<p>Draft</p>", "draft[extra]": "<p>Draft extra</p>", "draft[aside]": "<div>Draft aside</div>" })
  const html = EDITORS.replace('name="draft[body]">', 'name="draft[body]" value="<p>Server</p>">').replace(
    "<trix-editor",
    '<lexxy-editor name="draft[extra]"></lexxy-editor><trix-editor',
  )
  const { controller, q, el } = mountEditors(html, { late: true })
  await connect(controller)
  defineLexxy()
  await settle()
  expect(q("lexxy-editor[name='draft[body]']").value).toBe("<p>Server</p>") // blank re-checked at apply time
  expect(q("lexxy-editor[name='draft[extra]']").value).toBe("<p>Draft extra</p>")
  expect(editorSets).toBe(1)
  el.remove()
  defineTrix()
  await settle()
  expect(editorSets).toBe(1) // the root left the document: no Trix apply
})

test("an editor's own change event schedules the draft write (Lexical and Trix don't bubble a native input)", async () => {
  const { controller, q } = mountEditors(EDITORS)
  await connect(controller)
  q("lexxy-editor[name='draft[body]']").value = "<p>Typed</p>" // the stub dispatches lexxy:change
  expect(timers.length).toBe(1) // the same trailing-edge debounce as `input`
  drainTimers()
  expect(storage.json(KEY).fields["draft[body]"]).toBe("<p>Typed</p>")
  q("trix-editor[input]").value = "<div>Typed notes</div>" // dispatches trix-change
  drainTimers()
  expect(storage.json(KEY).fields["draft[notes]"]).toBe("<div>Typed notes</div>")
  controller.disconnect()
  q("lexxy-editor[name='draft[body]']").value = "<p>After</p>"
  expect(timers.length).toBe(0) // listeners dropped on disconnect
})

test("a throwing editor setter never throws out of connect and is reported once under debug only", async () => {
  seedDraft({ "draft[body]": "<p>Draft</p>" })
  const { controller, q } = mountEditors(EDITORS, { rootAttrs: 'data-reactive-debug="true"' })
  Object.defineProperty(q("lexxy-editor[name='draft[body]']"), "editor", { get: () => undefined })
  await connectCleanly(controller)
  expect(infos.length).toBe(1)
  expect(infos[0]).toContain("reactive_persist")
  expect(infos[0]).toContain("draft[body]")
})

test("without debug a throwing editor setter is silent", async () => {
  seedDraft({ "draft[body]": "<p>Draft</p>" })
  const { controller, q } = mountEditors(EDITORS)
  Object.defineProperty(q("lexxy-editor[name='draft[body]']"), "editor", { get: () => undefined })
  await connectCleanly(controller)
  expect(infos).toEqual([])
})

// --- checkbox groups (issue #258) -----------------------------------------

const GROUP = `
  <input type="checkbox" name="features[]" value="news">
  <input type="checkbox" name="features[]" value="events">
  <input type="checkbox" name="features[]" value="maps">
`

test("a group drafts the TICKED VALUES, not one box's checked state", async () => {
  const { controller, el } = mount(GROUP)
  await connect(controller)
  el.querySelector('[value="news"]').checked = true
  el.querySelector('[value="maps"]').checked = true
  fire(el.querySelector('[value="maps"]'), "change")
  drainTimers()

  const draft = storage.json(KEY).fields
  expect(draft["features[]"]).toEqual(["news", "maps"])
})

test("restoring a group ticks exactly the drafted boxes, not all of them", async () => {
  // The bug this guards: with one boolean in the draft, the restore applied it
  // to every box of the group — a draft of "the last box was ticked" came back
  // as "everything is ticked".
  seedDraft({ "features[]": ["events"] })
  const { controller, el } = mount(GROUP)
  await connect(controller)

  expect(el.querySelector('[value="news"]').checked).toBe(false)
  expect(el.querySelector('[value="events"]').checked).toBe(true)
  expect(el.querySelector('[value="maps"]').checked).toBe(false)
})

test("restoring a group with SEVERAL drafted values ticks all of them", async () => {
  // The single-value case above cannot see this: the restore decides "did the
  // server have a say?" per box, and the loop writes `checked` as it goes — so
  // asking from inside it reads this restore's own work, and every box after
  // the first looks server-rendered. Measured before the fix: a draft of
  // ["news","maps"] came back as ["news"] alone.
  seedDraft({ "features[]": ["news", "maps"] })
  const { controller, el } = mount(GROUP)
  await connect(controller)

  expect([...el.querySelectorAll("input")].filter((b) => b.checked).map((b) => b.value)).toEqual(["news", "maps"])
})

test("a group the server rendered ticked still beats the draft", async () => {
  // The counterweight: the guard must keep working, and it reads the state the
  // SERVER left, not the one the restore is writing.
  seedDraft({ "features[]": ["news", "maps"] })
  const { controller, el } = mount(`
    <input type="checkbox" name="features[]" value="news">
    <input type="checkbox" name="features[]" value="events" checked>
    <input type="checkbox" name="features[]" value="maps">
  `)
  await connect(controller)

  expect([...el.querySelectorAll("input")].filter((b) => b.checked).map((b) => b.value)).toEqual(["events"])
})

test("a lone checkbox keeps drafting its boolean", async () => {
  const { controller, el } = mount(`<input type="checkbox" name="gift">`)
  await connect(controller)
  el.querySelector('[name="gift"]').checked = true
  fire(el.querySelector('[name="gift"]'), "change")
  drainTimers()

  expect(storage.json(KEY).fields.gift).toBe(true)
})

test("a contenteditable sharing a group's name appends instead of clobbering the array", async () => {
  // Editors and contenteditables are collected after the native controls, so
  // before the fix the last writer won per name: the contenteditable's string
  // replaced the checkbox's entry and the draft held only "typed" — the
  // toEqual(["a", "typed"]) below is the guard. The throw that empties the
  // draft needs a writer FOLLOWED by a box; that setup is "a text control
  // sharing the group's name".
  const { controller, el } = mount(`
    <input type="checkbox" name="notes[]" value="a">
    <div contenteditable="true" name="notes[]">typed</div>
  `)
  await connect(controller)
  el.querySelector('[value="a"]').checked = true
  fire(el.querySelector('[value="a"]'), "change")
  drainTimers()

  expect(storage.json(KEY).fields["notes[]"]).toEqual(["a", "typed"])
})

test("a radio group keeps its single value even under a [] name", async () => {
  const { controller, el } = mount(`
    <input type="radio" name="plan[]" value="free">
    <input type="radio" name="plan[]" value="pro">
  `)
  await connect(controller)
  el.querySelector('[value="pro"]').checked = true
  fire(el.querySelector('[value="pro"]'), "change")
  drainTimers()

  expect(storage.json(KEY).fields["plan[]"]).toBe("pro")
})

test("a text control sharing the group's name does not kill the draft silently", async () => {
  // The bug this guards is invisible by construction: `.push` on the string a
  // non-checkbox left in the slot throws inside the draft write, persistWrite
  // swallows it, and the root then persists NOTHING — no draft, no console
  // output, nothing to notice. Measured before the fix: storage empty.
  const { controller, el } = mount(`
    <input type="text" name="features[]" value="freeform">
    <input type="checkbox" name="features[]" value="news">
  `)
  await connect(controller)
  el.querySelector('[value="news"]').checked = true
  fire(el.querySelector('[value="news"]'), "change")
  drainTimers()

  expect(storage.json(KEY)).not.toBeNull()
  expect(storage.json(KEY).fields["features[]"]).toEqual(["freeform", "news"])
})

test("a lone control under a [] name keeps its draft round-tripping", async () => {
  // A name ending in `[]` with no second contributor is a list JS maintains,
  // not a group with an ambiguous mapping: the draft has exactly one entry and
  // it can only have come from this control. Measured before the group slot
  // existed, the draft round-tripped; collecting it into an array without this
  // rule dropped it silently.
  seedDraft({ "tags[]": ["typed"] })
  const { controller, el } = mount(`<input type="text" name="tags[]" value="">`)
  await connect(controller)

  expect(el.querySelector("input").value).toBe("typed")
})

test("a list whose rows shrank between visits keeps what the server rendered", async () => {
  // The DOM decides the group SIZE, the draft decides its LENGTH, and the two
  // describe different moments: a JS-maintained row list can have three rows
  // when the draft is written and one when the page comes back. One entry per
  // control is what makes a group of one unambiguous, so both numbers have to
  // be one — the size alone would call this resolvable and pick an entry the
  // field never held.
  seedDraft({ "tags[]": ["one", "two", "three"] })
  const { controller, el } = mount(`<input type="text" name="tags[]" value="">`)
  await connect(controller)

  expect(el.querySelector("input").value).toBe("")
})

test("two generic controls under one [] name keep what the server rendered", async () => {
  // Two contributors and nothing in the draft says which entry was whose, so
  // the ambiguity stands and both keep the server's value.
  seedDraft({ "tags[]": ["one", "two"] })
  const { controller, el } = mount(`
    <input type="text" name="tags[]" value="">
    <input type="text" name="tags[]" value="">
  `)
  await connect(controller)

  expect([...el.querySelectorAll("input")].map((i) => i.value)).toEqual(["", ""])
})

test("restoring a mixed group leaves the text control alone instead of pasting the list", async () => {
  // The draft of a mixed group is ["freeform", "news"] — the text value and the
  // ticked box, in document order. Nothing in it says which element belonged to
  // the text field, so the restore must not guess: it would write
  // "freeform,news" into the input.
  seedDraft({ "features[]": ["freeform", "news"] })
  const { controller, el } = mount(`
    <input type="text" name="features[]" value="">
    <input type="checkbox" name="features[]" value="news">
  `)
  await connect(controller)

  expect(el.querySelector('input[type="text"]').value).toBe("")
  expect(el.querySelector('[value="news"]').checked).toBe(true)
})

test("a group with nothing ticked drafts an empty array", async () => {
  const { controller, el } = mount(`
    <input type="checkbox" name="features[]" value="news">
    <input type="checkbox" name="features[]" value="events">
  `)
  await connect(controller)
  el.querySelector('[value="news"]').checked = true
  fire(el.querySelector('[value="news"]'), "change")
  drainTimers()
  el.querySelector('[value="news"]').checked = false
  fire(el.querySelector('[value="news"]'), "change")
  drainTimers()

  expect(storage.json(KEY).fields["features[]"]).toEqual([])
})

test("restoring a mixed group leaves a contenteditable alone, not 'a,typed'", async () => {
  // The mirror of the snapshot test above. The restore's array guard has to sit
  // ABOVE the editor branch: below it, the very controls that land last in the
  // snapshot — editors and contenteditables — would still receive the whole
  // list stringified.
  seedDraft({ "notes[]": ["a", "typed"] })
  const { controller, el } = mount(`
    <input type="checkbox" name="notes[]" value="a">
    <div contenteditable="true" name="notes[]"></div>
  `)
  await connect(controller)

  expect(el.querySelector("[contenteditable]").textContent).toBe("")
  expect(el.querySelector('[value="a"]').checked).toBe(true)
})

test("a draft from before the group fix does not tick every box of the group", async () => {
  // The upgrade path: 0.13.2 wrote ONE boolean under `features[]` (the bug),
  // and the draft outlives the upgrade — default ttl 7 days. Restoring it the
  // ordinary way hands `true` to every box in the group, which is the very
  // state this fix exists to remove. A group key that is not a list is stale.
  storage.seed(KEY, { v: 1, savedAt: now - 1000, fields: { "features[]": true } })
  const { controller, el } = mount(`
    <input type="checkbox" name="features[]" value="news">
    <input type="checkbox" name="features[]" value="events">
    <input type="checkbox" name="features[]" value="maps">
  `)
  await connect(controller)

  expect([...el.querySelectorAll("input")].filter((b) => b.checked)).toEqual([])
})

test("a stale string under a group name leaves the boxes alone too", async () => {
  // The mixed-group shape of the same old draft: the LAST control to write won,
  // so the key could hold a text value. Boolean("freeform") is true, so without
  // the guard the box ticks on a value that never belonged to it.
  storage.seed(KEY, { v: 1, savedAt: now - 1000, fields: { "features[]": "freeform" } })
  const { controller, el } = mount(`
    <input type="text" name="features[]" value="">
    <input type="checkbox" name="features[]" value="news">
  `)
  await connect(controller)

  expect(el.querySelector('[value="news"]').checked).toBe(false)
  expect(el.querySelector('input[type="text"]').value).toBe("freeform")
})

test("a lone checkbox still restores from a boolean draft", async () => {
  // The counterweight: the guard asks for the `[]` suffix, and a checkbox
  // without one keeps the boolean it has held since #239. Drop the suffix test
  // and this example goes red.
  seedDraft({ "form[gift]": true })
  const { controller, el } = mount(`<input type="checkbox" name="form[gift]">`)
  await connect(controller)

  expect(el.querySelector("input").checked).toBe(true)
})

test("a late editor under a group name is left alone by the DEFERRED restore too", async () => {
  // persistDeferEditors calls persistApplyEditor directly after the custom
  // element upgrades, so the array rule has to be repeated there: the guard
  // above persistApply's branch chain never sees an editor that was not
  // upgraded yet at connect time. Without it the editor takes String(array).
  seedDraft({ "notes[]": ["a", "typed"] })
  const { controller, q } = mountEditors(
    `<input type="checkbox" name="notes[]" value="a">
     <lexxy-editor name="notes[]"></lexxy-editor>`,
    { late: true },
  )
  await connect(controller)
  defineLexxy()
  await settle()

  expect(q("lexxy-editor").value).toBe("<p><br></p>")
  expect(editorSets).toBe(0)
  expect(q('[value="a"]').checked).toBe(true)
})

test("a stale group key does not wipe a multi-select's server selection under restore: always", async () => {
  // 0.13.2 wrote one value per NAME, last writer wins, so a checkbox in a
  // mixed group could leave its boolean under the select's name. Under
  // `restore: "always"` the select branch skips the "the server rendered it"
  // check, and `wanted` = Set{"true"} matches no option — the rendered
  // selection would simply disappear.
  // `note` carries a value of its own in the same draft. Both assertions below
  // would also hold if the draft never arrived at all — a wrong key, an
  // expired ttl, a restore that did not run — so the third one is what makes
  // this a guard rather than a description of an untouched page.
  seedDraft({ "colors[]": true, note: "drafted" })
  const { controller, el } = mount(
    `<input type="checkbox" name="colors[]" value="red">
     <select multiple name="colors[]"><option value="blue" selected>blue</option><option value="green">green</option></select>
     <input type="text" name="note" value="">`,
    { payload: { ...PAYLOAD, restore: "always" } },
  )
  await connect(controller)

  expect([...el.querySelector("select").options].filter((o) => o.selected).map((o) => o.value)).toEqual(["blue"])
  expect(el.querySelector('input[type="checkbox"]').checked).toBe(false)
  expect(el.querySelector('[name="note"]').value).toBe("drafted")
})

test("a late editor does not adopt the single entry a checkbox left in the group", async () => {
  // The one shape where the group SIZE decides and the entry count cannot: an
  // editor that has not upgraded yet is omitted from the snapshot, so a group
  // of two contributors drafts a single entry — the ticked box's value. The
  // editor must not read it just because the list happens to hold one item.
  seedDraft({ "notes[]": ["a"] })
  const { controller, q } = mountEditors(
    `<input type="checkbox" name="notes[]" value="a">
     <lexxy-editor name="notes[]"></lexxy-editor>`,
    { late: true },
  )
  await connect(controller)
  defineLexxy()
  await settle()

  expect(q("lexxy-editor").value).toBe("<p><br></p>")
  expect(editorSets).toBe(0)
  expect(q('[value="a"]').checked).toBe(true)
})

test("a multi-select in a MIXED group keeps the selection the server rendered", async () => {
  // A multi-select reads a list by matching option values, which only holds
  // when the list is its own. Here a text field contributes too, and its value
  // happens to equal an option — measured before the fix, the select came back
  // with both options chosen, one of them the text field's.
  // `note` proves the draft arrived: the select assertion alone would also hold
  // for a draft that never came — wrong key, expired ttl, a restore that did
  // not run.
  seedDraft({ "tags[]": ["blue", "freitext"], note: "drafted" })
  const { controller, el } = mount(
    `<select multiple name="tags[]"><option value="blue" selected>blue</option><option value="freitext">freitext</option></select>
     <input type="text" name="tags[]" value="">
     <input type="text" name="note" value="">`,
    { payload: { ...PAYLOAD, restore: "always" } },
  )
  await connect(controller)

  expect([...el.querySelector("select").options].filter((o) => o.selected).map((o) => o.value)).toEqual(["blue"])
  expect(el.querySelector('[name="note"]').value).toBe("drafted")
})

// --- The restore runs after connect() (issue #275) ----------------------------
//
// On the first root of a page that needs it, the persist module is still on
// its way when the controller connects, so the restore runs a moment after
// connect() instead of inside it. Until it has run the root still shows the
// server's blanks — and nothing may treat those blanks as the user's values.

describe("while the persist module is still on its way", () => {
// Every test here starts with no feature module loaded — the opt-in
// phlex/reactive/core — and hands the default entry's features back after.
beforeEach(() => coldFeatures(true))
afterEach(() => coldFeatures())

// The module has arrived and everything queued on its import has run — for a
// test whose root left, so that nothing awaits featuresReady.
async function moduleArrived() {
  await loadFeature("persist")
  await settle()
}

function requestRig() {
  const posts = []
  window.Turbo = { renderStreamMessage: () => {} }
  globalThis.fetch = (_url, options) => {
    posts.push(JSON.parse(options.body))
    return Promise.resolve({
      redirected: false,
      ok: true,
      status: 200,
      headers: { get: () => "text/vnd.turbo-stream.html" },
      text: () => Promise.resolve(""),
    })
  }
  return posts
}

test("connect() returns before the restore; featuresReady resolves after it", async () => {
  seedDraft({ "form[name]": "Ada" })
  const { controller, q } = mount(FORM)

  controller.connect()
  expect(q('[name="form[name]"]').value).toBe("")

  await controller.featuresReady
  expect(q('[name="form[name]"]').value).toBe("Ada")
})

test("an action dispatched before the restore posts the RESTORED values, once", async () => {
  seedDraft({ "form[name]": "Ada" })
  const posts = requestRig()
  const { controller } = mount(FORM)
  let prevented = false

  controller.connect()
  const done = controller.dispatch({ params: { action: "save", params: "{}" }, preventDefault: () => (prevented = true) })
  expect(prevented).toBe(true)
  await done
  await controller.queue

  expect(posts.map((post) => [post.act, post.params["form[name]"]])).toEqual([["save", "Ada"]])
})

test("a keystroke before the restore writes no draft of the server's blanks", async () => {
  seedDraft({ "form[name]": "Ada", "form[gift]": true })
  const { controller, q } = mount(FORM)

  controller.connect()
  fire(q('[name="form[size]"]'), "change")
  fire(q('[name="form[name]"]'), "input")
  // Nothing wrote, and no debounce is pending: the one timer is the loader's
  // import timeout (not drained — this file's fake clock would fire it).
  expect(storage.calls.set).toBe(0)
  expect(timers.length).toBe(1)
  expect(storage.json(KEY).fields).toEqual({ "form[name]": "Ada", "form[gift]": true })

  await controller.featuresReady
  expect(q('[name="form[name]"]').value).toBe("Ada")
  expect(q('[name="form[gift]"]').checked).toBe(true)
})

test("a field the user filled in before the restore keeps what they typed; the rest of the draft still restores", async () => {
  seedDraft({ "form[name]": "Ada", "form[gift]": true })
  const { controller, q } = mount(FORM)

  controller.connect()
  q('[name="form[name]"]').value = "Grace"
  await controller.featuresReady

  // restore: blank — a non-blank control is never overwritten, whoever filled it.
  expect(q('[name="form[name]"]').value).toBe("Grace")
  expect(q('[name="form[gift]"]').checked).toBe(true)
})

test("persist_state before the restore waits for it instead of drafting the server's blanks", async () => {
  seedDraft({ "form[name]": "Ada" }, { state: { step: 1 } })
  const { controller, el, q } = mount(FORM)

  controller.connect()
  controller.runOps({ preventDefault() {}, params: { ops: JSON.stringify([["persist_state", { to: "@root", state: { step: 2 } }]]) } })
  await controller.featuresReady
  await settle()

  const draft = storage.json(KEY)
  expect(draft.fields["form[name]"]).toBe("Ada")
  expect(draft.state).toEqual({ step: 2 })
  expect(q('[name="form[name]"]').value).toBe("Ada")
  expect(el.getAttribute("data-reactive-persist-state")).toBe('{"step":2}')
})

test("persist_clear before the restore runs after it: the fields restore, then the draft is gone", async () => {
  seedDraft({ "form[name]": "Ada" })
  const { controller, q } = mount(FORM)

  controller.connect()
  controller.runOps({ preventDefault() {}, params: { ops: JSON.stringify([["persist_clear", { to: "@root" }]]) } })
  await controller.featuresReady
  await settle()

  expect(q('[name="form[name]"]').value).toBe("Ada")
  expect(storage.raw(KEY)).toBeUndefined()
})

test("a persist op on a root that is not connected runs at once", async () => {
  seedDraft({ "form[name]": "Ada" })
  const { controller, el } = mount(FORM)
  // Another root's controller carries the op to this one, which never connects.
  el.id = "pf"
  document.body.insertAdjacentHTML("beforeend", `<div id="other-root" data-controller="reactive"></div>`)
  const other = new ReactiveController()
  other.element = document.getElementById("other-root")
  other.connect()

  other.runOps({ preventDefault() {}, params: { ops: JSON.stringify([["persist_clear", { to: "#pf", global: true }]]) } })
  await settle()

  expect(storage.raw(KEY)).toBeUndefined()
  expect(controller.featuresReady).toBeDefined()
})

// Before the split the submit listener existed from connect(). Now the
// feature may still be loading when the form is submitted — and a draft that
// survived a successful submit would come back on the next visit.
function submitEnd(form, success = true) {
  form.dispatchEvent(new window.CustomEvent("turbo:submit-end", { bubbles: true, detail: { success } }))
}

test("a successful submit before the restore forgets the draft, and the late restore brings nothing back", async () => {
  seedDraft({ "form[name]": "Ada" })
  const { controller, q } = mount(FORM)

  controller.connect()
  submitEnd(document.getElementById("f"))
  await controller.featuresReady
  await settle()

  expect(storage.raw(KEY)).toBeUndefined()
  expect(q('[name="form[name]"]').value).toBe("")
})

test("a successful submit before the restore forgets the draft even when the root leaves at once", async () => {
  seedDraft({ "form[name]": "Ada" })
  const { controller } = mount(FORM)

  controller.connect()
  submitEnd(document.getElementById("f"))
  // Turbo's redirect visit: the root is gone before the module arrived.
  controller.disconnect()
  await moduleArrived()

  expect(storage.raw(KEY)).toBeUndefined()
})

test("a failed submit, or another form's, before the restore keeps the draft", async () => {
  seedDraft({ "form[name]": "Ada" })
  const { controller, q } = mount(FORM)

  controller.connect()
  submitEnd(document.getElementById("f"), false)
  submitEnd(document.getElementById("other"))
  await controller.featuresReady
  await settle()

  expect(storage.json(KEY).fields).toEqual({ "form[name]": "Ada" })
  expect(q('[name="form[name]"]').value).toBe("Ada")
})

test("once the feature has connected the core's stand-in submit listener is gone", async () => {
  seedDraft({ "form[name]": "Ada" })
  const { controller } = mount(FORM)
  const added = []
  const removed = []
  const add = document.addEventListener.bind(document)
  const remove = document.removeEventListener.bind(document)
  document.addEventListener = (type, ...rest) => {
    if (type === "turbo:submit-end") added.push(rest[0])
    return add(type, ...rest)
  }
  document.removeEventListener = (type, ...rest) => {
    if (type === "turbo:submit-end") removed.push(rest[0])
    return remove(type, ...rest)
  }

  await connect(controller)

  // Two were added — the core's stand-in, then the feature's own — and the
  // stand-in was removed again (before the feature wired its own).
  expect(added).toHaveLength(2)
  expect(removed).toEqual([added[0]])
})

// --- An edit made before the restore ---------------------------------------------

test("an edit made before the restore is drafted once the module arrives, with the restored fields", async () => {
  seedDraft({ "form[name]": "Ada" })
  const { controller, q } = mount(`${FORM}<input type="text" name="form[city]">`)

  controller.connect()
  q('[name="form[city]"]').value = "Paris"
  fire(q('[name="form[city]"]'), "input")
  expect(storage.calls.set).toBe(0)
  await controller.featuresReady

  // No later keystroke was needed.
  expect(storage.json(KEY).fields["form[city]"]).toBe("Paris")
  expect(storage.json(KEY).fields["form[name]"]).toBe("Ada")
})

test("without an edit before the restore nothing is written at connect", async () => {
  seedDraft({ "form[name]": "Ada" })
  const { controller } = mount(FORM)

  await connect(controller)

  expect(storage.calls.set).toBe(0)
})

// --- The root leaves before the module arrives --------------------------------------

test("an edit on a root that leaves before the module arrives is merged into the draft; the drafted fields are kept", async () => {
  seedDraft({ "form[name]": "Ada", "form[gift]": true })
  const { controller, q } = mount(`${FORM}<input type="text" name="form[city]">`)

  controller.connect()
  q('[name="form[city]"]').value = "Paris"
  fire(q('[name="form[city]"]'), "input")
  controller.disconnect()
  await moduleArrived()

  // The root never restored: its name field and gift box still hold the
  // server's blanks, and those must not overwrite what was drafted.
  expect(storage.json(KEY).fields).toEqual({ "form[name]": "Ada", "form[gift]": true, "form[city]": "Paris" })
})

test("a root that leaves before the module arrives without an edit leaves the draft alone", async () => {
  seedDraft({ "form[name]": "Ada" })
  const { controller } = mount(FORM)

  controller.connect()
  controller.disconnect()
  await moduleArrived()

  expect(storage.calls.set).toBe(0)
  expect(storage.json(KEY).fields).toEqual({ "form[name]": "Ada" })
})

test("persist_state on a root that leaves before the module arrives merges the bag and keeps the drafted fields", async () => {
  seedDraft({ "form[name]": "Ada" }, { state: { step: 1 } })
  const { controller } = mount(FORM)

  controller.connect()
  controller.runOps({ preventDefault() {}, params: { ops: JSON.stringify([["persist_state", { to: "@root", state: { step: 2 } }]]) } })
  controller.disconnect()
  await moduleArrived()

  const draft = storage.json(KEY)
  expect(draft.state).toEqual({ step: 2 })
  expect(draft.fields).toEqual({ "form[name]": "Ada" })
})

test("persist_clear on a root that leaves before the module arrives still forgets the draft", async () => {
  seedDraft({ "form[name]": "Ada" })
  const { controller } = mount(FORM)

  controller.connect()
  controller.runOps({ preventDefault() {}, params: { ops: JSON.stringify([["persist_clear", { to: "@root" }]]) } })
  controller.disconnect()
  await moduleArrived()

  expect(storage.raw(KEY)).toBeUndefined()
})

test("a persist op on a connected root that is NOT waiting for the module runs at once", async () => {
  // A tokenless root that gained data-reactive-persist by a morph: nothing
  // re-scans it, so no restore is coming — the op must not wait for one.
  const { controller, el } = mount(FORM, { payload: null })
  controller.connect()
  el.setAttribute("data-reactive-persist", JSON.stringify(PAYLOAD))
  seedDraft({ "form[name]": "Ada" })

  controller.runOps({ preventDefault() {}, params: { ops: JSON.stringify([["persist_clear", { to: "@root" }]]) } })
  await settle()

  expect(storage.raw(KEY)).toBeUndefined()
})

test("restore: always overwrites what was typed before the restore (as it does for a field typed in before connect)", async () => {
  seedDraft({ "form[name]": "Ada" })
  const { controller, q } = mount(FORM, { payload: { ...PAYLOAD, restore: "always" } })

  controller.connect()
  q('[name="form[name]"]').value = "Grace"
  await controller.featuresReady

  expect(q('[name="form[name]"]').value).toBe("Ada")
})

test("disconnect before the feature arrives restores nothing and wires nothing", async () => {
  seedDraft({ "form[name]": "Ada" })
  const { controller, q } = mount(FORM)

  controller.connect()
  const ready = controller.featuresReady
  controller.disconnect()
  await ready
  fire(q('[name="form[name]"]'), "change")

  expect(q('[name="form[name]"]').value).toBe("")
  expect(storage.calls.set).toBe(0)
})

test("the feature's editor constants match the core's (a feature never imports the core)", async () => {
  const core = await import("../../app/javascript/phlex/reactive/reactive_controller.js")
  const persist = await import("../../app/javascript/phlex/reactive/features/persist.js")

  expect(persist.PERSIST_EDITOR_SELECTOR).toBe(core.EDITOR_SELECTOR)
  expect([...persist.PERSIST_EDITOR_TAGS]).toEqual([...core.EDITOR_TAGS])
})

test("a root without reactive_persist never imports the feature", async () => {
  const { controller } = mount(FORM, { payload: null })
  const before = controller.featuresReady

  controller.connect()

  // No scan hit: featuresReady is the shared, already-resolved promise.
  expect(controller.featuresReady).toBe(before)
})
})

// --- Once the module is loaded -----------------------------------------------------

test("once the module is loaded the restore runs INSIDE connect() again", async () => {
  seedDraft({ "form[name]": "Ada" })
  const warm = mount(FORM)
  await connect(warm.controller)
  warm.controller.disconnect()

  const { controller, q } = mount(FORM)
  controller.connect()

  expect(q('[name="form[name]"]').value).toBe("Ada")
})
