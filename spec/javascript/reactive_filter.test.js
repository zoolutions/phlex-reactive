// Unit tests for client-side option filtering (issue #163) — reactive_filter,
// the "preload + type to narrow" half of the searchable combobox.
//
// The ROOT declares which input drives the filter (data-reactive-filter-input)
// and which elements are the options (data-reactive-filter-option), plus the
// optional group/empty selectors. connect() gates on the root attrs (a root
// without them pays only two attribute reads), installs ONE delegated input
// listener on the root, seeds the initial state, and re-syncs after a
// turbo:morph-element (the reactive_show precedent). Each sync lowercases the
// input's current value and toggles `hidden` on every owned option by a
// substring match against its data-reactive-filter-text haystack (falling back
// to the option's own text) — no round trip, no token. A group whose every
// option is hidden collapses; the empty target is revealed at 0 visible. A
// missing input or absent selectors leave visibility alone (default-deny: a
// bad binding must never break the page).
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll } from "bun:test"

let ReactiveController

beforeAll(async () => {
  mock.module("@hotwired/stimulus", () => ({
    Controller: class {
      constructor() {}
    },
  }))
  ReactiveController = (await import("../../app/javascript/phlex/reactive/reactive_controller.js")).default
})

// A minimal element stub faithful enough for the filter sync:
//   - value for the input read, `hidden` for the visibility toggle
//   - data-controller for the reactive-root ownership predicate
//   - #id, [attr], [attr=value] and [name="X"] selector support
//   - textContent (own text + descendants) for the haystack fallback
//   - attrs-backed get/set/removeAttribute + a listener log with emit()
class FakeNode {
  constructor(opts = {}) {
    const {
      tag = "div",
      id = "",
      name = null,
      type = null,
      value = "",
      text = "",
      controller = null,
      attrs = {},
    } = opts
    this.tag = tag.toLowerCase()
    this.id = id
    this.name = name
    this.type = type
    this.value = value
    this.text = text
    this.hidden = false
    this.parentNode = null
    this.children = []
    this.attrs = { ...attrs }
    this.isConnected = true
    this.listeners = {}
    if (controller) this.attrs["data-controller"] = controller
  }

  append(...nodes) {
    for (const n of nodes) {
      n.parentNode = this
      this.children.push(n)
    }
    return this
  }

  get textContent() {
    return this.text + this.children.map((c) => c.textContent).join("")
  }

  #descendants() {
    const out = []
    for (const child of this.children) out.push(child, ...child.#descendants())
    return out
  }

  matches(selector) {
    if (selector === '[data-controller~="reactive"]') {
      const c = this.attrs["data-controller"]
      return !!c && c.split(/\s+/).includes("reactive")
    }
    // The dirty-tracking + show-binding opt-in probes connect() also runs.
    if (selector === '[data-action*="reactive#trackDirty"]') {
      return (this.attrs["data-action"] ?? "").includes("reactive#trackDirty")
    }
    const byId = selector.match(/^#([\w-]+)$/)
    if (byId) return this.id === byId[1]
    const named = selector.match(/^\[name="(.*)"\]$/)
    if (named) return this.name === named[1]
    const attrEq = selector.match(/^\[([\w-]+)=(?:"([^"]*)"|([^\]"]+))\]$/)
    if (attrEq) return this.getAttribute(attrEq[1]) === (attrEq[2] ?? attrEq[3])
    const attrPresent = selector.match(/^\[([\w-]+)\]$/)
    if (attrPresent) return this.getAttribute(attrPresent[1]) !== null
    return false
  }

  closest(selector) {
    let node = this
    while (node) {
      if (node.matches(selector)) return node
      node = node.parentNode
    }
    return null
  }

  querySelectorAll(selector) {
    return this.#descendants().filter((n) => n.matches(selector))
  }

  getAttribute(name) {
    if (name === "name") return this.name
    return this.attrs[name] ?? null
  }
  setAttribute(name, value) {
    this.attrs[name] = String(value)
  }
  removeAttribute(name) {
    delete this.attrs[name]
  }
  hasAttribute(name) {
    return name in this.attrs
  }
  addEventListener(name, fn) {
    ;(this.listeners[name] ??= []).push(fn)
  }
  removeEventListener(name, fn) {
    this.listeners[name] = (this.listeners[name] ?? []).filter((f) => f !== fn)
  }
  emit(name, event = {}) {
    for (const fn of this.listeners[name] ?? []) fn({ type: name, ...event })
  }
}

function buildController(rootEl) {
  const controller = new ReactiveController()
  controller.element = rootEl
  controller.tokenValue = "tok"
  globalThis.document = { querySelector: () => null, dispatchEvent: () => {} }
  globalThis.window = { addEventListener: () => {}, removeEventListener: () => {} }
  return controller
}

// A combobox root declaring the filter binding (input + option, plus any
// optional group/empty selectors).
function filterRoot(extraAttrs = {}) {
  const root = new FakeNode({
    tag: "div",
    id: "filter-root",
    controller: "reactive",
    attrs: {
      "data-reactive-filter-input": "#search",
      "data-reactive-filter-option": "[role=option]",
      ...extraAttrs,
    },
  })
  return root
}

function searchInput(value = "") {
  return new FakeNode({ tag: "input", id: "search", type: "search", value })
}

// An option row: role=option plus an explicit haystack attr (omit via
// haystack: null to exercise the textContent fallback).
function option(text, haystack = text) {
  const attrs = { role: "option" }
  if (haystack !== null) attrs["data-reactive-filter-text"] = haystack
  return new FakeNode({ tag: "button", text, attrs })
}

test("connect() seeds: a pre-filled input filters the options immediately", () => {
  const root = filterRoot()
  const apple = option("Apple")
  const mango = option("Mango")
  root.append(searchInput("app"), apple, mango)

  buildController(root).connect()

  expect(apple.hidden).toBe(false)
  expect(mango.hidden).toBe(true)
})

test("typing narrows by the data-reactive-filter-text haystack, case-insensitively", () => {
  const root = filterRoot()
  const input = searchInput("")
  const squat = option("Back Squat", "squat barbell legs")
  const bench = option("Bench Press", "bench barbell chest")
  root.append(input, squat, bench)

  buildController(root).connect()
  expect(squat.hidden).toBe(false)
  expect(bench.hidden).toBe(false)

  input.value = "LEGS" // haystack is matched case-folded
  root.emit("input", { target: input })
  expect(squat.hidden).toBe(false)
  expect(bench.hidden).toBe(true)
})

test("the haystack falls back to the option's own text when the attr is absent", () => {
  const root = filterRoot()
  const input = searchInput("cher")
  root.append(input, option("Cherry", null), option("Grape", null))

  buildController(root).connect()

  const [cherry, grape] = root.querySelectorAll("[role=option]")
  expect(cherry.hidden).toBe(false)
  expect(grape.hidden).toBe(true)
})

test("clearing the query reveals every option again", () => {
  const root = filterRoot()
  const input = searchInput("apple")
  const apple = option("Apple")
  const mango = option("Mango")
  root.append(input, apple, mango)

  buildController(root).connect()
  expect(mango.hidden).toBe(true)

  input.value = "  " // whitespace-only counts as cleared (trimmed)
  root.emit("input", { target: input })
  expect(apple.hidden).toBe(false)
  expect(mango.hidden).toBe(false)
})

test("an input event from ANOTHER field does not re-filter", () => {
  const root = filterRoot()
  const input = searchInput("")
  const other = new FakeNode({ tag: "input", id: "other", name: "note", value: "" })
  const mango = option("Mango")
  root.append(input, other, mango)

  buildController(root).connect()

  // The search value changed, but the event came from an unrelated field —
  // the filter must NOT re-run (the option would hide if it did).
  input.value = "apple"
  root.emit("input", { target: other })
  expect(mango.hidden).toBe(false)

  // The same state re-filtered from the NAMED input does hide it.
  root.emit("input", { target: input })
  expect(mango.hidden).toBe(true)
})

test("a group collapses when every contained option is hidden, and reappears", () => {
  const root = filterRoot({ "data-reactive-filter-group": "[data-filter-group]" })
  const input = searchInput("")
  const fruits = new FakeNode({ tag: "div", attrs: { "data-filter-group": "" } })
  const veg = new FakeNode({ tag: "div", attrs: { "data-filter-group": "" } })
  const apple = option("Apple")
  const carrot = option("Carrot")
  fruits.append(apple)
  veg.append(carrot)
  root.append(input, fruits, veg)

  buildController(root).connect()
  expect(fruits.hidden).toBe(false)
  expect(veg.hidden).toBe(false)

  input.value = "apple"
  root.emit("input", { target: input })
  expect(fruits.hidden).toBe(false)
  expect(veg.hidden).toBe(true) // carrot filtered out → the whole group collapses

  input.value = ""
  root.emit("input", { target: input })
  expect(veg.hidden).toBe(false)
})

test("a group with no contained options is left alone", () => {
  const root = filterRoot({ "data-reactive-filter-group": "[data-filter-group]" })
  const input = searchInput("apple")
  const header = new FakeNode({ tag: "div", attrs: { "data-filter-group": "" } })
  root.append(input, header, option("Apple"))

  buildController(root).connect()

  // No options inside → not this filter's group to decide; server state stands.
  expect(header.hidden).toBe(false)
})

test("the empty target is revealed at 0 visible and hidden when matches exist", () => {
  const root = filterRoot({ "data-reactive-filter-empty": "#no-matches" })
  const input = searchInput("")
  const empty = new FakeNode({ tag: "div", id: "no-matches" })
  empty.hidden = true // server renders it hidden
  root.append(input, option("Apple"), option("Mango"), empty)

  buildController(root).connect()
  expect(empty.hidden).toBe(true)

  input.value = "zzz"
  root.emit("input", { target: input })
  expect(empty.hidden).toBe(false)

  input.value = "apple"
  root.emit("input", { target: input })
  expect(empty.hidden).toBe(true)
})

test("a filtered-out option loses its listnav highlight", () => {
  const root = filterRoot()
  const input = searchInput("")
  const apple = option("Apple")
  const mango = option("Mango")
  mango.setAttribute("data-reactive-highlighted", "true")
  root.append(input, apple, mango)

  buildController(root).connect()
  expect(mango.hasAttribute("data-reactive-highlighted")).toBe(true)

  input.value = "apple"
  root.emit("input", { target: input })
  expect(mango.hidden).toBe(true)
  expect(mango.hasAttribute("data-reactive-highlighted")).toBe(false)
})

test("listnav skips hidden options (Arrow keys move among the VISIBLE ones)", () => {
  const root = filterRoot()
  root.setAttribute("data-reactive-listnav-option-param", "[role=option]")
  const input = searchInput("")
  const apple = option("Apple")
  const banana = option("Banana")
  const cherry = option("Cherry")
  banana.hidden = true // filtered out
  root.append(input, apple, banana, cherry)

  const controller = buildController(root)
  controller.connect()
  // connect() seeded with an empty query — that reveals banana again, so
  // re-hide it to model a filtered state for the nav assertion.
  banana.hidden = true

  const event = { currentTarget: root, preventDefault: () => {} }
  controller.listnavNext(event) // highlights Apple
  controller.listnavNext(event) // skips hidden Banana → Cherry
  expect(cherry.hasAttribute("data-reactive-highlighted")).toBe(true)
  expect(banana.hasAttribute("data-reactive-highlighted")).toBe(false)
})

test("no owned input in the DOM leaves visibility untouched (no crash, no flip)", () => {
  const root = filterRoot()
  const shown = option("Apple")
  const hiddenOne = option("Mango")
  hiddenOne.hidden = true
  root.append(shown, hiddenOne)

  expect(() => buildController(root).connect()).not.toThrow()
  expect(shown.hidden).toBe(false)
  expect(hiddenOne.hidden).toBe(true)
})

test("connect() installs NO listeners for a root without filter attrs (the gate)", () => {
  const root = new FakeNode({ tag: "div", id: "plain-root", controller: "reactive" })
  root.append(searchInput(""))

  buildController(root).connect()

  expect(root.listeners.input ?? []).toHaveLength(0)
})

test("nested reactive root: the outer filter neither hides the inner root's options nor counts them", () => {
  const root = filterRoot({ "data-reactive-filter-empty": "#no-matches" })
  const input = searchInput("zzz")
  const inner = new FakeNode({ tag: "div", controller: "reactive" })
  const innerOption = option("Apple")
  inner.append(innerOption)
  const empty = new FakeNode({ tag: "div", id: "no-matches" })
  empty.hidden = true
  root.append(input, inner, empty)

  buildController(root).connect()

  // The inner root's option is not ours to hide — and it doesn't count as
  // visible either, so the (outer) empty target reveals at 0 owned options.
  expect(innerOption.hidden).toBe(false)
  expect(empty.hidden).toBe(false)
})

test("a turbo:morph-element re-syncs from the (Turbo-preserved) input value", () => {
  const root = filterRoot()
  const input = searchInput("apple")
  const apple = option("Apple")
  const mango = option("Mango")
  root.append(input, apple, mango)

  buildController(root).connect()
  expect(mango.hidden).toBe(true)

  // A broadcast morph re-rendered every option visible (server truth) while
  // Turbo preserved the user's typed query — the post-morph re-sync reapplies.
  mango.hidden = false
  root.emit("turbo:morph-element", { target: root })
  expect(mango.hidden).toBe(true)
})

test("disconnect() removes the filter listeners", () => {
  const root = filterRoot()
  const input = searchInput("")
  const mango = option("Mango")
  root.append(input, mango)

  const controller = buildController(root)
  controller.connect()
  controller.disconnect()

  expect(root.listeners.input ?? []).toHaveLength(0)
  expect(root.listeners["turbo:morph-element"] ?? []).toHaveLength(0)

  // A stray event after teardown must not re-filter.
  input.value = "apple"
  root.emit("input", { target: input })
  expect(mango.hidden).toBe(false)
})

// Issue #425: data-reactive-filter-match picks WHERE the query must sit in an
// option's haystack — "substring" (anywhere, the default when absent),
// "prefix" (at its start) or "word_start" (at its start, or right after
// whitespace or one of - ' ( ) , . /) — and data-reactive-filter-fold folds
// diacritics on both sides (NFD, combining marks stripped) before comparing.

const CITIES = ["Århus", "Barcelona", "Berlin", "Nantes", "New York", "Santander", "Zürich"]

// The issue's reproduction: a city list whose haystack is each option's own
// text (no data-reactive-filter-text), filtered word-start + folded.
function cityRoot(attrs) {
  const root = filterRoot(attrs)
  const input = searchInput("")
  const options = Object.fromEntries(CITIES.map((city) => [city, option(city, null)]))
  root.append(input, ...Object.values(options))
  buildController(root).connect()
  const type = (value) => {
    input.value = value
    root.emit("input", { target: input })
    return CITIES.filter((city) => !options[city].hidden)
  }
  return { root, input, options, type }
}

const WORD_START_FOLD = { "data-reactive-filter-match": "word_start", "data-reactive-filter-fold": "true" }

test("word_start + fold: 'n' keeps only the cities that START with N", () => {
  const { type } = cityRoot(WORD_START_FOLD)
  expect(type("n")).toEqual(["Nantes", "New York"])
})

test("word_start + fold: 'ar' matches Århus by its folded start, not Barcelona's interior 'ar'", () => {
  const { type } = cityRoot(WORD_START_FOLD)
  expect(type("ar")).toEqual(["Århus"])
})

test("word_start + fold: 'zur' finds Zürich", () => {
  const { type } = cityRoot(WORD_START_FOLD)
  expect(type("zur")).toEqual(["Zürich"])
})

test("fold: a query typed WITH accents still matches (both sides fold)", () => {
  const { type } = cityRoot(WORD_START_FOLD)
  expect(type("zür")).toEqual(["Zürich"])
  expect(type("ÅR")).toEqual(["Århus"])
})

test("word_start: a multi-word query matches across the separator", () => {
  const { type } = cityRoot(WORD_START_FOLD)
  expect(type("new y")).toEqual(["New York"])
  expect(type("york")).toEqual(["New York"]) // the second word starts after a space
})

test("word_start: the query may start after any declared separator", () => {
  const root = filterRoot({ "data-reactive-filter-match": "word_start" })
  const input = searchInput("")
  const names = ["Côte d'Ivoire", "Guinea-Bissau", "Congo (Kinshasa)", "Bonaire/Sint Eustatius", "St.Kitts", "Korea, South", "Mexico (DF)City"]
  const options = names.map((name) => option(name, null))
  root.append(input, ...options)
  buildController(root).connect()

  const visibleFor = (value) => {
    input.value = value
    root.emit("input", { target: input })
    return names.filter((_, i) => !options[i].hidden)
  }

  expect(visibleFor("ivo")).toEqual(["Côte d'Ivoire"]) // after '
  expect(visibleFor("bis")).toEqual(["Guinea-Bissau"]) // after -
  expect(visibleFor("kin")).toEqual(["Congo (Kinshasa)"]) // after (
  expect(visibleFor("sint")).toEqual(["Bonaire/Sint Eustatius"]) // after a space
  expect(visibleFor("eus")).toEqual(["Bonaire/Sint Eustatius"])
  expect(visibleFor("kit")).toEqual(["St.Kitts"]) // after .
  expect(visibleFor("sou")).toEqual(["Korea, South"]) // after , (and the space)
  expect(visibleFor("cit")).toEqual(["Mexico (DF)City"]) // after )
  expect(visibleFor("ssa")).toEqual([]) // interior only (Bissau)
})

test("word_start: a word-start occurrence after an interior one still matches", () => {
  const root = filterRoot({ "data-reactive-filter-match": "word_start" })
  const input = searchInput("ana")
  const banana = option("Banana Ana", null) // "ana" at 1 and 3 (interior), then at 7
  const havana = option("Havana", null) // interior only
  root.append(input, banana, havana)

  buildController(root).connect()

  expect(banana.hidden).toBe(false)
  expect(havana.hidden).toBe(true)
})

test("prefix: only the haystack's start counts — 'york' hides New York", () => {
  const root = filterRoot({ "data-reactive-filter-match": "prefix" })
  const input = searchInput("york")
  const newYork = option("New York", null)
  const yorkshire = option("Yorkshire", null)
  root.append(input, newYork, yorkshire)

  buildController(root).connect()

  expect(newYork.hidden).toBe(true)
  expect(yorkshire.hidden).toBe(false)
})

test("prefix: leading whitespace in an option's text does not defeat the match", () => {
  const root = filterRoot({ "data-reactive-filter-match": "prefix" })
  const input = searchInput("nan")
  const nantes = option("\n    Nantes\n  ", null) // markup indentation in textContent
  root.append(input, nantes)

  buildController(root).connect()

  expect(nantes.hidden).toBe(false)
})

test("fold applies to the data-reactive-filter-text haystack, which keeps precedence over the text", () => {
  const root = filterRoot({ "data-reactive-filter-fold": "true" })
  const input = searchInput("cote")
  const ivory = option("CI", "Côte d'Ivoire") // the label never says it; the haystack does
  const other = option("Côte", "elsewhere") // the text would match, the haystack does not
  root.append(input, ivory, other)

  buildController(root).connect()

  expect(ivory.hidden).toBe(false)
  expect(other.hidden).toBe(true)
})

test("without fold the accent still decides (fold is opt-in; the default is unchanged)", () => {
  const { type } = cityRoot({})
  expect(type("zur")).toEqual([])
  expect(type("n")).toEqual(["Barcelona", "Berlin", "Nantes", "New York", "Santander"]) // substring
  expect(type("ar")).toEqual(["Barcelona"]) // Århus keeps its å; the interior "ar" counts
})

test("an unknown match mode on the root falls back to substring matching", () => {
  const { type } = cityRoot({ "data-reactive-filter-match": "fuzzy" })
  expect(type("an")).toEqual(["Nantes", "Santander"])
})

test("word_start + fold keeps an already-selected tag hidden (the reactive_tags composition)", () => {
  const root = filterRoot(WORD_START_FOLD)
  const input = searchInput("zu")
  const zurich = option("Zürich", null)
  const zug = option("Zug", null)
  zug.setAttribute("data-reactive-tags-selected", "")
  root.append(input, zurich, zug)

  buildController(root).connect()

  expect(zurich.hidden).toBe(false)
  expect(zug.hidden).toBe(true) // matches the query, but its tag is already a chip
})
