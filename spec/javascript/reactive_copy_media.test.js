// Issue #373: copy a server-rendered image onto a preview, with no URL in any
// op argument or binding attribute.
//
//   ["copy_media", {to, from}]   copies src, srcset and alt from the `from`
//                                <img> onto the `to` <img> (runtime.js op).
//   data-reactive-media='{field, take?, pool, label?, blank?}'
//                                a binding (features/bindings.js): the field's
//                                value (sliced to `take`) is a key into `pool`,
//                                whose value is a SELECTOR for an <img>.
//
// The set_attr refusal of src (issue #96) stays: a raw list that names src
// warns and is skipped.
//
// happy-dom, so selectors and events are real.
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll, beforeEach, afterEach } from "bun:test"
import { Window } from "happy-dom"

const window = new Window()
let ReactiveController
const SAVED = {}
let warnings

beforeAll(async () => {
  mock.module("@hotwired/stimulus", () => ({ Controller: class {} }))
  ReactiveController = (await import("../../app/javascript/phlex/reactive/reactive_controller.js")).default
})

beforeEach(() => {
  for (const key of ["document", "window", "Event", "CustomEvent", "MutationObserver"]) SAVED[key] = globalThis[key]
  SAVED.warn = console.warn
  warnings = []
  console.warn = (...args) => warnings.push(args.join(" "))
  globalThis.document = window.document
  globalThis.window = window
  globalThis.Event = window.Event
  globalThis.CustomEvent = window.CustomEvent
  globalThis.MutationObserver = window.MutationObserver
  document.body.innerHTML = ""
})

afterEach(() => {
  console.warn = SAVED.warn
  delete SAVED.warn
  for (const [key, value] of Object.entries(SAVED)) globalThis[key] = value
})

const flush = () => new Promise((resolve) => setTimeout(resolve, 0))

function mount(html, { connect = false } = {}) {
  document.body.innerHTML = `<div id="r" data-controller="reactive" data-reactive-token-value="t">${html}</div>`
  const root = document.getElementById("r")
  const controller = new ReactiveController()
  controller.element = root
  if (connect) controller.connect()
  const $ = (sel) => document.querySelector(sel)
  return { root, controller, $ }
}

function run(controller, ops) {
  controller.runOps({ params: { ops: JSON.stringify(ops) }, target: controller.element, preventDefault() {} })
}

// Count every attribute write on an element.
function spyWrites(el) {
  const writes = []
  const set = el.setAttribute.bind(el)
  const remove = el.removeAttribute.bind(el)
  el.setAttribute = (name, value) => {
    writes.push(["set", name, value])
    set(name, value)
  }
  el.removeAttribute = (name) => {
    writes.push(["remove", name])
    remove(name)
  }
  return writes
}

const POOL = `
  <img id="logo-007" src="/logos/007.svg" srcset="/logos/007.svg 1x, /logos/007@2x.svg 2x" alt="North" hidden>
  <img id="logo-011" src="/logos/011.svg" alt="South" hidden>
  <img id="no-src" alt="Nothing" hidden>
  <span id="not-img" data-src="/logos/007.svg">North</span>`

// --- the op --------------------------------------------------------------------

test("copy_media copies src, srcset and alt from the source img", () => {
  const { controller, $ } = mount(`<img id="logo" alt="">${POOL}`)
  run(controller, [["copy_media", { to: "#logo", from: "#logo-007" }]])

  expect($("#logo").getAttribute("src")).toBe("/logos/007.svg")
  expect($("#logo").getAttribute("srcset")).toBe("/logos/007.svg 1x, /logos/007@2x.svg 2x")
  expect($("#logo").getAttribute("alt")).toBe("North")
})

test("a source without srcset removes the target's srcset", () => {
  const { controller, $ } = mount(`<img id="logo" alt="">${POOL}`)
  run(controller, [["copy_media", { to: "#logo", from: "#logo-007" }]])
  run(controller, [["copy_media", { to: "#logo", from: "#logo-011" }]])

  expect($("#logo").getAttribute("src")).toBe("/logos/011.svg")
  expect($("#logo").hasAttribute("srcset")).toBe(false)
  expect($("#logo").getAttribute("alt")).toBe("South")
})

test("the same URL a second time writes nothing (the image does not reload)", () => {
  const { controller, $ } = mount(`<img id="logo" alt="">${POOL}`)
  run(controller, [["copy_media", { to: "#logo", from: "#logo-007" }]])
  const writes = spyWrites($("#logo"))

  run(controller, [["copy_media", { to: "#logo", from: "#logo-007" }]])

  expect(writes).toEqual([])
})

for (const [label, from] of [
  ["a missing source", "#nope"],
  ["a source that is not an img", "#not-img"],
  ["a source selector that is a URL (invalid selector)", "https://example.test/a.svg"],
]) {
  test(`${label} clears the target's src, srcset and alt`, () => {
    const { controller, $ } = mount(`<img id="logo" src="/old.svg" srcset="/old.svg 1x" alt="Old">${POOL}`)
    run(controller, [["copy_media", { to: "#logo", from }]])

    expect($("#logo").hasAttribute("src")).toBe(false)
    expect($("#logo").hasAttribute("srcset")).toBe(false)
    expect($("#logo").getAttribute("alt")).toBe("")
  })
}

// Issue #381: an <img> source with an alt and no src is a hit without an
// image — the name survives. Only a missing or non-<img> source clears.
test("a source img without src removes the target's src and srcset and copies its alt", () => {
  const { controller, $ } = mount(`<img id="logo" src="/old.svg" srcset="/old.svg 1x" alt="Old">${POOL}`)
  run(controller, [["copy_media", { to: "#logo", from: "#no-src" }]])

  expect($("#logo").hasAttribute("src")).toBe(false)
  expect($("#logo").hasAttribute("srcset")).toBe(false)
  expect($("#logo").getAttribute("alt")).toBe("Nothing")
})

test("a source img without src ignores a stray srcset on it: no image is copied", () => {
  const { root, controller, $ } = mount(`<img id="logo" src="/old.svg" alt="Old">`)
  root.insertAdjacentHTML("beforeend", `<img id="odd" srcset="/odd.svg 1x" alt="Odd" hidden>`)
  run(controller, [["copy_media", { to: "#logo", from: "#odd" }]])

  expect($("#logo").hasAttribute("src")).toBe(false)
  expect($("#logo").hasAttribute("srcset")).toBe(false)
  expect($("#logo").getAttribute("alt")).toBe("Odd")
})

for (const tag of ["iframe", "script", "object", "embed", "frame", "video", "div"]) {
  test(`a <${tag}> target never receives src (warns and skips)`, () => {
    const { root, controller } = mount(POOL)
    // Built by hand: the HTML parser drops a <frame> outside a <frameset>.
    const target = document.createElement(tag)
    target.id = "t"
    root.append(target)
    run(controller, [["copy_media", { to: "#t", from: "#logo-007" }]])

    expect(target.hasAttribute("src")).toBe(false)
    expect(target.hasAttribute("data")).toBe(false)
    expect(target.hasAttribute("srcset")).toBe(false)
    expect(warnings.some((w) => w.includes("copy_media"))).toBe(true)
  })
}

test("the op ignores any URL-shaped extra arg: only the source element's src is used", () => {
  const { controller, $ } = mount(`<img id="logo" alt="">${POOL}`)
  run(controller, [["copy_media", { to: "#logo", from: "#logo-011", src: "javascript:alert(1)", url: "/evil.svg" }]])

  expect($("#logo").getAttribute("src")).toBe("/logos/011.svg")
})

test("from: resolves inside the root unless global:", () => {
  document.body.innerHTML = ""
  const { controller, $ } = mount(`<img id="logo" alt="">`)
  document.body.insertAdjacentHTML("beforeend", `<img id="outside" src="/outside.svg" alt="Out">`)

  run(controller, [["copy_media", { to: "#logo", from: "#outside" }]])
  expect($("#logo").hasAttribute("src")).toBe(false)

  run(controller, [["copy_media", { to: "#logo", from: "#outside", global: true }]])
  expect($("#logo").getAttribute("src")).toBe("/outside.svg")
})

test("set_attr of src is still refused: warns and skips (issue #96)", () => {
  const { controller, $ } = mount(`<img id="logo" alt="">`)
  run(controller, [["set_attr", { to: "#logo", name: "src", value: "/logos/007.svg" }]])
  run(controller, [["set_attr", { to: "#logo", name: "SRC", value: "javascript:alert(1)" }]])

  expect($("#logo").hasAttribute("src")).toBe(false)
  expect(warnings.filter((w) => w.includes("refused client attr op")).length).toBe(2)
})

test("set_attr of srcset is refused too: warns and skips", () => {
  const { controller, $ } = mount(`<img id="logo" alt="">`)
  run(controller, [["set_attr", { to: "#logo", name: "srcset", value: "/evil.svg 1x" }]])
  run(controller, [["toggle_attr", { to: "#logo", name: "SrcSet" }]])

  expect($("#logo").hasAttribute("srcset")).toBe(false)
  expect(warnings.filter((w) => w.includes("refused client attr op")).length).toBe(2)
})

test("a hand-built binding whose label is @root never rewrites the root's text", async () => {
  const wire = media({ field: "code", pool: { a: "#logo-007" }, label: "@root", blank: "gone" })
  const { root, $ } = mount(`<input name="code" value="zzz"><img id="logo" alt="" data-reactive-media="${wire}">${POOL}`, {
    connect: true,
  })
  await flush()

  type($("[name=code]"), "a")
  expect(root.querySelector("[name=code]")).not.toBeNull()
  expect($("#logo").getAttribute("src")).toBe("/logos/007.svg")
})

// --- the binding -----------------------------------------------------------------

function media(wire) {
  return JSON.stringify(wire).replaceAll('"', "&quot;")
}

const BINDING = media({
  field: "code",
  take: 3,
  pool: { "007": "#logo-007", "011": "#logo-011", nosrc: "#no-src", span: "#not-img", url: "https://example.test/a.svg" },
  label: "#caption",
  blank: "Unknown",
})

function type(input, value) {
  input.value = value
  input.dispatchEvent(new window.Event("input", { bubbles: true }))
}

test("reactive_media copies the pool img whose key is the field's prefix", async () => {
  const { $ } = mount(`<input name="code"><img id="logo" alt="" data-reactive-media="${BINDING}"><span id="caption"></span>${POOL}`, { connect: true })
  await flush()

  type($("[name=code]"), "007-1234")

  expect($("#logo").getAttribute("src")).toBe("/logos/007.svg")
  expect($("#logo").getAttribute("srcset")).toBe("/logos/007.svg 1x, /logos/007@2x.svg 2x")
  expect($("#logo").getAttribute("alt")).toBe("North")
  expect($("#caption").textContent).toBe("North")
})

test("reactive_media clears the preview and writes blank_label on a key miss", async () => {
  const { $ } = mount(`<input name="code"><img id="logo" alt="" data-reactive-media="${BINDING}"><span id="caption"></span>${POOL}`, { connect: true })
  await flush()

  type($("[name=code]"), "007")
  type($("[name=code]"), "999")

  expect($("#logo").hasAttribute("src")).toBe(false)
  expect($("#logo").hasAttribute("srcset")).toBe(false)
  expect($("#logo").getAttribute("alt")).toBe("")
  expect($("#caption").textContent).toBe("Unknown")
})

test("a prefix shorter than take misses", async () => {
  const { $ } = mount(`<input name="code"><img id="logo" alt="" data-reactive-media="${BINDING}"><span id="caption"></span>${POOL}`, { connect: true })
  await flush()

  type($("[name=code]"), "00")
  expect($("#logo").hasAttribute("src")).toBe(false)
})

for (const [label, key] of [
  ["a pool value that is a URL is only a selector", "url"],
  ["a pool selector that is not an img", "spa"],
]) {
  test(`${label}: the preview clears and the value never reaches src`, async () => {
    const wire = media({ field: "code", take: 3, pool: { url: "https://example.test/a.svg", spa: "#not-img" } })
    const { $ } = mount(`<input name="code" value="007"><img id="logo" src="/logos/007.svg" alt="North" data-reactive-media="${wire}">${POOL}`, { connect: true })
    await flush()

    type($("[name=code]"), key)

    expect($("#logo").hasAttribute("src")).toBe(false)
    expect($("#logo").getAttribute("alt")).toBe("")
    expect(document.documentElement.outerHTML).not.toContain('src="https://example.test')
  })
}

// Issue #381: a known entry without an image file keeps its name.
test("a pool img without src is a hit: the preview drops its image and the label gets the alt, not blank_label", async () => {
  const wire = media({ field: "code", take: 3, pool: { "007": "#logo-007", "050": "#no-src" }, label: "#caption", blank: "Unknown" })
  const { $ } = mount(`<input name="code"><img id="logo" alt="" data-reactive-media="${wire}"><span id="caption"></span>${POOL}`, { connect: true })
  await flush()

  type($("[name=code]"), "007")
  expect($("#logo").getAttribute("src")).toBe("/logos/007.svg")
  type($("[name=code]"), "050-1")

  expect($("#logo").hasAttribute("src")).toBe(false)
  expect($("#logo").hasAttribute("srcset")).toBe(false)
  expect($("#logo").getAttribute("alt")).toBe("Nothing")
  expect($("#caption").textContent).toBe("Nothing")
})

test("a pool img with neither src nor alt is still a hit: the label is empty, not blank_label", async () => {
  const wire = media({ field: "code", pool: { a: "#bare" }, label: "#caption", blank: "Unknown" })
  const { $ } = mount(
    `<input name="code"><img id="logo" alt="" data-reactive-media="${wire}"><span id="caption">x</span><img id="bare" hidden>`,
    { connect: true },
  )
  await flush()

  expect($("#caption").textContent).toBe("Unknown")
  type($("[name=code]"), "a")
  expect($("#caption").textContent).toBe("")
  expect($("#logo").getAttribute("alt")).toBe("")
})

test("a missing or non-img pool source still writes blank_label", async () => {
  const wire = media({ field: "code", pool: { gone: "#missing", spa: "#not-img", nos: "#no-src" }, label: "#caption", blank: "Unknown" })
  const { $ } = mount(`<input name="code"><img id="logo" alt="" data-reactive-media="${wire}"><span id="caption"></span>${POOL}`, { connect: true })
  await flush()

  for (const key of ["gone", "spa"]) {
    type($("[name=code]"), "nos")
    expect($("#caption").textContent).toBe("Nothing")
    type($("[name=code]"), key)
    expect($("#caption").textContent).toBe("Unknown")
    expect($("#logo").getAttribute("alt")).toBe("")
  }
})

test("a pool selector that matches nothing clears the preview", async () => {
  const wire = media({ field: "code", pool: { a: "#missing" } })
  const { $ } = mount(`<input name="code"><img id="logo" src="/old.svg" alt="Old" data-reactive-media="${wire}">`, { connect: true })
  await flush()

  type($("[name=code]"), "a")
  expect($("#logo").hasAttribute("src")).toBe(false)
})

test("a pool key from Object.prototype misses", async () => {
  const wire = media({ field: "code", pool: { a: "#logo-007" } })
  const { $ } = mount(`<input name="code"><img id="logo" alt="" data-reactive-media="${wire}">${POOL}`, { connect: true })
  await flush()

  type($("[name=code]"), "constructor")
  expect($("#logo").hasAttribute("src")).toBe(false)
  type($("[name=code]"), "__proto__")
  expect($("#logo").hasAttribute("src")).toBe(false)
})

test("take: counts characters, not UTF-16 code units", async () => {
  const wire = media({ field: "code", take: 1, pool: { "🦊": "#logo-007" } })
  const { $ } = mount(`<input name="code"><img id="logo" alt="" data-reactive-media="${wire}">${POOL}`, { connect: true })
  await flush()

  type($("[name=code]"), "🦊-north")
  expect($("#logo").getAttribute("src")).toBe("/logos/007.svg")
})

test("without take the whole field value is the key", async () => {
  const wire = media({ field: "code", pool: { "007": "#logo-007" } })
  const { $ } = mount(`<input name="code"><img id="logo" alt="" data-reactive-media="${wire}">${POOL}`, { connect: true })
  await flush()

  type($("[name=code]"), "0071")
  expect($("#logo").hasAttribute("src")).toBe(false)
  type($("[name=code]"), "007")
  expect($("#logo").getAttribute("src")).toBe("/logos/007.svg")
})

test("the label is empty on a miss without blank_label, and written via textContent only", async () => {
  const wire = media({ field: "code", pool: { a: "#evil" }, label: "#caption" })
  const { $ } = mount(
    `<input name="code"><img id="logo" alt="" data-reactive-media="${wire}"><span id="caption">x</span>
     <img id="evil" src="/e.svg" alt="<b>bold</b>" hidden>`,
    { connect: true },
  )
  await flush()

  expect($("#caption").textContent).toBe("")
  type($("[name=code]"), "a")
  expect($("#caption").textContent).toBe("<b>bold</b>")
  expect($("#caption").querySelector("b")).toBeNull()
})

test("seeds at connect from the field's current value", async () => {
  const { $ } = mount(`<input name="code" value="011-9"><img id="logo" alt="" data-reactive-media="${BINDING}"><span id="caption"></span>${POOL}`, { connect: true })
  await flush()

  expect($("#logo").getAttribute("src")).toBe("/logos/011.svg")
  expect($("#caption").textContent).toBe("South")
})

test("a radio group contributes its checked value", async () => {
  const wire = media({ field: "pick", pool: { n: "#logo-007", s: "#logo-011" } })
  const { $ } = mount(
    `<input type="radio" name="pick" value="n"><input type="radio" name="pick" value="s">
     <img id="logo" alt="" data-reactive-media="${wire}">${POOL}`,
    { connect: true },
  )
  await flush()

  const south = $("[name=pick][value=s]")
  south.checked = true
  south.dispatchEvent(new window.Event("change", { bubbles: true }))
  expect($("#logo").getAttribute("src")).toBe("/logos/011.svg")
})

test("re-typing within the same key writes nothing", async () => {
  const { $ } = mount(`<input name="code"><img id="logo" alt="" data-reactive-media="${BINDING}"><span id="caption"></span>${POOL}`, { connect: true })
  await flush()
  type($("[name=code]"), "007")
  const writes = spyWrites($("#logo"))

  type($("[name=code]"), "0071")
  type($("[name=code]"), "00712")

  expect(writes).toEqual([])
})

test("an unowned field leaves the preview alone", async () => {
  const wire = media({ field: "code", pool: { a: "#logo-007" } })
  const { $ } = mount(`<img id="logo" src="/kept.svg" alt="Kept" data-reactive-media="${wire}">${POOL}`, { connect: true })
  await flush()

  expect($("#logo").getAttribute("src")).toBe("/kept.svg")
})

test("a binding on a non-img element warns and never sets src", async () => {
  const wire = media({ field: "code", pool: { a: "#logo-007" } })
  const { $ } = mount(`<input name="code" value="a"><iframe id="frame" data-reactive-media="${wire}"></iframe>${POOL}`, { connect: true })
  await flush()

  expect($("#frame").hasAttribute("src")).toBe(false)
  expect(warnings.some((w) => w.includes("copy_media"))).toBe(true)
})

test("a scoped field resolves under reactive_scope", async () => {
  const wire = media({ field: "code", pool: { a: "#logo-007" } })
  document.body.innerHTML = `<div id="r" data-controller="reactive" data-reactive-scope="brand">
    <input name="brand[code]" value="a"><img id="logo" alt="" data-reactive-media="${wire}">${POOL}</div>`
  const controller = new ReactiveController()
  controller.element = document.getElementById("r")
  controller.connect()
  await flush()

  expect(document.querySelector("#logo").getAttribute("src")).toBe("/logos/007.svg")
})
