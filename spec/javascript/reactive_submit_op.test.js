// Unit tests for the issue #226 `submit` client op — commit the TARGET'S OWN
// form via requestSubmit(). Layered on the #95 runOps interpreter like
// reactive_run_ops_extended.test.js: fake nodes, no fetch ever, owned scoping.
//
// The op's form resolution, in order:
//   * the target itself when it IS a form (tagName, so fake nodes work),
//   * the target's form owner (input.form — honors a form= attribute),
//   * the nearest ancestor form (closest("form") — may sit OUTSIDE the
//     component root by design: the field's own form is the scope).
// No form anywhere → a silent no-op (never a throw).
//
// requestSubmit (never submit()) so constraint validation runs and a REAL
// cancelable `submit` event fires — an on(:action, event: "submit")
// interception or a native/Turbo form handles it exactly like a user submit.
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

// A form stand-in: requestSubmit records the call count.
function makeForm() {
  return {
    tagName: "FORM",
    submitted: 0,
    requestSubmit() {
      this.submitted += 1
    },
  }
}

function makeRoot() {
  return {
    isConnected: true,
    id: "otp",
    contains: () => true,
    closest: () => null,
    querySelectorAll: () => [],
    getAttribute: () => null,
  }
}

function buildController(root) {
  const controller = new ReactiveController()
  controller.element = root
  globalThis.fetch = () => {
    throw new Error("runOps must NEVER fetch")
  }
  globalThis.document = {
    activeElement: null,
    querySelector: () => null,
    querySelectorAll: () => [],
    dispatchEvent: () => {},
  }
  return controller
}

function fire(controller, ops) {
  const event = {
    params: { ops },
    target: {},
    preventDefault() {},
  }
  controller.runOps(event)
}

function captureWarnings(fn) {
  const warns = []
  const original = console.warn
  console.warn = (...args) => warns.push(args.join(" "))
  try {
    fn()
  } finally {
    console.warn = original
  }
  return warns
}

test("submit on a form-control target requestSubmits its OWN form (el.form)", () => {
  const root = makeRoot()
  const form = makeForm()
  // A control owned by the root whose form owner is `form` (may live outside
  // the root — the field's form is the scope, not the component boundary).
  const control = {
    form,
    closest: (sel) => (sel === "form" ? null : root),
  }
  root.querySelectorAll = (sel) => (sel === "[name=code]" ? [control] : [])
  const controller = buildController(root)

  fire(controller, [["submit", { to: "[name=code]" }]])

  expect(form.submitted).toBe(1)
})

test("submit on a target that IS a form requestSubmits it directly", () => {
  const root = makeRoot()
  const form = makeForm()
  form.closest = () => root // owned by the root
  root.querySelectorAll = (sel) => (sel === "#checkout" ? [form] : [])
  const controller = buildController(root)

  fire(controller, [["submit", { to: "#checkout" }]])

  expect(form.submitted).toBe(1)
})

test("submit on a plain node (the @root default) falls back to closest('form')", () => {
  const root = makeRoot()
  const form = makeForm()
  // The component root is a <div> INSIDE the form — the OTP shape.
  root.closest = (sel) => (sel === "form" ? form : null)
  const controller = buildController(root)

  fire(controller, [["submit", { to: "@root" }]])

  expect(form.submitted).toBe(1)
})

test("submit with no form anywhere is a silent no-op (never a throw)", () => {
  const root = makeRoot() // closest -> null, no form property
  const controller = buildController(root)

  expect(() => fire(controller, [["submit", { to: "@root" }]])).not.toThrow()
})

test("submit is a KNOWN op — it never trips the unknown-op default-deny warn", () => {
  const root = makeRoot()
  const form = makeForm()
  root.closest = (sel) => (sel === "form" ? form : null)
  const controller = buildController(root)

  const warns = captureWarnings(() => fire(controller, [["submit", { to: "@root" }]]))

  expect(warns.filter((w) => w.includes("unknown client op"))).toEqual([])
  expect(form.submitted).toBe(1)
})

test("submit composes in a chain (siblings still apply, in order)", () => {
  const root = makeRoot()
  const form = makeForm()
  root.closest = (sel) => (sel === "form" ? form : null)
  const el = {
    classes: new Set(),
    closest: () => root,
    classList: {
      add(...cs) {
        cs.forEach((c) => el.classes.add(c))
      },
    },
  }
  root.querySelectorAll = (sel) => (sel === ".status" ? [el] : [])
  const controller = buildController(root)

  fire(controller, [
    ["add_class", { to: ".status", classes: ["busy"] }],
    ["submit", { to: "@root" }],
  ])

  expect(el.classes.has("busy")).toBe(true)
  expect(form.submitted).toBe(1)
})

// --- submitter: (issue #319) ---------------------------------------------------
// js.submit(to, submitter: "#sel") resolves the submitter with the op's own
// scoping and calls form.requestSubmit(submitter), so the request carries the
// submitter's name=value. A submitter that is not a submit control of THAT form
// warns and falls back to a plain requestSubmit() (requestSubmit(x) would throw).

function makeSubmitForm() {
  return {
    tagName: "FORM",
    calls: [],
    closest: () => null,
    requestSubmit(...args) {
      this.calls.push(args)
    },
  }
}

function submitterRoot(form, nodes) {
  const root = makeRoot()
  form.closest = () => root
  root.querySelectorAll = (sel) => (sel === "#bulk" ? [form] : (nodes[sel] ?? []))
  return root
}

function submitControl(form, type = "submit", tagName = "BUTTON") {
  return { tagName, type, form, closest: () => null }
}

test("submit with submitter: requestSubmits the form THROUGH that submit control", () => {
  const form = makeSubmitForm()
  const button = submitControl(form)
  const root = submitterRoot(form, { "#delete-submit": [button] })
  button.closest = () => root

  const warns = captureWarnings(() =>
    fire(buildController(root), [["submit", { to: "#bulk", submitter: "#delete-submit" }]]),
  )

  expect(form.calls).toEqual([[button]])
  expect(warns).toEqual([])
})

test("an <input type=submit> submitter is accepted too", () => {
  const form = makeSubmitForm()
  const input = submitControl(form, "submit", "INPUT")
  const root = submitterRoot(form, { "#go": [input] })
  input.closest = () => root

  fire(buildController(root), [["submit", { to: "#bulk", submitter: "#go" }]])

  expect(form.calls).toEqual([[input]])
})

test("a submitter of ANOTHER form warns and falls back to a plain requestSubmit()", () => {
  const form = makeSubmitForm()
  const other = makeSubmitForm()
  const button = submitControl(other)
  const root = submitterRoot(form, { "#elsewhere": [button] })
  button.closest = () => root

  const warns = captureWarnings(() =>
    fire(buildController(root), [["submit", { to: "#bulk", submitter: "#elsewhere" }]]),
  )

  expect(form.calls).toEqual([[]])
  expect(other.calls).toEqual([])
  expect(warns.some((w) => w.includes("submitter"))).toBe(true)
})

test("a submitter that is not a submit control warns and falls back", () => {
  const form = makeSubmitForm()
  const plain = submitControl(form, "button")
  const root = submitterRoot(form, { "#plain": [plain] })
  plain.closest = () => root

  const warns = captureWarnings(() => fire(buildController(root), [["submit", { to: "#bulk", submitter: "#plain" }]]))

  expect(form.calls).toEqual([[]])
  expect(warns.some((w) => w.includes("submitter"))).toBe(true)
})

test("a submitter that resolves to nothing warns and falls back", () => {
  const form = makeSubmitForm()
  const root = submitterRoot(form, {})

  const warns = captureWarnings(() => fire(buildController(root), [["submit", { to: "#bulk", submitter: "#missing" }]]))

  expect(form.calls).toEqual([[]])
  expect(warns.some((w) => w.includes("submitter"))).toBe(true)
})

test("a cancelled confirm: submits nothing; an accepted one submits through the submitter", async () => {
  const confirm = await import("../../app/javascript/phlex/reactive/confirm.js")
  const form = makeSubmitForm()
  const button = submitControl(form)
  const root = submitterRoot(form, { "#delete-submit": [button] })
  button.closest = () => root
  const controller = buildController(root)
  const ops = [["submit", { to: "#bulk", submitter: "#delete-submit" }]]
  const run = () => controller.runOps({ params: { ops, confirm: "Delete?" }, target: {}, preventDefault() {} })
  const settle = () => new Promise((resolve) => setTimeout(resolve, 0))

  const original = confirm.confirmResolver
  try {
    confirm.setConfirmResolver(() => Promise.resolve(false))
    run()
    await settle()
    expect(form.calls).toEqual([])

    confirm.setConfirmResolver(() => Promise.resolve(true))
    run()
    await settle()
    expect(form.calls).toEqual([[button]])
  } finally {
    confirm.setConfirmResolver(original)
  }
})
