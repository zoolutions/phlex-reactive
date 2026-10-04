// Unit tests for the on-demand client inspector (issue #168) — inspect.js.
//
// A STANDALONE module (the confirm.js/compute.js precedent): it does NOT touch
// the hot-path reactive_controller.js and costs nothing until imported. It scans
// the live DOM and maps every reactive root + bound trigger back to the server
// Component#action names, so a developer debugging in the browser console can
// answer "what's on this page and what does it POST?" without reading source.
//
//   import { scan, report } from "phlex/reactive/inspect"
//   scan(document)      // structured inventory (returns data)
//   report(document)    // console.table rendering of scan(document)
//
// It reads the SAME DOM contract the controller writes: roots
// [data-controller~="reactive"] with id + data-reactive-token-value; triggers
// [data-reactive-action-param] scoped to the NEAREST root (nested roots aren't
// double-attributed); the token payload is base64+JSON-decoded (Rails 7.1+ JSON
// serializer) and degrades to { opaque: true } on a Marshal/opaque payload.
//
// Run with: bun test spec/javascript
import { test, expect, beforeAll, beforeEach, describe } from "bun:test"
import { Window } from "happy-dom"

let scan, report, window, document

beforeAll(async () => {
  const mod = await import("../../app/javascript/phlex/reactive/inspect.js")
  scan = mod.scan
  report = mod.report
})

// A fresh happy-dom Window per test. scan/report take a root, so we pass this
// document explicitly — no global pollution, and `btoa` comes from the window.
beforeEach(() => {
  window = new Window()
  document = window.document
  globalThis.btoa = window.btoa.bind(window)
})

// Build a real signed-shaped token: base64(JSON({_rails:{data:{...}}})) + "--sig".
// The scanner unwraps _rails.data to the {c, gid, s, v} payload, exactly the
// MessageVerifier(JSON serializer) wire shape.
function signedToken(data) {
  const wrapped = { _rails: { data, pur: "phlex-reactive/identity" } }
  const b64 = btoa(JSON.stringify(wrapped))
  return `${b64}--deadbeefsignature`
}

describe("scan(document)", () => {
  test("finds a reactive root and decodes its token payload", () => {
    document.body.innerHTML = `
      <div id="counter" data-controller="reactive"
           data-reactive-token-value="${signedToken({ c: "CounterComponent", s: { count: 1 }, v: 1 })}">
        <button data-reactive-action-param="increment"
                data-action="click->reactive#dispatch"
                data-reactive-params-param="{}">+</button>
      </div>`

    const roots = scan(document)
    expect(roots).toHaveLength(1)
    const root = roots[0]
    expect(root.id).toBe("counter")
    expect(root.component).toBe("CounterComponent")
    expect(root.stateKeys).toEqual(["count"])
    expect(root.tokenVersion).toBe(1)
  })

  test("lists a trigger's action, event, and params", () => {
    document.body.innerHTML = `
      <div id="todo_1" data-controller="reactive" data-reactive-token-value="${signedToken({ c: "TodoItemComponent", gid: "gid://dummy/Todo/1", v: 1 })}">
        <button data-reactive-action-param="toggle" data-action="click->reactive#dispatch" data-reactive-params-param="{}">x</button>
        <input data-reactive-action-param="rename" data-action="change->reactive#dispatch"
               data-reactive-params-param="{&quot;title&quot;:&quot;&quot;}" name="title">
      </div>`

    const [root] = scan(document)
    expect(root.gid).toBe("gid://dummy/Todo/1")
    const actions = root.triggers.map((t) => t.action)
    expect(actions).toContain("toggle")
    expect(actions).toContain("rename")
    const toggle = root.triggers.find((t) => t.action === "toggle")
    expect(toggle.event).toBe("click")
    const rename = root.triggers.find((t) => t.action === "rename")
    expect(rename.event).toBe("change")
  })

  test("captures trigger modifiers (debounce, confirm)", () => {
    document.body.innerHTML = `
      <div id="s" data-controller="reactive" data-reactive-token-value="${signedToken({ c: "SearchComponent", v: 1 })}">
        <input data-reactive-action-param="search" data-action="input->reactive#dispatch"
               data-reactive-params-param="{}" data-reactive-debounce-param="300" name="q">
        <button data-reactive-action-param="destroy" data-action="click->reactive#dispatch"
                data-reactive-params-param="{}" data-reactive-confirm-param="Sure?">x</button>
      </div>`

    const [root] = scan(document)
    const search = root.triggers.find((t) => t.action === "search")
    expect(search.debounce).toBe("300")
    const destroy = root.triggers.find((t) => t.action === "destroy")
    expect(destroy.confirm).toBe("Sure?")
  })

  test("collects named fields the dispatch would send", () => {
    document.body.innerHTML = `
      <div id="f" data-controller="reactive" data-reactive-token-value="${signedToken({ c: "FormComponent", v: 1 })}">
        <input name="title" value="hi">
        <select name="kind"><option>a</option></select>
        <textarea name="body"></textarea>
      </div>`

    const [root] = scan(document)
    expect(root.fields.sort()).toEqual(["body", "kind", "title"])
  })

  test("captures client-only ops and compute triggers", () => {
    document.body.innerHTML = `
      <div id="c" data-controller="reactive" data-reactive-token-value="${signedToken({ c: "CalcComponent", v: 1 })}">
        <button data-reactive-ops-param="[{&quot;name&quot;:&quot;toggle&quot;}]" data-action="click->reactive#runOps">menu</button>
        <input data-reactive-compute-reducer-param="split" name="total">
      </div>`

    const [root] = scan(document)
    expect(root.clientOps).toHaveLength(1)
    expect(root.computes).toContain("split")
  })

  test("decodes on_client binding records — one entry per record (issue #271)", () => {
    const records = [
      { on: "click", window: true, outside: true, ops: [["hide", { to: "#menu .item" }]] },
      { on: "keydown.esc", ops: [["hide", { to: "#menu" }]] },
    ]
    const attr = records.map((r) => JSON.stringify(r).replaceAll(" ", "\\u0020")).join(" ").replaceAll('"', "&quot;")
    document.body.innerHTML = `
      <div id="m" data-controller="reactive" data-reactive-token-value="${signedToken({ c: "MenuComponent", v: 1 })}">
        <div data-reactive-ops-param="${attr}" data-action="click@window->reactive#runOps keydown.esc->reactive#runOps"></div>
        <button data-reactive-ops-param="[[&quot;toggle&quot;,{&quot;to&quot;:&quot;#x&quot;}]]" data-action="click->reactive#runOps">legacy</button>
      </div>`

    const [root] = scan(document)
    expect(root.clientOps).toEqual([
      { event: "click@window", ops: [["hide", { to: "#menu .item" }]] },
      { event: "keydown.esc", ops: [["hide", { to: "#menu" }]] },
      { event: "click", ops: [["toggle", { to: "#x" }]] },
    ])
  })

  test("scopes triggers to the NEAREST root (nested roots aren't double-attributed)", () => {
    document.body.innerHTML = `
      <div id="outer" data-controller="reactive" data-reactive-token-value="${signedToken({ c: "OuterComponent", v: 1 })}">
        <button data-reactive-action-param="outer_act" data-action="click->reactive#dispatch" data-reactive-params-param="{}">o</button>
        <div id="inner" data-controller="reactive" data-reactive-token-value="${signedToken({ c: "InnerComponent", v: 1 })}">
          <button data-reactive-action-param="inner_act" data-action="click->reactive#dispatch" data-reactive-params-param="{}">i</button>
        </div>
      </div>`

    const roots = scan(document)
    const outer = roots.find((r) => r.id === "outer")
    const inner = roots.find((r) => r.id === "inner")
    expect(outer.triggers.map((t) => t.action)).toEqual(["outer_act"])
    expect(inner.triggers.map((t) => t.action)).toEqual(["inner_act"])
  })

  test("captures the show/filter/text binding families", () => {
    document.body.innerHTML = `
      <div id="b" data-controller="reactive" data-reactive-token-value="${signedToken({ c: "BindComponent", v: 1 })}"
           data-reactive-filter-input="#q" data-reactive-filter-option=".opt">
        <div data-reactive-show-field="mode" data-reactive-show-equals="on">shown</div>
        <span data-reactive-text="preview"></span>
      </div>`

    const [root] = scan(document)
    expect(root.show).toHaveLength(1)
    expect(root.show[0].field).toBe("mode")
    expect(root.text).toContain("preview")
    expect(root.filter).not.toBeNull()
  })

  describe("token decoding degradation", () => {
    test("degrades to { opaque: true } on a non-JSON (Marshal) payload", () => {
      // A base64 segment that decodes to bytes that aren't JSON.
      const opaque = `${btoa("\x04\bsome-marshal-bytes")}--sig`
      document.body.innerHTML = `<div id="m" data-controller="reactive" data-reactive-token-value="${opaque}"></div>`
      const [root] = scan(document)
      expect(root.opaque).toBe(true)
      expect(root.component).toBeNull()
    })

    test("degrades on a malformed base64 token without throwing", () => {
      document.body.innerHTML = `<div id="x" data-controller="reactive" data-reactive-token-value="!!!not-base64!!!--sig"></div>`
      expect(() => scan(document)).not.toThrow()
      const [root] = scan(document)
      expect(root.opaque).toBe(true)
    })

    test("handles a missing token attribute", () => {
      document.body.innerHTML = `<div id="n" data-controller="reactive"></div>`
      const [root] = scan(document)
      expect(root.opaque).toBe(true)
      expect(root.id).toBe("n")
    })
  })

  test("captures status attributes (error/busy/dirty)", () => {
    document.body.innerHTML = `
      <div id="st" data-controller="reactive" data-reactive-token-value="${signedToken({ c: "X", v: 1 })}"
           data-reactive-error="boom" aria-busy="true"></div>`
    const [root] = scan(document)
    expect(root.status.error).toBe("boom")
    expect(root.status.busy).toBe(true)
  })
})

describe("report(document)", () => {
  test("does not throw on an empty document", () => {
    document.body.innerHTML = ""
    expect(() => report(document)).not.toThrow()
  })

  test("returns the same data scan(document) does", () => {
    document.body.innerHTML = `<div id="r" data-controller="reactive" data-reactive-token-value="${signedToken({ c: "RComponent", v: 1 })}"></div>`
    const returned = report(document)
    expect(returned).toHaveLength(1)
    expect(returned[0].component).toBe("RComponent")
  })
})
