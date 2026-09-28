// Unit test for reactive_compute and CHECKED-STATE controls (issue #262).
//
// #recompute resolved every declared name FIRST-WINS and read `.value`. For a
// checkbox that is a constant, whatever the box's state:
//
//   Rails check_box (hidden "0" + box "1")   the hidden comes first → always 0
//   lone <input type=checkbox value="1">     .value never changes   → always 1
//   lone <input type=checkbox>               Number("on") is NaN    → always 0
//
// A radio group read the FIRST radio's value, whichever radio was checked. And
// an output that resolved to a checkbox pair wrote `.value` on the hidden
// companion — changing what the UNCHECKED state submits, leaving the box alone.
//
// The fix: a checkbox's compute value is its checked state, coerced by the
// declared input type (:number 1/0, :string "true"/"false", :boolean
// true/false); a radio group reads its checked radio; an output sets `checked`.
// The checkbox wins over its same-named hidden companion, as #showFieldValue
// already does for reactive_show.
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll, beforeEach, describe } from "bun:test"

let ReactiveController
let computeModule

beforeAll(async () => {
  mock.module("@hotwired/stimulus", () => ({
    Controller: class {
      constructor() {}
    },
  }))
  ReactiveController = (await import("../../app/javascript/phlex/reactive/reactive_controller.js")).default
  computeModule = await import("../../app/javascript/phlex/reactive/compute.js")
})

beforeEach(() => {
  computeModule.__resetComputeRegistryForTest()
})

// A fake named control with REAL DOM semantics for the properties the compute
// path touches: `.value` coerces to String and fires nothing; `.checked` is a
// plain boolean property; a checkbox rendered without a value attribute reports
// "on". `events` records every dispatched event type, so a test can assert the
// write dispatched exactly one `input`.
function control({ name, type = "text", value = "", checked = false }) {
  return {
    name,
    type,
    tagName: "INPUT",
    checked,
    events: [],
    _root: null,
    _value: String(value),
    get value() {
      return this._value
    },
    set value(v) {
      this._value = String(v)
    },
    closest() {
      return this._root
    },
    dispatchEvent(event) {
      Object.defineProperty(event, "target", { value: this, configurable: true })
      this.events.push(event.type)
      return true
    },
  }
}

const hidden = (name, value = "0") => control({ name, type: "hidden", value })
const checkbox = (name, { value = "1", checked = false } = {}) => control({ name, type: "checkbox", value, checked })
const radio = (name, value, checked = false) => control({ name, type: "radio", value, checked })

// A text node sink for reactive_text / the identity mirror.
function textNode(name) {
  return { _root: null, textName: name, textContent: "", closest() { return this._root } }
}

// The root answers the per-name `[name="X"]` query the resolver issues with
// EVERY control carrying that name, in document order — the Rails pair is
// [hidden, checkbox], a radio group is every radio.
function makeRoot({ reducer = "calc", inputs, outputs = [], controls, texts = [], scope = null, nestedRoots = [] }) {
  const attrs = {
    "data-reactive-compute-reducer-param": reducer,
    "data-reactive-compute-inputs-param": JSON.stringify(inputs),
    "data-reactive-compute-outputs-param": JSON.stringify(outputs),
    "data-reactive-scope": scope,
  }
  const root = {
    id: "order",
    getAttribute: (k) => attrs[k] ?? null,
    querySelectorAll: (sel) => {
      if (sel === '[data-controller~="reactive"]') return nestedRoots
      const named = sel.match(/\[name="(.+?)"\]/)
      if (named) return controls.filter((c) => c.name === named[1])
      const text = sel.match(/\[data-reactive-text="(.+?)"\]/)
      if (text) return texts.filter((t) => t.textName === text[1])
      return []
    },
    closest: () => null,
  }
  for (const c of [...controls, ...texts]) c._root ??= root
  return root
}

function buildController(root) {
  const controller = new ReactiveController()
  controller.element = root
  globalThis.window ??= {}
  return controller
}

// Run one recompute and hand back the `values` bag the reducer received.
function valuesSeen({ inputs, controls, scope = null, event = undefined, nestedRoots = [] }) {
  let seen = null
  let meta = null
  computeModule.setComputeReducer("calc", (values, m) => {
    seen = values
    meta = m
    return {}
  })
  buildController(makeRoot({ inputs, controls, scope, nestedRoots })).recompute(event)
  return { values: seen, meta }
}

describe("a checkbox input reads its checked state", () => {
  test("Rails pair, untyped (number): the box wins over its hidden companion", () => {
    const unchecked = valuesSeen({ inputs: ["gift"], controls: [hidden("gift"), checkbox("gift")] })
    expect(unchecked.values).toEqual({ gift: 0 })

    const checked = valuesSeen({ inputs: ["gift"], controls: [hidden("gift"), checkbox("gift", { checked: true })] })
    expect(checked.values).toEqual({ gift: 1 })
  })

  test("a lone box with value=\"1\" reads 0 when unchecked, not its constant value", () => {
    expect(valuesSeen({ inputs: ["gift"], controls: [checkbox("gift")] }).values).toEqual({ gift: 0 })
    expect(valuesSeen({ inputs: ["gift"], controls: [checkbox("gift", { checked: true })] }).values).toEqual({ gift: 1 })
  })

  test("a lone box with no value attribute (\"on\") reads 1 when checked, not NaN→0", () => {
    const box = checkbox("gift", { value: "on", checked: true })
    expect(valuesSeen({ inputs: ["gift"], controls: [box] }).values).toEqual({ gift: 1 })
  })

  test("the box's own value is NOT the reading — a checked value=\"250\" is 1", () => {
    const box = checkbox("gift", { value: "250", checked: true })
    expect(valuesSeen({ inputs: ["gift"], controls: [box] }).values).toEqual({ gift: 1 })
  })

  test(":string reads \"true\"/\"false\" — what reactive_show compares against", () => {
    const inputs = { gift: "string" }
    expect(valuesSeen({ inputs, controls: [hidden("gift"), checkbox("gift")] }).values).toEqual({ gift: "false" })
    expect(valuesSeen({ inputs, controls: [hidden("gift"), checkbox("gift", { checked: true })] }).values).toEqual({
      gift: "true",
    })
  })

  test(":boolean reads a real boolean", () => {
    const inputs = { gift: "boolean" }
    expect(valuesSeen({ inputs, controls: [hidden("gift"), checkbox("gift")] }).values).toEqual({ gift: false })
    expect(valuesSeen({ inputs, controls: [hidden("gift"), checkbox("gift", { checked: true })] }).values).toEqual({
      gift: true,
    })
  })

  test("the permit form mixes a :boolean box with numeric fields", () => {
    const controls = [control({ name: "price", value: "100" }), hidden("gift"), checkbox("gift", { checked: true })]
    const { values } = valuesSeen({ inputs: { price: "number", gift: "boolean" }, controls })
    expect(values).toEqual({ price: 100, gift: true })
  })

  test("toggling the box names it as meta.changed", () => {
    const box = checkbox("gift", { checked: true })
    const { meta } = valuesSeen({ inputs: ["gift"], controls: [hidden("gift"), box], event: { target: box } })
    expect(meta).toEqual({ changed: "gift" })
  })

  test("under data-reactive-scope a bare name resolves the scoped pair", () => {
    const controls = [hidden("order[gift]"), checkbox("order[gift]", { checked: true })]
    const { values } = valuesSeen({ inputs: { gift: "boolean" }, controls, scope: "order" })
    expect(values).toEqual({ gift: true })
  })

  test("a box owned by a NESTED reactive root is not read (issue #15)", () => {
    const nestedRoot = { id: "nested" }
    const nested = checkbox("gift", { checked: true })
    nested._root = nestedRoot // closest() resolves to the nested root, not ours
    const { values } = valuesSeen({ inputs: { gift: "boolean" }, controls: [nested], nestedRoots: [nestedRoot] })
    expect(values).toEqual({ gift: false })
  })

  test("our own unchecked box is read even when a nested root's checked box comes first", () => {
    const nestedRoot = { id: "nested" }
    const nested = checkbox("gift", { checked: true })
    nested._root = nestedRoot
    const controls = [nested, hidden("gift"), checkbox("gift")]
    const { values } = valuesSeen({ inputs: ["gift"], controls, nestedRoots: [nestedRoot] })
    expect(values).toEqual({ gift: 0 })
  })
})

describe(":boolean on a control that is not a checkbox", () => {
  for (const [value, expected] of [
    ["", false],
    ["0", false],
    ["false", false],
    ["1", true],
    ["true", true],
    ["yes", true],
  ]) {
    test(`a field holding ${JSON.stringify(value)} reads ${expected}`, () => {
      const { values } = valuesSeen({ inputs: { flag: "boolean" }, controls: [control({ name: "flag", value })] })
      expect(values).toEqual({ flag: expected })
    })
  }

  test("an absent field reads false", () => {
    expect(valuesSeen({ inputs: { flag: "boolean" }, controls: [] }).values).toEqual({ flag: false })
  })
})

describe("a radio group reads its CHECKED radio", () => {
  const group = (checkedValue) => ["10", "20", "30"].map((v) => radio("rate", v, v === checkedValue))

  test("untyped (number): the checked radio's value, not the first radio's", () => {
    expect(valuesSeen({ inputs: ["rate"], controls: group("20") }).values).toEqual({ rate: 20 })
  })

  test("untyped (number): 0 when no radio is checked", () => {
    expect(valuesSeen({ inputs: ["rate"], controls: group(null) }).values).toEqual({ rate: 0 })
  })

  test(":string: the checked value, \"\" when none", () => {
    const inputs = { rate: "string" }
    expect(valuesSeen({ inputs, controls: group("30") }).values).toEqual({ rate: "30" })
    expect(valuesSeen({ inputs, controls: group(null) }).values).toEqual({ rate: "" })
  })
})

describe("plain fields are untouched (regression guards)", () => {
  test("a hidden input WITHOUT a same-named checkbox is an ordinary value", () => {
    expect(valuesSeen({ inputs: ["tier"], controls: [hidden("tier", "3")] }).values).toEqual({ tier: 3 })
  })

  test("same-named plain fields stay first-wins", () => {
    const controls = [control({ name: "qty", value: "2" }), control({ name: "qty", value: "9" })]
    expect(valuesSeen({ inputs: ["qty"], controls }).values).toEqual({ qty: 2 })
  })

  test("blank/NaN numeric fields still coerce to 0, :string still reads raw", () => {
    const controls = [control({ name: "qty", value: "" }), control({ name: "title", value: "abc" })]
    const { values } = valuesSeen({ inputs: { qty: "number", title: "string" }, controls })
    expect(values).toEqual({ qty: 0, title: "abc" })
  })
})

describe("an output that resolves to a checkbox sets checked", () => {
  function run(result, box, companion = hidden("free")) {
    computeModule.setComputeReducer("calc", () => result)
    const controls = [control({ name: "total", value: "100" }), companion, box]
    buildController(makeRoot({ inputs: ["total"], outputs: ["free"], controls })).recompute()
    return { box, companion }
  }

  test("a truthy result ticks the box and leaves both value attributes alone", () => {
    const { box, companion } = run({ free: true }, checkbox("free"))
    expect(box.checked).toBe(true)
    expect(box.value).toBe("1")
    expect(companion.value).toBe("0")
    expect(box.events).toEqual(["input"])
    expect(companion.events).toEqual([])
  })

  test("a falsy result unticks it", () => {
    const { box } = run({ free: false }, checkbox("free", { checked: true }))
    expect(box.checked).toBe(false)
    expect(box.events).toEqual(["input"])
  })

  for (const falsy of [0, "0", "", "false"]) {
    test(`${JSON.stringify(falsy)} counts as unticked`, () => {
      expect(run({ free: falsy }, checkbox("free", { checked: true })).box.checked).toBe(false)
    })
  }

  test("an unchanged state dispatches nothing (the change guard)", () => {
    const { box } = run({ free: 1 }, checkbox("free", { checked: true }))
    expect(box.checked).toBe(true)
    expect(box.events).toEqual([])
  })
})

describe("an output that resolves to a radio group checks the matching radio", () => {
  function run(result, radios) {
    computeModule.setComputeReducer("calc", () => result)
    const controls = [control({ name: "total", value: "100" }), ...radios]
    buildController(makeRoot({ inputs: ["total"], outputs: ["rate"], controls })).recompute()
    return radios
  }
  const group = (checkedValue) => ["10", "20", "30"].map((v) => radio("rate", v, v === checkedValue))

  test("moves the check to the radio carrying the result, values untouched", () => {
    const radios = run({ rate: 30 }, group("10"))
    expect(radios.map((r) => r.checked)).toEqual([false, false, true])
    expect(radios.map((r) => r.value)).toEqual(["10", "20", "30"])
    expect(radios.map((r) => r.events)).toEqual([[], [], ["input"]])
  })

  test("an unchanged selection dispatches nothing", () => {
    const radios = run({ rate: "20" }, group("20"))
    expect(radios.map((r) => r.checked)).toEqual([false, true, false])
    expect(radios.flatMap((r) => r.events)).toEqual([])
  })

  test("a result no radio carries clears the group", () => {
    const radios = run({ rate: "99" }, group("20"))
    expect(radios.map((r) => r.checked)).toEqual([false, false, false])
    expect(radios.map((r) => r.events)).toEqual([[], ["input"], []])
  })

  test("a result no radio carries leaves an already-empty group alone", () => {
    const radios = run({ rate: "99" }, group(null))
    expect(radios.flatMap((r) => r.events)).toEqual([])
  })
})

describe("the identity mirror paints the same text reading", () => {
  test("a declared checkbox input mirrors \"true\"/\"false\" into its reactive_text node", () => {
    const node = textNode("gift")
    const controls = [hidden("gift"), checkbox("gift", { checked: true })]
    buildController(makeRoot({ inputs: { gift: "boolean" }, controls, texts: [node] })).recompute()
    expect(node.textContent).toBe("true")
  })

  test("a declared radio input mirrors the checked radio's value", () => {
    const node = textNode("rate")
    const controls = [radio("rate", "10"), radio("rate", "20", true)]
    buildController(makeRoot({ inputs: { rate: "string" }, controls, texts: [node] })).recompute()
    expect(node.textContent).toBe("20")
  })
})
