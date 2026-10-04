// Unit test for roving-focus list navigation (issue #271) —
// reactive_listnav(focus: true) spread on a role=menu container. The trigger
// (the container) carries data-reactive-listnav-focus-param="true"; Arrow
// Down/Up move REAL focus among the items (wrapping), Home/End jump to the
// edges. "Current" is the item that is or contains document.activeElement. No
// highlight attr is written; hidden items and nested-root items are skipped.
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

const HIGHLIGHT = "data-reactive-highlighted"

function makeItem(label) {
  const attrs = {}
  const item = {
    label,
    hidden: false,
    _root: null,
    scrolled: 0,
    getAttribute: (k) => attrs[k] ?? null,
    setAttribute: (k, v) => (attrs[k] = String(v)),
    removeAttribute: (k) => delete attrs[k],
    hasAttribute: (k) => k in attrs,
    contains: (other) => other === item,
    focus() {
      globalThis.document.activeElement = item
    },
    scrollIntoView() {
      item.scrolled++
    },
    closest() {
      return item._root
    },
  }
  return item
}

// The menu container is the event's currentTarget (the listnav trigger); the
// items live under the controller root.
function setup(items, { selector = "[role=menuitem]", focusMode = true, nestedRoots = [] } = {}) {
  const root = {
    id: "menu-root",
    getAttribute: () => null,
    querySelectorAll: (sel) => (sel === selector ? items.slice() : sel.includes("data-controller") ? nestedRoots : []),
    closest: () => null,
  }
  for (const item of items) item._root ??= root
  const menuAttrs = { "data-reactive-listnav-option-param": selector }
  if (focusMode) menuAttrs["data-reactive-listnav-focus-param"] = "true"
  const menu = { getAttribute: (k) => menuAttrs[k] ?? null }
  const controller = new ReactiveController()
  controller.element = root
  globalThis.window ??= {}
  globalThis.document = { activeElement: null, querySelectorAll: () => [] }
  return { controller, menu }
}

function keyEvent(menu) {
  return {
    currentTarget: menu,
    defaultPrevented: false,
    preventDefault() {
      this.defaultPrevented = true
    },
  }
}

const focusedLabel = () => globalThis.document.activeElement?.label ?? null

test("from nothing, Down focuses the first item and Up the last", () => {
  const items = [makeItem("a"), makeItem("b"), makeItem("c")]
  const { controller, menu } = setup(items)

  controller.listnavNext(keyEvent(menu))
  expect(focusedLabel()).toBe("a")

  globalThis.document.activeElement = null
  controller.listnavPrev(keyEvent(menu))
  expect(focusedLabel()).toBe("c")
})

test("Down/Up move focus from the focused item and wrap", () => {
  const items = [makeItem("a"), makeItem("b"), makeItem("c")]
  const { controller, menu } = setup(items)

  items[0].focus()
  controller.listnavNext(keyEvent(menu))
  expect(focusedLabel()).toBe("b")
  controller.listnavNext(keyEvent(menu))
  controller.listnavNext(keyEvent(menu))
  expect(focusedLabel()).toBe("a") // wrapped
  controller.listnavPrev(keyEvent(menu))
  expect(focusedLabel()).toBe("c") // wrapped back
})

test("Home and End jump to the first and last item", () => {
  const items = [makeItem("a"), makeItem("b"), makeItem("c")]
  const { controller, menu } = setup(items)

  items[1].focus()
  controller.listnavLast(keyEvent(menu))
  expect(focusedLabel()).toBe("c")
  controller.listnavFirst(keyEvent(menu))
  expect(focusedLabel()).toBe("a")
})

test("current is the item that CONTAINS the focused element", () => {
  const items = [makeItem("a"), makeItem("b"), makeItem("c")]
  const inner = { label: "inner-of-b" }
  items[1].contains = (other) => other === items[1] || other === inner
  const { controller, menu } = setup(items)

  globalThis.document.activeElement = inner
  controller.listnavNext(keyEvent(menu))

  expect(focusedLabel()).toBe("c")
})

test("hidden items and nested-root items are skipped", () => {
  const nestedRoot = { id: "nested" }
  const items = [makeItem("a"), makeItem("hidden"), makeItem("nested"), makeItem("d")]
  items[1].hidden = true
  items[2]._root = nestedRoot
  const { controller, menu } = setup(items, { nestedRoots: [nestedRoot] })

  items[0].focus()
  controller.listnavNext(keyEvent(menu))

  expect(focusedLabel()).toBe("d")
})

test("writes no highlight attr, scrolls the item into view, and preventDefaults", () => {
  const items = [makeItem("a"), makeItem("b")]
  const { controller, menu } = setup(items)

  const event = keyEvent(menu)
  controller.listnavNext(event)

  expect(items.some((i) => i.hasAttribute(HIGHLIGHT))).toBe(false)
  expect(items[0].scrolled).toBe(1)
  expect(event.defaultPrevented).toBe(true)
})

test("highlight mode: listnavFirst/listnavLast highlight the edges (direct invocation)", () => {
  const items = [makeItem("a"), makeItem("b"), makeItem("c")]
  const { controller, menu } = setup(items, { selector: "[role=option]", focusMode: false })

  controller.listnavLast(keyEvent(menu))
  expect(items.findIndex((i) => i.hasAttribute(HIGHLIGHT))).toBe(2)
  controller.listnavFirst(keyEvent(menu))
  expect(items.findIndex((i) => i.hasAttribute(HIGHLIGHT))).toBe(0)
  expect(focusedLabel()).toBe(null) // highlight mode never moves focus
})
