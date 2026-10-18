# frozen_string_literal: true

# Issue #442: a pickable list bound ONCE. The list carries one on_client
# record with within: "[role=option]"; each row carries only its data-*. A
# pick (a click anywhere in a row, or Enter on the row reactive_listnav
# highlights) writes the row's value into the hidden field, its label into the
# label node, marks it aria-selected and tells the page with a CustomEvent
# whose detail is read off the row. The "Recent" heading inside the list is no
# row: a click there runs nothing and keeps its default. Client-only: no
# action, no token.
class ItemPickerComponent < ApplicationComponent
  include Phlex::Reactive::ClientBindings

  ITEMS = [
    { id: 1, value: "north", label: "North" },
    { id: 2, value: "south", label: "South" },
    { id: 3, value: "east", label: "East" }
  ].freeze

  def view_template
    div(**reactive_root(id: "item-picker", data: { testid: "item-picker" })) do
      input(id: "item-value", type: "hidden", name: "item", data: { testid: "item-value" })
      input(id: "item-query", name: "q", type: "search", autocomplete: "off",
        **mix(reactive_listnav("[role=option]"), data: { testid: "item-query" }))
      span(id: "item-label", data: { testid: "item-label" })
      ul(id: "item-menu", role: "listbox",
        **mix(on_client(:click, pick_ops, within: "[role=option]"), data: { testid: "item-menu" })) do
        li(data: { testid: "item-gap" }) { "Recent" }
        ITEMS.each { row(it) }
      end
    end
  end

  private

  def row(item)
    li do
      button(type: "button", role: "option", id: "item-#{item[:id]}",
        data: { id: item[:id], value: item[:value], label: item[:label], testid: "item-#{item[:id]}" }) do
        span(data: { testid: "item-#{item[:id]}-text" }) { item[:label] }
      end
    end
  end

  def pick_ops
    js.set_value("#item-value", from: :trigger, attr: "data-value")
      .text("#item-label", from: :trigger, attr: "data-label")
      .remove_attr("[role=option]", "aria-selected")
      .set_attr(:trigger, "aria-selected", "true")
      .dispatch("app:item-picked", detail_from: { id: "data-id", value: "data-value", text: :text })
  end
end
