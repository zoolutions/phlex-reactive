// Unit tests for the declarative pending-state vocabulary on reactive triggers
// (issue #181 — busy:, unifying the former loading:/disable_with:).
//
// `on(:x, busy: { … })` / `on(:x, busy: "…")` emit data-reactive-busy-param
// (JSON) that Stimulus surfaces as event.params.busy. The controller, when a
// request is ENQUEUED (covering the queue wait, not just the fetch):
//
//   * marks the TRIGGER with data-reactive-busy="<action>" and the root with the
//     SAME action token in a SPACE-SEPARATED set (two queued actions never
//     clobber), plus aria-busy via a PENDING COUNTER (removed only at zero),
//   * applies the busy hint's cosmetic ops (add_class/remove_class/toggle_class/
//     hide/show), disables the trigger, swaps its INNERHTML — but the disable +
//     swap happen at ENQUEUE, never during a debounce quiet period (a debounced
//     input's element must not be disabled mid-typing),
//   * scopes busy_on elements: data-reactive-busy-on="save" gets
//     data-reactive-busy toggled only while `save` is in flight,
//   * on settle (success OR failure) restores the trigger, GUARDED — skipped if
//     the trigger disconnected, and the label is not clobbered if a morph
//     rendered a new server label (innerHTML no longer equals the swapped text).
//
// text swaps INNERHTML, not textContent: a composite trigger (icon + label span)
// must keep its icon through the swap — the child-preservation test proves it.
//
// The trigger is event.currentTarget (a <button><span> click's target is the
// span, which carries no params) — captured in dispatch and threaded through.
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

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

// A fake element with a classList over a Set, a token-store for attributes, a
// `disabled` flag, and `innerHTML`. `isConnected` defaults true. Records
// blur/input listeners so a debounce flush can be driven. innerHTML is a plain
// string here (the controller only reads/writes it as an opaque markup blob), so
// setting it to "Saving…" and back exactly models the DOM's byte round trip —
// including the composite-trigger case where the original holds child markup.
function makeEl({ owner = null, innerHTML = "" } = {}) {
  const listeners = {}
  const attrs = {}
  const el = {
    isConnected: true,
    disabled: false,
    innerHTML,
    classes: new Set(),
    closest: () => owner,
    getAttribute: (n) => (n in attrs ? attrs[n] : null),
    setAttribute: (n, v) => {
      attrs[n] = String(v)
    },
    removeAttribute: (n) => {
      delete attrs[n]
    },
    hasAttribute: (n) => n in attrs,
    addEventListener: (t, fn) => {
      (listeners[t] ||= []).push(fn)
    },
    removeEventListener: (t, fn) => {
      listeners[t] = (listeners[t] || []).filter((f) => f !== fn)
    },
    fire: (t) => (listeners[t] || []).slice().forEach((fn) => fn()),
  }
  el.classList = {
    add: (...cs) => cs.forEach((c) => el.classes.add(c)),
    remove: (...cs) => cs.forEach((c) => el.classes.delete(c)),
    toggle: (c) => (el.classes.has(c) ? el.classes.delete(c) : el.classes.add(c)),
    contains: (c) => el.classes.has(c),
  }
  return el
}

let root

// A reactive root that resolves `to:`/busy_on selectors from a `matches` map,
// tracks its own attributes (aria-busy, data-reactive-busy set), and owns the
// trigger. querySelectorAll returns whatever the map holds for a selector.
function makeRoot(matches = {}) {
  const attrs = {}
  return {
    isConnected: true,
    id: "counter",
    hidden: false,
    getAttribute: (n) => (n in attrs ? attrs[n] : null),
    setAttribute: (n, v) => {
      attrs[n] = String(v)
    },
    removeAttribute: (n) => {
      delete attrs[n]
    },
    hasAttribute: (n) => n in attrs,
    dispatchEvent: () => {},
    contains: () => false,
    querySelectorAll: (sel) => matches[sel] ?? [],
  }
}

// Build a controller with a scripted fetch. `responses` is consumed in order;
// the last repeats. Each is {...response fields} or { reject: Error }. A
// `hold` promise lets a test keep the fetch pending to inspect mid-flight state.
function buildController(responses, { rootMatches = {}, hold = null } = {}) {
  root = makeRoot(rootMatches)
  const controller = new ReactiveController()
  controller.element = root
  controller.tokenValue = "tok"
  let calls = 0
  globalThis.fetch = async () => {
    const script = responses[Math.min(calls, responses.length - 1)]
    calls++
    if (hold) await hold
    if (script.reject) return Promise.reject(script.reject)
    return {
      redirected: script.redirected ?? false,
      ok: script.ok ?? true,
      status: script.status ?? 200,
      headers: { get: () => script.contentType ?? "text/vnd.turbo-stream.html" },
      text: () => Promise.resolve(script.body ?? ""),
    }
  }
  globalThis.document = { querySelector: () => null, dispatchEvent: () => {} }
  globalThis.window = { Turbo: { renderStreamMessage: () => {} } }
  globalThis.queueMicrotask ??= (fn) => Promise.resolve().then(fn)
  return { controller, calls: () => calls }
}

// Fire a dispatch with a busy hint. `trigger` is event.currentTarget.
function fireDispatch(controller, trigger, busy, extra = {}) {
  const event = {
    target: trigger,
    currentTarget: trigger,
    params: { action: "save", params: "{}", busy, ...extra },
    defaultPrevented: false,
    preventDefault() {
      this.defaultPrevented = true
    },
  }
  return { promise: controller.dispatch(event), event }
}

// --- currentTarget capture --------------------------------------------------

test("the trigger is event.currentTarget, not event.target (a nested span click)", async () => {
  const { controller } = buildController([{}])
  const button = makeEl()
  const span = makeEl() // the inner <span> the click actually landed on
  const event = {
    target: span, // the span carries no busy/params
    currentTarget: button, // on() is spread onto the button
    params: { action: "save", params: "{}", busy: { add_class: ["busy"] } },
    defaultPrevented: false,
    preventDefault() {
      this.defaultPrevented = true
    },
  }
  controller.dispatch(event)
  // The class must land on the BUTTON (currentTarget), never the span.
  expect(button.classes.has("busy")).toBe(true)
  expect(span.classes.has("busy")).toBe(false)
  await controller.queue
})

// --- busy vocabulary at enqueue ---------------------------------------------

test("marks the trigger with data-reactive-busy=<action> on enqueue", async () => {
  const { controller } = buildController([{}])
  const trigger = makeEl()

  const { promise } = fireDispatch(controller, trigger, { disable: true })
  expect(trigger.getAttribute("data-reactive-busy")).toBe("save")
  await promise
})

test("adds the action token to the root's SPACE-SEPARATED busy set", async () => {
  const { controller } = buildController([{}])
  const trigger = makeEl()

  const { promise } = fireDispatch(controller, trigger, { disable: true })
  expect(root.getAttribute("data-reactive-busy")).toBe("save")
  await promise
})

test("sets aria-busy on the root during the pending window", async () => {
  let release
  const hold = new Promise((r) => (release = r))
  const { controller } = buildController([{}], { hold })
  const trigger = makeEl()

  const { promise } = fireDispatch(controller, trigger, { disable: true })
  expect(root.getAttribute("aria-busy")).toBe("true")
  release()
  await promise
  expect(root.hasAttribute("aria-busy")).toBe(false)
})

test("applies add_class + disable + text swap on enqueue", async () => {
  let release
  const hold = new Promise((r) => (release = r))
  const { controller } = buildController([{}], { hold })
  const trigger = makeEl({ innerHTML: "Save" })

  const { promise } = fireDispatch(controller, trigger, { disable: true, add_class: ["opacity-50"], text: "Saving…" })
  expect(trigger.disabled).toBe(true)
  expect(trigger.classes.has("opacity-50")).toBe(true)
  expect(trigger.innerHTML).toBe("Saving…")
  release()
  await promise
})

test("the String shorthand disables + swaps the label (busy: 'Saving…')", async () => {
  // The Ruby side expands "Saving…" to { disable: true, text: … }; the client
  // receives the expanded hash. This mirrors that wire form.
  let release
  const hold = new Promise((r) => (release = r))
  const { controller } = buildController([{}], { hold })
  const trigger = makeEl({ innerHTML: "Save" })

  const { promise } = fireDispatch(controller, trigger, { disable: true, text: "Saving…" })
  expect(trigger.disabled).toBe(true)
  expect(trigger.innerHTML).toBe("Saving…")
  release()
  await promise
})

test("supports remove_class, toggle_class, hide and show", async () => {
  const { controller } = buildController([{}])
  const trigger = makeEl()
  trigger.classes.add("idle")

  const { promise } = fireDispatch(controller, trigger, {
    remove_class: ["idle"],
    toggle_class: ["spin"],
    hide: true,
  })
  expect(trigger.classes.has("idle")).toBe(false)
  expect(trigger.classes.has("spin")).toBe(true)
  expect(trigger.hidden).toBe(true)
  await promise
  // All revert on settle.
  expect(trigger.classes.has("idle")).toBe(true)
  expect(trigger.classes.has("spin")).toBe(false)
  expect(trigger.hidden).toBe(false)
})

// Issue #300: hide/show undo only what THIS hint changed — a target that was
// already in the hinted state keeps it on settle.
test("hide: on an already-hidden to: target leaves it hidden on settle", async () => {
  const panel = makeEl()
  panel.closest = () => root
  panel.hidden = true
  const { controller } = buildController([{}], { rootMatches: { "#already-hidden": [panel] } })

  const { promise } = fireDispatch(controller, makeEl(), { hide: true, to: "#already-hidden" })
  expect(panel.hidden).toBe(true)
  await promise
  expect(panel.hidden).toBe(true)
})

test("show: on an already-visible to: target leaves it visible on settle", async () => {
  const panel = makeEl()
  panel.closest = () => root
  panel.hidden = false
  const { controller } = buildController([{}], { rootMatches: { "#already-shown": [panel] } })

  const { promise } = fireDispatch(controller, makeEl(), { show: true, to: "#already-shown" })
  expect(panel.hidden).toBe(false)
  await promise
  expect(panel.hidden).toBe(false)
})

test("show: on a hidden target re-hides it on settle", async () => {
  const panel = makeEl()
  panel.closest = () => root
  panel.hidden = true
  const { controller } = buildController([{}], { rootMatches: { ".spinner": [panel] } })

  const { promise } = fireDispatch(controller, makeEl(), { show: true, to: ".spinner" })
  expect(panel.hidden).toBe(false)
  await promise
  expect(panel.hidden).toBe(true)
})

test("a to: selector applies the class ops to owned matches, not the trigger", async () => {
  const spinner = makeEl()
  spinner.closest = () => root
  const { controller } = buildController([{}], { rootMatches: { ".spinner": [spinner] } })
  const trigger = makeEl()

  const { promise } = fireDispatch(controller, trigger, { add_class: ["on"], to: ".spinner" })
  expect(spinner.classes.has("on")).toBe(true)
  expect(trigger.classes.has("on")).toBe(false)
  await promise
})

// --- composite trigger (innerHTML preserves child markup) -------------------

test("text swap preserves a composite trigger's markup (icon + label round-trip)", async () => {
  const { controller } = buildController([{}])
  // A button with an icon AND a label — the exact case textContent would flatten.
  const trigger = makeEl({ innerHTML: '<svg class="icon"></svg> Save' })

  const { promise } = fireDispatch(controller, trigger, { disable: true, text: "Saving…" })
  // During flight the label is swapped wholesale (the hint replaces the content).
  expect(trigger.innerHTML).toBe("Saving…")
  await promise
  // On settle the ORIGINAL markup — icon included — is restored byte-for-byte.
  expect(trigger.innerHTML).toBe('<svg class="icon"></svg> Save')
})

// --- busy_on scoping --------------------------------------------------------

test("busy_on element gets data-reactive-busy while its action is in flight, cleared after", async () => {
  let release
  const hold = new Promise((r) => (release = r))
  const spinner = makeEl()
  spinner.closest = () => root
  spinner.setAttribute("data-reactive-busy-on", "save")
  const { controller } = buildController([{}], {
    hold,
    rootMatches: { "[data-reactive-busy-on]": [spinner] },
  })
  const trigger = makeEl()

  const { promise } = fireDispatch(controller, trigger, { disable: true })
  expect(spinner.getAttribute("data-reactive-busy")).toBe("save")
  release()
  await promise
  expect(spinner.hasAttribute("data-reactive-busy")).toBe(false)
})

test("busy_on element for a DIFFERENT action is not marked", async () => {
  const spinner = makeEl()
  spinner.closest = () => root
  spinner.setAttribute("data-reactive-busy-on", "destroy") // different action
  const { controller } = buildController([{}], {
    rootMatches: { "[data-reactive-busy-on]": [spinner] },
  })
  const trigger = makeEl()

  const { promise } = fireDispatch(controller, trigger, { disable: true })
  expect(spinner.hasAttribute("data-reactive-busy")).toBe(false)
  await promise
})

// --- restore on settle (success) --------------------------------------------

test("restores disabled + label on success settle", async () => {
  const { controller } = buildController([{}])
  const trigger = makeEl({ innerHTML: "Save" })

  const { promise } = fireDispatch(controller, trigger, { disable: true, text: "Saving…" })
  await promise
  expect(trigger.disabled).toBe(false)
  expect(trigger.innerHTML).toBe("Save")
  expect(trigger.hasAttribute("data-reactive-busy")).toBe(false)
})

test("restores disabled + label on failure settle", async () => {
  const { controller } = buildController([{ ok: false, status: 500 }])
  const trigger = makeEl({ innerHTML: "Save" })
  const originalError = console.error
  console.error = () => {}
  try {
    const { promise } = fireDispatch(controller, trigger, { disable: true, text: "Saving…" })
    await promise
  } finally {
    console.error = originalError
  }
  expect(trigger.disabled).toBe(false)
  expect(trigger.innerHTML).toBe("Save")
})

test("removes an add_class op on settle", async () => {
  const { controller } = buildController([{}])
  const trigger = makeEl()

  const { promise } = fireDispatch(controller, trigger, { add_class: ["opacity-50"] })
  await promise
  expect(trigger.classes.has("opacity-50")).toBe(false)
})

// --- guarded restore --------------------------------------------------------

test("restore is SKIPPED when the trigger left the DOM (guarded by isConnected)", async () => {
  const { controller } = buildController([{}])
  const trigger = makeEl({ innerHTML: "Save" })

  const { promise } = fireDispatch(controller, trigger, { disable: true, text: "Saving…" })
  trigger.isConnected = false // a plain replace detached the trigger
  await promise
  // No restore against a detached node — label stays as swapped (the node is gone).
  expect(trigger.innerHTML).toBe("Saving…")
})

test("does NOT clobber a server-rendered new label (innerHTML changed by the morph)", async () => {
  const { controller } = buildController([{}])
  const trigger = makeEl({ innerHTML: "Save" })

  const { promise } = fireDispatch(controller, trigger, { disable: true, text: "Saving…" })
  // A morph re-rendered the trigger with a fresh label before the settle lands.
  trigger.innerHTML = "Saved ✓"
  await promise
  // The restore must NOT overwrite the server's new label with the old "Save".
  expect(trigger.innerHTML).toBe("Saved ✓")
  // The disabled flag is still restored (it's the client's, not the server's).
  expect(trigger.disabled).toBe(false)
})

// --- pending counter across overlapping enqueues ----------------------------

test("aria-busy survives A's settle while B is still queued (pending counter)", async () => {
  // A per-call gate so we can release A's fetch while B's stays pending. The
  // queue serializes #perform, so only A is in flight when we release its gate;
  // B's #perform then starts and blocks on gate #2.
  const gates = []
  const nextGate = () => {
    let release
    const p = new Promise((r) => (release = r))
    gates.push(release)
    return p
  }
  root = makeRoot()
  const controller = new ReactiveController()
  controller.element = root
  controller.tokenValue = "tok"
  globalThis.fetch = async () => {
    await nextGate()
    return {
      redirected: false,
      ok: true,
      status: 200,
      headers: { get: () => "text/vnd.turbo-stream.html" },
      text: () => Promise.resolve(""),
    }
  }
  globalThis.document = { querySelector: () => null, dispatchEvent: () => {} }
  globalThis.window = { Turbo: { renderStreamMessage: () => {} } }
  globalThis.queueMicrotask ??= (fn) => Promise.resolve().then(fn)

  const triggerA = makeEl()
  const triggerB = makeEl()

  // Enqueue A then B — both pending; counter = 2.
  fireDispatch(controller, triggerA, { disable: true }, { action: "a" })
  fireDispatch(controller, triggerB, { disable: true }, { action: "b" })
  await wait(5) // let A's #perform reach its fetch/gate
  expect(root.getAttribute("aria-busy")).toBe("true")

  // Release A's gate: A settles, but B is next in the serialized queue.
  gates[0]()
  await wait(5)
  // With A settled and B still in flight (or newly started), aria-busy must NOT
  // have been cleared — the pending counter is still > 0.
  expect(root.getAttribute("aria-busy")).toBe("true")

  await wait(5)
  gates[1]?.() // release B
  await controller.queue
  // Both settled → counter 0 → attribute removed.
  expect(root.hasAttribute("aria-busy")).toBe(false)
})

test("the root busy set keeps a token until ALL its requests settle (per-action refcount)", async () => {
  let release
  const hold = new Promise((r) => (release = r))
  const { controller } = buildController([{}, {}], { hold })
  const t1 = makeEl()
  const t2 = makeEl()

  // Two "save" requests overlapping.
  fireDispatch(controller, t1, { disable: true })
  fireDispatch(controller, t2, { disable: true })
  expect(root.getAttribute("data-reactive-busy")).toBe("save")

  release()
  await controller.queue
  // Both settled → the token is gone.
  expect(root.hasAttribute("data-reactive-busy")).toBe(false)
})

test("two different queued actions keep both tokens in the space-separated set", async () => {
  let release
  const hold = new Promise((r) => (release = r))
  const { controller } = buildController([{}, {}], { hold })
  const t1 = makeEl()
  const t2 = makeEl()

  fireDispatch(controller, t1, { disable: true }, { action: "save" })
  fireDispatch(controller, t2, { disable: true }, { action: "publish" })

  const set = root.getAttribute("data-reactive-busy").split(" ").sort()
  expect(set).toEqual(["publish", "save"])
  release()
  await controller.queue
})

// --- overlapping text swaps restore the TRUE original (refcounted snapshot) --

test("an overlapping text swap restores the true pre-busy label, not the swapped one", async () => {
  let release
  const hold = new Promise((r) => (release = r))
  const { controller } = buildController([{}, {}], { hold })
  const trigger = makeEl({ innerHTML: "Save" })

  // Two overlapping enqueues on the SAME trigger. The second must NOT snapshot
  // the already-swapped "Saving…" as the original.
  fireDispatch(controller, trigger, { disable: true, text: "Saving…" })
  fireDispatch(controller, trigger, { disable: true, text: "Saving…" })
  expect(trigger.innerHTML).toBe("Saving…")

  release()
  await controller.queue
  // Both settled → the TRUE original label is restored.
  expect(trigger.innerHTML).toBe("Save")
})

// --- debounce: disable only at flush, not during the quiet period -----------

test("a debounced trigger is NOT disabled during the quiet period, only at flush", async () => {
  // Hold the fetch so the request stays pending after the flush — otherwise the
  // whole round trip completes within the wait and the busy state settles before
  // we can observe it.
  let release
  const hold = new Promise((r) => (release = r))
  const { controller } = buildController([{}], { hold })
  const input = makeEl()

  // Fire a debounced dispatch; the disable must NOT apply yet (still typing) —
  // the debounced input's element must not be disabled during the quiet period.
  fireDispatch(controller, input, { disable: true }, { debounce: 50 })
  expect(input.disabled).toBe(false)
  expect(input.hasAttribute("data-reactive-busy")).toBe(false)

  // Cross the quiet period → flush → enqueue → NOW the busy state applies.
  await wait(80)
  expect(input.disabled).toBe(true)
  expect(input.getAttribute("data-reactive-busy")).toBe("save")
  release()
  await controller.queue
})

// --- deploy-overlap read shim (legacy data-reactive-loading-param) ----------

test("reads a legacy loading param (deploy overlap) and remaps class: to add_class:", async () => {
  const { controller } = buildController([{}])
  const trigger = makeEl()
  // A page rendered by the PREVIOUS gem emits `loading`, not `busy`, and its
  // class-op key is `class:` — the shim remaps it to add_class:.
  const event = {
    target: trigger,
    currentTarget: trigger,
    params: { action: "save", params: "{}", loading: { class: ["busy"], disable: true } },
    defaultPrevented: false,
    preventDefault() {
      this.defaultPrevented = true
    },
  }
  controller.dispatch(event)
  expect(trigger.classes.has("busy")).toBe(true)
  expect(trigger.disabled).toBe(true)
  await controller.queue
})

// --- always-on busy vocabulary (no busy hint needed) ------------------------

test("the busy vocabulary is ALWAYS-ON — a bare on() (no busy hint) still marks busy", async () => {
  let release
  const hold = new Promise((r) => (release = r))
  const { controller } = buildController([{}], { hold })
  const trigger = makeEl()

  // No busy hint at all — the always-on data-reactive-busy/aria-busy vocab still
  // fires so an app styles a spinner with pure CSS and zero Ruby.
  const { promise } = fireDispatch(controller, trigger, undefined)
  expect(trigger.getAttribute("data-reactive-busy")).toBe("save")
  expect(root.getAttribute("data-reactive-busy")).toBe("save")
  expect(root.getAttribute("aria-busy")).toBe("true")
  // …but with no hint there is NO disable, NO class, NO text swap.
  expect(trigger.disabled).toBe(false)
  expect(trigger.classes.size).toBe(0)
  release()
  await promise
  // All busy markers clear on settle.
  expect(trigger.hasAttribute("data-reactive-busy")).toBe(false)
  expect(root.hasAttribute("data-reactive-busy")).toBe(false)
  expect(root.hasAttribute("aria-busy")).toBe(false)
})
