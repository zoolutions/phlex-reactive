// Unit test for #collectFields() and CHECKBOX GROUPS (issue #258).
//
// Before the fix every checkbox was collected as `fields[name] = field.checked`,
// a boolean under its own name. Three boxes named `features[]` with two ticked
// therefore left the browser as a single `false` — the last box's checked state,
// the chosen values gone before any schema could see them. A native submission
// of the same three boxes sends `features[]=news&features[]=events`.
//
// The fix collects an array whenever the name carries the `[]` suffix. That
// suffix is the only trigger: a group says so rather than being inferred from
// two controls sharing a name. A radio group keeps posting its single checked
// value with or without the suffix, and a lone checkbox without `[]` keeps its
// documented yes/no boolean. Both are covered here as regression guards — they
// pass before and after the fix, which is the point.
//
// #collectFields() is private, so we observe it through the POST body, the same
// way reactive_collect_fields.test.js does.
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

// Same minimal node as the sibling test, plus `options`/`multiple` so a
// <select multiple> can be expressed.
class FakeNode {
  constructor({
    tag = "div",
    name = null,
    type = null,
    value = "",
    checked = false,
    controller = null,
    multiple = false,
    options = null,
    files = null,
    // A bare [contenteditable] / rich editor, which #collectFields reads in a
    // SECOND pass. The fixture needs it to cover a `[]`-named editor; pass
    // `value: null` so the read falls through to textContent, as it does for a
    // real contenteditable.
    editor = false,
    textContent = null,
  } = {}) {
    this.tag = tag.toLowerCase()
    this.name = name
    this.type = type
    this.value = value
    this.checked = checked
    this.multiple = multiple
    this.options = options
    this.files = files // array of File for a file input
    this.editor = editor
    this.textContent = textContent
    // Mirrors the DOM property the controller reads to tell a RICH editor
    // (lexxy/trix, which upgrade asynchronously) from a bare contenteditable.
    this.localName = this.tag
    this.parentNode = null
    this.children = []
    this.dataset = {}
    if (controller) this.dataset.controller = controller
  }

  append(...nodes) {
    for (const n of nodes) {
      n.parentNode = this
      this.children.push(n)
    }
    return this
  }

  #descendants() {
    const out = []
    for (const child of this.children) {
      out.push(child, ...child.#descendants())
    }
    return out
  }

  getAttribute(attr) {
    if (attr === "name") return this.name
    return null
  }

  setAttribute() {}
  removeAttribute() {}

  matches(selector) {
    if (selector === '[data-controller~="reactive"]') {
      const c = this.dataset.controller
      return !!c && c.split(/\s+/).includes("reactive")
    }
    if (selector.includes("input[name]")) {
      return ["input", "select", "textarea"].includes(this.tag) && this.name != null
    }
    if (selector.includes("lexxy-editor")) {
      return this.editor && this.name != null
    }
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
}

function checkbox(name, value, checked) {
  return new FakeNode({ tag: "input", type: "checkbox", name, value, checked })
}

// Dispatches `save` on the root and returns the params as they go over the wire.
async function collect(root) {
  let captured = null
  globalThis.fetch = (path, opts) => {
    captured = JSON.parse(opts.body)
    return Promise.resolve({
      redirected: false,
      ok: true,
      headers: { get: () => "text/vnd.turbo-stream.html" },
      text: () => Promise.resolve(""),
    })
  }
  globalThis.document = { querySelector: () => null, dispatchEvent: () => {} }
  globalThis.window = { Turbo: { renderStreamMessage: () => {} } }

  const controller = new ReactiveController()
  controller.element = root
  controller.tokenValue = "tok"
  await controller.dispatch({
    params: { action: "save", params: "{}" },
    preventDefault: () => {},
  })
  return captured.params
}

test("a checkbox group posts the CHECKED VALUES, not one box's checked state (issue #258)", async () => {
  const root = new FakeNode({ tag: "div", controller: "reactive" })
  root.append(
    checkbox("features[]", "news", true),
    checkbox("features[]", "events", true),
    checkbox("features[]", "maps", false),
  )

  expect(await collect(root)).toEqual({ "features[]": ["news", "events"] })
})

test("a group with nothing checked posts an EMPTY ARRAY, not a missing key", async () => {
  const root = new FakeNode({ tag: "div", controller: "reactive" })
  root.append(
    checkbox("features[]", "news", false),
    checkbox("features[]", "events", false),
  )

  // An empty array is what lets an action tell "the operator cleared the group"
  // from "the group never rendered". It survives the server side intact: the
  // key expands to `features` (ParamSchema#bracket_path drops the empty trailing
  // segment) and ParamSchema#array_values passes a real array straight through,
  // so an [:string] schema hands the action []. A missing key would arrive as
  // nil and be indistinguishable from a field the form does not have.
  expect(await collect(root)).toEqual({ "features[]": [] })
})

test("a lone checkbox without [] keeps its documented yes/no boolean", async () => {
  const root = new FakeNode({ tag: "div", controller: "reactive" })
  root.append(checkbox("subscribe", "on-value", true))

  expect(await collect(root)).toEqual({ subscribe: true })
})

test("a <select multiple> under a [] name posts every selected option", async () => {
  const root = new FakeNode({ tag: "div", controller: "reactive" })
  root.append(
    new FakeNode({
      tag: "select",
      name: "features[]",
      multiple: true,
      options: [
        { value: "news", selected: true },
        { value: "events", selected: false },
        { value: "maps", selected: true },
      ],
    }),
  )

  expect(await collect(root)).toEqual({ "features[]": ["news", "maps"] })
})

test("two controls sharing a name WITHOUT [] keep resolving last-wins", async () => {
  // The `[]` suffix is the only trigger. An implicit "two controls share a
  // name" rule would also catch Rails' hidden companions and radio groups, and
  // every neighbouring path that reads the same DOM (persist, the conditional
  // confirm, the nested rows) would have to reproduce the same guesswork. A
  // group says so with the suffix HTML already has for it.
  const root = new FakeNode({ tag: "div", controller: "reactive" })
  root.append(checkbox("feature", "news", true), checkbox("feature", "events", true))

  expect(await collect(root)).toEqual({ feature: true })
})

test("a radio group still posts the single checked value", async () => {
  // Radios share a name to mean "pick one" and stay scalar. Without a `[]`
  // suffix nothing would make them an array anyway; the case worth pinning is
  // the suffixed one, covered below — `#arrayFieldNames` skips radios outright,
  // so `plan[]` posts the checked value, not `["pro"]`.
  const root = new FakeNode({ tag: "div", controller: "reactive" })
  root.append(
    new FakeNode({ tag: "input", type: "radio", name: "plan", value: "free", checked: false }),
    new FakeNode({ tag: "input", type: "radio", name: "plan", value: "pro", checked: true }),
  )

  expect(await collect(root)).toEqual({ plan: "pro" })
})

test("the multipart path writes a group as params[name][] entries, not indexed keys", async () => {
  // With a populated file input the body becomes FormData. Rack reads repeated
  // params[features][] entries as an array; the indexed keys the generic
  // appender writes (params[features][0]) would arrive as a hash instead.
  const root = new FakeNode({ tag: "div", controller: "reactive" })
  root.append(
    checkbox("features[]", "news", true),
    checkbox("features[]", "events", true),
    checkbox("features[]", "maps", false),
    new FakeNode({
      tag: "input",
      type: "file",
      name: "attachment",
      files: [new File(["x"], "receipt.txt", { type: "text/plain" })],
    }),
  )

  let captured = null
  globalThis.fetch = (path, opts) => {
    captured = opts
    return Promise.resolve({
      redirected: false,
      ok: true,
      headers: { get: () => "text/vnd.turbo-stream.html" },
      text: () => Promise.resolve(""),
    })
  }
  globalThis.document = { querySelector: () => null, dispatchEvent: () => {} }
  globalThis.window = { Turbo: { renderStreamMessage: () => {} } }

  const controller = new ReactiveController()
  controller.element = root
  controller.tokenValue = "tok"
  await controller.dispatch({ params: { action: "save", params: "{}" }, preventDefault: () => {} })

  expect(captured.body instanceof FormData).toBe(true)
  expect(captured.body.getAll("params[features][]")).toEqual(["news", "events"])
  expect(captured.body.getAll("empty_groups[]")).toEqual([])
  expect(captured.body.get("params[features][0]")).toBeNull()
})

// --- hidden companions and markers (issue #258) -----------------------------
//
// Rails' `check_box` helper emits a hidden default BEFORE the box, under the
// same name: `<input name="subscribe" type="hidden" value="0">` then
// `<input type="checkbox" value="1" name="subscribe">`. That pair has always
// resolved last-wins to the box's own value, and it must keep doing so.
//
// A hidden input is identified as a COMPANION by a checkbox sharing its name,
// whatever its value — Rails renders three: `value="0"` from `check_box`, the
// same under a `[]` name from `check_box(..., multiple: true)`, and a blank one
// from `collection_check_boxes`. A hidden input WITHOUT a same-named checkbox
// is an ordinary value, the usual shape for a list JS maintains. A cleared
// group is expressed by none of them, and a form body cannot carry it at all.

function hidden(name, value) {
  return new FakeNode({ tag: "input", type: "hidden", name, value })
}

test("a Rails check_box pair stays a boolean when checked, not ['0','1']", async () => {
  const root = new FakeNode({ tag: "div", controller: "reactive" })
  root.append(hidden("subscribe", "0"), checkbox("subscribe", "1", true))

  expect(await collect(root)).toEqual({ subscribe: true })
})

test("a Rails check_box pair stays a boolean when unchecked", async () => {
  const root = new FakeNode({ tag: "div", controller: "reactive" })
  root.append(hidden("subscribe", "0"), checkbox("subscribe", "1", false))

  expect(await collect(root)).toEqual({ subscribe: false })
})

test("a hidden input paired with a same-named text field still resolves last-wins", async () => {
  const root = new FakeNode({ tag: "div", controller: "reactive" })
  root.append(hidden("title", "fallback"), new FakeNode({ tag: "input", name: "title", value: "typed" }))

  expect(await collect(root)).toEqual({ title: "typed" })
})

test("the empty-group marker contributes nothing beside real values", async () => {
  // collection_check_boxes ships `hidden name="features[]" value=""` in front
  // of the boxes. It says "the group is here", not "an empty string was chosen".
  const root = new FakeNode({ tag: "div", controller: "reactive" })
  root.append(
    hidden("features[]", ""),
    checkbox("features[]", "news", true),
    checkbox("features[]", "maps", false),
  )

  expect(await collect(root)).toEqual({ "features[]": ["news"] })
})

test("a hidden input CARRYING a value under a [] name contributes it", async () => {
  // A list JS maintains as hidden inputs is a normal shape; those values are
  // chosen values and must survive.
  const root = new FakeNode({ tag: "div", controller: "reactive" })
  root.append(hidden("tag_ids[]", "7"), hidden("tag_ids[]", "9"))

  expect(await collect(root)).toEqual({ "tag_ids[]": ["7", "9"] })
})

test("check_box(multiple: true) posts only the ticked values, not its companions", async () => {
  // <input name="tag_ids[]" type="hidden" value="0"><input type="checkbox" value="N" name="tag_ids[]">
  // per box, measured from the helper. The companions carry the unchecked_value
  // ("0" by default), so a value test would let them through: three boxes with
  // the third ticked would post ["0","0","0","3"], and against [:integer] the
  // action would write tag id 0.
  const root = new FakeNode({ tag: "div", controller: "reactive" })
  for (const [value, checked] of [["1", false], ["2", false], ["3", true]]) {
    root.append(hidden("tag_ids[]", "0"), checkbox("tag_ids[]", value, checked))
  }

  expect(await collect(root)).toEqual({ "tag_ids[]": ["3"] })
})

test("check_box(multiple: true) with none ticked posts an empty group", async () => {
  const root = new FakeNode({ tag: "div", controller: "reactive" })
  for (const value of ["1", "2"]) {
    root.append(hidden("tag_ids[]", "0"), checkbox("tag_ids[]", value, false))
  }

  expect(await collect(root)).toEqual({ "tag_ids[]": [] })
})

test("a box rendered with unchecked_value nil has no companion and still works", async () => {
  // With `unchecked_value: nil` Rails emits no hidden at all — the third shape.
  const root = new FakeNode({ tag: "div", controller: "reactive" })
  root.append(checkbox("tag_ids[]", "7", true), checkbox("tag_ids[]", "8", false))

  expect(await collect(root)).toEqual({ "tag_ids[]": ["7"] })
})

test("a radio group keeps its single value even under a [] name", async () => {
  const root = new FakeNode({ tag: "div", controller: "reactive" })
  root.append(
    new FakeNode({ tag: "input", type: "radio", name: "plan[]", value: "free", checked: false }),
    new FakeNode({ tag: "input", type: "radio", name: "plan[]", value: "pro", checked: true }),
  )

  expect(await collect(root)).toEqual({ "plan[]": "pro" })
})

test("an editor CONTRIBUTES to a group instead of standing down behind it", async () => {
  // With a filled group already in the slot the old pass stood down entirely —
  // `existing` was neither null nor "" — so the editor's value never reached
  // the wire at all, while the draft snapshot pushed the same control into an
  // array — the wire and the
  // draft disagreeing about one field, and a declared array type seeing a
  // string. It appends to the group slot now, exactly as the first pass does.
  const root = new FakeNode({ tag: "div", controller: "reactive" })
  root.append(
    checkbox("notes[]", "a", true),
    new FakeNode({ tag: "div", name: "notes[]", editor: true, value: null, textContent: "typed" }),
  )

  expect(await collect(root)).toEqual({ "notes[]": ["a", "typed"] })
})


test("a hidden under a group's name contributes even when an editor shares it", () => {
  // Nothing here can tell a hidden that MIRRORS an editor from one that is a
  // list JS maintains: both are `<input type="hidden">` under the same name.
  // Suppressing it would be the quieter failure — a doubled value shows up on
  // the wire, a swallowed one does not — so the hidden keeps its say. Measured
  // on THIS fixture with a rule that suppressed the hidden: `["typed"]`, its
  // own value gone.
  const root = new FakeNode({ tag: "div", controller: "reactive" })
  root.append(
    hidden("tag_ids[]", "h"),
    new FakeNode({ tag: "div", name: "tag_ids[]", editor: true, value: null, textContent: "typed" }),
  )

  return expect(collect(root)).resolves.toEqual({ "tag_ids[]": ["h", "typed"] })
})

test("a []-named radio keeps its chosen value when an editor shares the name", () => {
  // A radio keeps its single value with or without the suffix — that is why
  // #arrayFieldNames excepts it. An editor sharing the name must not turn that
  // scalar into a group: measured before this guard, the post came back as
  // {"pick[]": ["typed"]} and the chosen value was gone.
  const root = new FakeNode({ tag: "div", controller: "reactive" })
  root.append(
    new FakeNode({ tag: "input", type: "radio", name: "pick[]", value: "a", checked: true }),
    new FakeNode({ tag: "div", name: "pick[]", editor: true, value: null, textContent: "typed" }),
  )

  return expect(collect(root)).resolves.toEqual({ "pick[]": "a" })
})

test("an unupgraded rich editor contributes nothing to its group", () => {
  // Trix defines its elements in a setTimeout after load, so a save can run
  // while the editor is still a plain unupgraded tag with nothing to read.
  // Its "" is an ABSENT value, not an empty one, and pushing it would add a
  // phantom entry beside whatever else the group carries. persistSnapshot
  // omits such an editor for the same reason.
  const root = new FakeNode({ tag: "div", controller: "reactive" })
  root.append(
    hidden("notes[]", "<p>real</p>"),
    new FakeNode({ tag: "trix-editor", name: "notes[]", editor: true, value: null, textContent: null }),
  )

  return expect(collect(root)).resolves.toEqual({ "notes[]": ["<p>real</p>"] })
})


test("a LONE editor under a [] name posts an array, not a scalar", async () => {
  // The shape the fix was measured on: with no standard control under the
  // name there is no slot, and the old pass assigned — `{"notes[]": "typed"}`
  // on the wire against a declared array type, while the draft held ["typed"].
  const root = new FakeNode({ tag: "div", controller: "reactive" })
  root.append(new FakeNode({ tag: "div", name: "notes[]", editor: true, value: null, textContent: "typed" }))

  return expect(collect(root)).resolves.toEqual({ "notes[]": ["typed"] })
})

// --- the empty-group announcement (issue #258) ------------------------------
//
// A form body cannot carry an empty array, so a cleared group is ANNOUNCED
// instead: its key stays out of `params` and its name rides in `empty_groups[]`,
// a field of its own beside token/act/params. Announcing it rather than sending
// a blank keeps `[""]` meaning what it means — a `[:date]` or `[:file]` element
// reads a blank as "did not come in".

function fileInput(name = "attachment") {
  return new FakeNode({
    tag: "input",
    type: "file",
    name,
    files: [new File(["x"], "receipt.txt", { type: "text/plain" })],
  })
}

// Dispatches `save` on the root and returns the FormData that went over the
// wire. The file input is what makes the body multipart in the first place.
async function collectMultipart(root) {
  let captured = null
  globalThis.fetch = (path, opts) => {
    captured = opts
    return Promise.resolve({
      redirected: false,
      ok: true,
      headers: { get: () => "text/vnd.turbo-stream.html" },
      text: () => Promise.resolve(""),
    })
  }
  globalThis.document = { querySelector: () => null, dispatchEvent: () => {} }
  globalThis.window = { Turbo: { renderStreamMessage: () => {} } }

  const controller = new ReactiveController()
  controller.element = root
  controller.tokenValue = "tok"
  await controller.dispatch({ params: { action: "save", params: "{}" }, preventDefault: () => {} })

  expect(captured.body instanceof FormData).toBe(true)
  return captured.body
}

test("an empty group beside a file input is ANNOUNCED, not silently dropped", async () => {
  const root = new FakeNode({ tag: "div", controller: "reactive" })
  root.append(checkbox("features[]", "news", false), checkbox("features[]", "events", false), fileInput())

  const body = await collectMultipart(root)

  expect(body.getAll("params[features][]")).toEqual([])
  expect(body.getAll("empty_groups[]")).toEqual(["features"])
})

test("the announced name is the DOM name, so a scoped group carries its scope", async () => {
  // `reactive_scope :todo` renders todo[tags][]; the announcement drops only
  // the `[]` suffix, which is the name the endpoint resolves against the
  // declaration after it peels the scope.
  const root = new FakeNode({ tag: "div", controller: "reactive" })
  root.append(checkbox("todo[tags][]", "ruby", false), fileInput())

  const body = await collectMultipart(root)

  expect(body.getAll("empty_groups[]")).toEqual(["todo[tags]"])
})

test("the JSON path keeps sending [] and never announces", async () => {
  // No file, so the body is JSON — where an empty array is expressible and the
  // announcement has no reason to exist.
  const root = new FakeNode({ tag: "div", controller: "reactive" })
  root.append(checkbox("features[]", "news", false))

  expect(await collect(root)).toEqual({ "features[]": [] })
})
