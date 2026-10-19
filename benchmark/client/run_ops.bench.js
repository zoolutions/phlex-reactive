// Micro-bench: runOps — the on_client entry point (issue #95), reworked in
// #271 to parse binding records and pick the one whose descriptor fired. Two
// shapes on a happy-dom root holding a menu + a trigger:
//
//   * legacy  — the bare [[op, args]] list (pre-#271 wire, still accepted)
//   * record  — the #271 binding record, as Stimulus typecasts it (an object)
//   * two records — a mix-ed pair as a space-joined string (split + parse)
//   * delegated — issue #442: a list's within: record picking a row, its value
//     read off the row (@trigger) onto another element, the row marked selected
//
// Each event is a fresh object (the run-once guard keys on the event).
// happy-dom numbers are ENGINE-RELATIVE: a same-machine before/after delta, not
// an absolute browser cost.

import { bench, group } from "mitata"
import { makeDom, buildController } from "./support/harness.js"

// makeDom() installs THIS window's Event/CustomEvent on globalThis, and the
// fixture below needs this document. Restore the previous DOM globals after
// building it, so the benches that registered earlier (recompute dispatches
// events at run time) keep their own window's constructors.
const previousGlobals = {
  document: globalThis.document,
  window: globalThis.window,
  Event: globalThis.Event,
  CustomEvent: globalThis.CustomEvent,
}
const { document } = await makeDom()

const root = document.createElement("div")
root.id = "menu-root"
root.setAttribute("data-controller", "reactive")
root.innerHTML = '<button id="trigger"></button><ul id="menu" hidden><li>a</li></ul>'
document.body.appendChild(root)
const trigger = root.querySelector("#trigger")
const controller = buildController(root)

// Issue #442: a second root holding a 50-row list bound once (its own
// fixture, so the lines above keep theirs).
const listRoot = document.createElement("div")
listRoot.id = "list-root"
listRoot.setAttribute("data-controller", "reactive")
listRoot.innerHTML = `<input id="item-value" type="hidden"><ul id="list">${Array.from(
  { length: 50 },
  (_, i) => `<li><button role="option" data-value="v${i}"><span>Item ${i}</span></button></li>`,
).join("")}</ul>`
document.body.appendChild(listRoot)
const list = listRoot.querySelector("#list")
const rowText = list.querySelectorAll("span")[25]
const listController = buildController(listRoot)
Object.assign(globalThis, previousGlobals)

const ops = [["toggle", { to: "#menu" }]]
const record = { on: "click", ops }
const pair = `${JSON.stringify(record)} ${JSON.stringify({ on: "keydown.esc", ops: [["hide", { to: "#menu" }]] })}`

const delegated = {
  on: "click",
  within: "[role=option]",
  ops: [
    // set_attr, not set_value: its `input` would need this window's Event,
    // and the globals are restored above.
    ["set_attr", { to: "#item-value", name: "data-picked", from: "@trigger", attr: "data-value" }],
    ["set_attr", { to: "@trigger", name: "aria-selected", value: "true" }],
  ],
}

const fire = (param) =>
  controller.runOps({ type: "click", params: { ops: param }, currentTarget: trigger, target: trigger, preventDefault() {} })
const pick = () =>
  listController.runOps({ type: "click", params: { ops: delegated }, currentTarget: list, target: rowText, preventDefault() {} })

group("runOps (one toggle op)", () => {
  bench("legacy [[op, args]] list", () => fire(ops))
  bench("binding record (object)", () => fire(record))
  bench("two records (space-joined string)", () => fire(pair))
})

group("runOps (issue #442: a list bound once)", () => {
  bench("delegated record (within:, a read off @trigger)", pick)
})
