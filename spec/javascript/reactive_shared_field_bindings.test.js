// A shared field drives its host's client bindings too (issue #440).
//
// reactive_shared_field (#434) marks a control inside a nested reactive root
// with data-reactive-shared-field, and the host's actions post it. The same
// marker now counts for the host's client BINDINGS: reactive_show (every DNF
// term, after:, clear:), reactive_show(disable: true), reactive_enable,
// reactive_show_targets, reactive_group_targets, checked_* counts and a
// reactive_compute input read the marked control, one level up, client-only
// roots between skipped (the #434 rule). Ops, listnav, busy_on, dirty tracking
// and persist keep strict ownership. Without the marker nothing changes.
//
// happy-dom, so selectors, closest() and bubbling events are real. Stimulus is
// mocked, so nothing routes input->reactive#recompute here: a compute test
// dispatches a real input event and relies on the module's own listener.
//
// Run with: bun test spec/javascript
import { test, expect, mock, beforeAll, beforeEach, afterEach } from "bun:test"
import { Window } from "happy-dom"

const window = new Window()
let ReactiveController
let computeModule
const SAVED = {}

beforeAll(async () => {
  mock.module("@hotwired/stimulus", () => ({ Controller: class {} }))
  ReactiveController = (await import("../../app/javascript/phlex/reactive/reactive_controller.js")).default
  computeModule = await import("../../app/javascript/phlex/reactive/compute.js")
})

beforeEach(() => {
  for (const key of ["document", "window", "Event", "CustomEvent", "MutationObserver", "fetch"]) SAVED[key] = globalThis[key]
  globalThis.document = window.document
  globalThis.window = window
  globalThis.Event = window.Event
  globalThis.CustomEvent = window.CustomEvent
  globalThis.MutationObserver = window.MutationObserver
  window.Turbo = { renderStreamMessage: () => {} }
  globalThis.fetch = () => {
    throw new Error("client bindings must never fetch")
  }
  computeModule.__resetComputeRegistryForTest()
  document.body.innerHTML = ""
})

afterEach(() => {
  for (const root of document.querySelectorAll('[data-controller~="reactive"]')) root.__controller?.disconnect()
  for (const [key, value] of Object.entries(SAVED)) globalThis[key] = value
})

// One controller per awake root, in document order, as Stimulus connects them.
function mount(html) {
  document.body.innerHTML = html
  for (const root of document.querySelectorAll('[data-controller~="reactive"]')) {
    const controller = new ReactiveController()
    controller.element = root
    controller.tokenValue = root.getAttribute("data-reactive-token-value") ?? ""
    root.__controller = controller
    controller.connect()
  }
}

const $ = (id) => document.getElementById(id)

// A user edit: write the value, then the bubbling event the browser fires.
function edit(id, value, type = "change") {
  const el = $(id)
  if (el.type === "checkbox") el.checked = value
  else el.value = value
  el.dispatchEvent(new window.Event(type, { bubbles: true }))
}

const show = (field, equals) => `'{"any":[[{"field":"${field}","equals":"${equals}"}]]}'`
const MARK = "data-reactive-shared-field"

// The host's bindings: a section and a button driven by the picker's value,
// and a cross-root show target outside the host.
const hostBindings = `
  <div id="picked" data-reactive-show=${show("choice", "b")} hidden>b picked</div>
  <button id="save" data-reactive-enable=${show("choice", "b")} disabled>Save</button>`

function hostPage({ marked = true, pickerToken = false, hostToken = true } = {}) {
  return `
    <div id="host" data-controller="reactive" ${hostToken ? 'data-reactive-token-value="host-token"' : ""}
         data-reactive-show-targets='{"choice":{"#outside":[{"field":"choice","equals":"b"}]}}'>
      <div id="picker" data-controller="reactive" ${pickerToken ? 'data-reactive-token-value="picker-token"' : ""}>
        <input id="choice" name="choice" value="" required ${marked ? MARK : ""}>
        <input id="q" name="q" form="none">
      </div>
      ${hostBindings}
    </div>
    <div id="outside" hidden>outside</div>`
}

function expectFollows() {
  expect($("picked").hidden).toBe(true)
  expect($("save").disabled).toBe(true)
  expect($("outside").hidden).toBe(true)

  edit("choice", "b")
  expect($("picked").hidden).toBe(false)
  expect($("save").disabled).toBe(false)
  expect($("outside").hidden).toBe(false)

  edit("choice", "c", "input")
  expect($("picked").hidden).toBe(true)
  expect($("save").disabled).toBe(true)
  expect($("outside").hidden).toBe(true)
}

test("a marked field in a nested client-only root drives the host's show, enable and show target", () => {
  mount(hostPage())
  expectFollows()
})

test("a marked field in a nested token-bearing root drives the host's bindings the same way", () => {
  mount(hostPage({ pickerToken: true }))
  expectFollows()
})

test("a client-only host reads the marked field too", () => {
  mount(hostPage({ hostToken: false }))
  expectFollows()
})

test("without the marker the host's bindings never read the nested root's field", () => {
  mount(hostPage({ marked: false, pickerToken: true }))
  edit("choice", "b")
  expect($("picked").hidden).toBe(true)
  expect($("save").disabled).toBe(true)
  expect($("outside").hidden).toBe(true)
})

test("an unmarked field under a nested client-only root stays invisible to the host's bindings", () => {
  mount(hostPage({ marked: false }))
  edit("choice", "b")
  expect($("picked").hidden).toBe(true)
  expect($("save").disabled).toBe(true)
})

// A group hidden by `mode`, disabling its controls while hidden.
function disableGroupPage({ marked = true, pickerToken = false } = {}) {
  return `
    <div id="host" data-controller="reactive" data-reactive-token-value="host-token">
      <select id="mode" name="mode"><option value="a" selected>a</option><option value="other">other</option></select>
      <input id="title" name="title" value="">
      <div id="group" data-reactive-show=${show("mode", "other")} data-reactive-show-disable="true">
        <input id="note" name="note" value="">
        <div id="picker" data-controller="reactive" ${pickerToken ? 'data-reactive-token-value="picker-token"' : ""}>
          <input id="choice" name="choice" value="" required ${marked ? MARK : ""}>
          <input id="q" name="q" form="none">
        </div>
      </div>
    </div>`
}

test("a disable: true group disables a marked control while hidden and re-enables it when shown", () => {
  mount(disableGroupPage())
  expect($("group").hidden).toBe(true)
  expect($("note").disabled).toBe(true)
  expect($("choice").disabled).toBe(true)
  expect($("q").disabled).toBe(false) // unmarked: the picker's own

  edit("mode", "other")
  expect($("group").hidden).toBe(false)
  expect($("choice").disabled).toBe(false)

  edit("mode", "a")
  expect($("group").hidden).toBe(true)
  expect($("choice").disabled).toBe(true)
  expect($("q").disabled).toBe(false)
})

test("a disable: true group flips a marked control in a nested token-bearing root too", () => {
  mount(disableGroupPage({ pickerToken: true }))
  expect($("choice").disabled).toBe(true)
  expect($("q").disabled).toBe(false)
  edit("mode", "other")
  expect($("choice").disabled).toBe(false)
})

test("without the marker a disable: true group leaves the nested root's controls alone", () => {
  mount(disableGroupPage({ marked: false }))
  expect($("group").hidden).toBe(true)
  expect($("note").disabled).toBe(true)
  expect($("choice").disabled).toBe(false)
})

test("a marked control two server roots down is not read by the grand-host; its direct host reads it", () => {
  mount(`
    <div id="grand" data-controller="reactive" data-reactive-token-value="grand-token">
      <div id="host" data-controller="reactive" data-reactive-token-value="host-token">
        <div id="picker" data-controller="reactive" data-reactive-token-value="picker-token">
          <input id="choice" name="choice" value="" ${MARK}>
        </div>
        <p id="host-picked" data-reactive-show=${show("choice", "b")} hidden>host</p>
      </div>
      <p id="grand-picked" data-reactive-show=${show("choice", "b")} hidden>grand</p>
    </div>`)
  edit("choice", "b")
  expect($("host-picked").hidden).toBe(false)
  expect($("grand-picked").hidden).toBe(true)
})

test("the layered tree control -> client-only root -> token root -> host: the host reads it", () => {
  mount(`
    <div id="host" data-controller="reactive" data-reactive-token-value="host-token">
      <div id="widget" data-controller="reactive" data-reactive-token-value="widget-token">
        <div id="list" data-controller="reactive">
          <input id="choice" name="choice" value="" ${MARK}>
        </div>
      </div>
      <p id="picked" data-reactive-show=${show("choice", "b")} hidden>b</p>
    </div>`)
  edit("choice", "b")
  expect($("picked").hidden).toBe(false)
})

test("a nested root's own bindings are still its own controller's job", () => {
  mount(`
    <div id="host" data-controller="reactive" data-reactive-token-value="host-token">
      <input id="mode" name="mode" value="a">
      <div id="picker" data-controller="reactive">
        <input id="choice" name="choice" value="" ${MARK}>
        <p id="inner" data-reactive-show=${show("mode", "a")} hidden>inner</p>
      </div>
      <p id="picked" data-reactive-show=${show("choice", "b")} hidden>b</p>
    </div>`)
  // The picker has no `mode` field: its binding stays as rendered; the host
  // never evaluates a binding element that lives in the nested root.
  expect($("inner").hidden).toBe(true)
  edit("choice", "b")
  expect($("picked").hidden).toBe(false)
  expect($("inner").hidden).toBe(true)
})

test("after: waits for the marked field's first blur, seen by the host", () => {
  mount(`
    <div id="host" data-controller="reactive" data-reactive-token-value="host-token">
      <div id="picker" data-controller="reactive"><input id="choice" name="choice" value="" ${MARK}></div>
      <p id="picked" data-reactive-show=${show("choice", "b")} data-reactive-show-after="choice" hidden>b</p>
    </div>`)
  edit("choice", "b", "input")
  expect($("picked").hidden).toBe(true)
  $("choice").dispatchEvent(new window.FocusEvent("focusout", { bubbles: true }))
  expect($("picked").hidden).toBe(false)
})

test("clear: on the host's show empties a marked control when its section hides", () => {
  mount(`
    <div id="host" data-controller="reactive" data-reactive-token-value="host-token">
      <select id="mode" name="mode"><option value="a">a</option><option value="other" selected>other</option></select>
      <div id="group" data-reactive-show=${show("mode", "other")} data-reactive-show-clear='["choice","q"]'>
        <div id="picker" data-controller="reactive">
          <input id="choice" name="choice" value="b" ${MARK}>
          <input id="q" name="q" value="typed">
        </div>
      </div>
    </div>`)
  expect($("group").hidden).toBe(false)
  edit("mode", "a")
  expect($("group").hidden).toBe(true)
  expect($("choice").value).toBe("")
  expect($("q").value).toBe("typed") // unmarked: never the host's to clear
})

test("checked_* counts and a group target count include a marked checkbox", () => {
  mount(`
    <div id="host" data-controller="reactive" data-reactive-token-value="host-token"
         data-reactive-group-targets='{"tags[]":{"count":["#outside-count"]}}'>
      <input id="own" type="checkbox" name="tags[]" value="x">
      <div id="picker" data-controller="reactive">
        <input id="shared" type="checkbox" name="tags[]" value="y" ${MARK}>
        <input id="internal" type="checkbox" name="tags[]" value="z">
      </div>
      <span id="count" data-reactive-count="tags[]">0</span>
      <button id="go" data-reactive-enable='{"any":[[{"field":"tags[]","checked_gte":2}]]}' disabled>Go</button>
    </div>
    <span id="outside-count">0</span>`)
  edit("own", true)
  expect($("count").textContent).toBe("1")
  expect($("go").disabled).toBe(true)
  edit("internal", true) // unmarked: the picker's own
  expect($("count").textContent).toBe("1")
  edit("shared", true)
  expect($("count").textContent).toBe("2")
  expect($("outside-count").textContent).toBe("2")
  expect($("go").disabled).toBe(false)
})

test("a host compute input reads a marked field and recomputes on its input event", () => {
  const seen = []
  computeModule.setComputeReducer("label", (values, meta) => {
    seen.push(meta.changed)
    return { label: `picked ${values.choice}` }
  })
  mount(`
    <div id="host" data-controller="reactive" data-reactive-token-value="host-token"
         data-action="input->reactive#recompute"
         data-reactive-compute-reducer-param="label"
         data-reactive-compute-inputs-param='{"choice":"string","title":"string"}'
         data-reactive-compute-outputs-param='["label"]'>
      <input id="title" name="title" value="">
      <div id="picker" data-controller="reactive">
        <input id="choice" name="choice" value="" ${MARK}>
        <input id="q" name="q" value="">
      </div>
      <span id="label" data-reactive-text="label"></span>
    </div>`)
  edit("choice", "b", "input")
  expect($("label").textContent).toBe("picked b")
  expect(seen).toEqual(["choice"])

  // An owned field's edit is Stimulus's to route (input->reactive#recompute):
  // the module's listener leaves it alone, so it never runs twice.
  edit("title", "x", "input")
  // An unmarked field under the nested root is not the host's input.
  edit("q", "typed", "input")
  expect(seen).toEqual(["choice"])
})

test("without the marker a host compute never reads or recomputes for the nested field", () => {
  const seen = []
  computeModule.setComputeReducer("label", (values) => {
    seen.push(values.choice)
    return { label: `picked ${values.choice}` }
  })
  mount(`
    <div id="host" data-controller="reactive" data-reactive-token-value="host-token"
         data-action="input->reactive#recompute"
         data-reactive-compute-reducer-param="label"
         data-reactive-compute-inputs-param='{"choice":"string"}'
         data-reactive-compute-outputs-param='["label"]'>
      <div id="picker" data-controller="reactive"><input id="choice" name="choice" value=""></div>
      <span id="label" data-reactive-text="label"></span>
    </div>`)
  edit("choice", "b", "input")
  expect(seen).toEqual([])
  $("host").__controller.recompute(new window.Event("input"))
  expect(seen).toEqual([""]) // the nested field is not resolved
})

test("a host client op never reaches a marked control: ops keep strict ownership", () => {
  mount(`
    <div id="host" data-controller="reactive" data-reactive-token-value="host-token">
      <input id="title" name="title" value="">
      <div id="picker" data-controller="reactive"><input id="choice" name="choice" value="" ${MARK}></div>
    </div>`)
  const host = $("host")
  const event = new window.Event("click", { bubbles: true, cancelable: true })
  Object.defineProperty(event, "currentTarget", { value: host, configurable: true })
  event.params = { ops: { on: "click", ops: [["set_value", { to: "[name=title], [name=choice]", value: "zzz" }]] } }
  host.__controller.runOps(event)
  expect($("title").value).toBe("zzz")
  expect($("choice").value).toBe("")
})
