# frozen_string_literal: true

# Fill-then-add with clear: :reset (issue #466). Each add control renders a
# DEFAULT — a quantity of 1, a preselected price, a ticked "gift" checkbox —
# and after every Add the sources go back to those defaults (the way a form
# reset would) instead of being emptied, so a default-on checkbox stays on for
# the next entry.
class DraftOrderFillResetFormComponent < ApplicationComponent
  include Phlex::Reactive::ClientBindings

  reactive_scope :order

  def view_template
    div(**mix(reactive_root(id: "draft_order_fill_reset_form", data: { testid: "draft-order-fill-reset" }))) do
      label(for: "src-qty") { "Quantity" }
      input(id: "src-qty", type: "number", value: "1", data: { testid: "src-qty" })
      label(for: "src-price") { "Price" }
      select(id: "src-price", data: { testid: "src-price" }) do
        option(value: "10") { "10" }
        option(value: "20", selected: true) { "20" }
        option(value: "30") { "30" }
      end
      label(for: "src-gift") { "Gift" }
      input(id: "src-gift", type: "checkbox", checked: true, data: { testid: "src-gift" })

      div(**mix(reactive_nested_list(:line_items), data: { testid: "items" }))
      template(**reactive_nested_template(:line_items)) { row_fields }
      button(**mix(
        reactive_nested_add(:line_items,
          from: { quantity: "#src-qty", price: "#src-price", gift: "#src-gift" },
          clear: :reset),
        data: { testid: "add-item" }
      )) { "Add item" }
    end
  end

  private

  def row_fields
    div(**mix(reactive_nested_row, data: { testid: "item-row" })) do
      input(name: nested_field_name(:line_items, :quantity), type: "number", data: { testid: "qty" })
      input(name: nested_field_name(:line_items, :price), type: "number", data: { testid: "price" })
      input(name: nested_field_name(:line_items, :gift), type: "checkbox", value: "1", data: { testid: "gift" })
    end
  end
end
