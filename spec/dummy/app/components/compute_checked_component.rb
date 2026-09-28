# frozen_string_literal: true

# Issue #262 repro: a compute root whose inputs AND outputs include the
# checked-state controls — a Rails checkbox pair, a lone valueless checkbox and
# a radio group. Before #262 #recompute read `.value` first-wins, so the reducer
# got the hidden companion's constant "0", `Number("on")` and the first radio's
# value, whatever the user had ticked; an output wrote `.value` on the companion.
#
# One input per declared type, so the spec pins each coercion against a real
# browser: `gift` untyped (number → 1/0), `express` :boolean, `shipping` :string.
# The `readings` text node prints the typeof + value the reducer received.
#
# CLIENT-ONLY (no reactive_record / reactive_state), like ComputeSeedComponent.
class ComputeCheckedComponent < ApplicationComponent
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  SHIPPING = %w[pickup post courier].freeze
  TIERS = %w[basic plus].freeze

  reactive_compute :checked_total,
    inputs: [:price, :gift, { express: :boolean, shipping: :string }],
    outputs: %i[total free_shipping tier]

  def id = "compute-checked"

  def view_template
    div(**reactive_root(compute: :checked_total)) do
      input(**reactive_field(:price, value: 100, type: "number", data: { testid: "price" }))
      inputs
      input(**reactive_field(:total, value: "", type: "number", data: { testid: "total" }))
      outputs
      p(data: { testid: "readings" }) { reactive_text(:readings) }
    end
  end

  private

  def inputs
    # The Rails check_box shape: the hidden companion comes FIRST, same name.
    input(type: "hidden", name: "gift", value: "0", autocomplete: "off")
    input(type: "checkbox", name: "gift", value: "1", data: { testid: "gift" })
    # A lone box with NO value attribute: its .value is the constant "on".
    input(type: "checkbox", name: "express", data: { testid: "express" })
    SHIPPING.each do
      input(type: "radio", name: "shipping", value: it, checked: it == "post", data: { testid: "shipping-#{it}" })
    end
  end

  # Both rendered UNSET, so a ticked box / checked radio proves the reducer's
  # output wrote the checked state.
  def outputs
    input(type: "hidden", name: "free_shipping", value: "0", autocomplete: "off", data: { testid: "free-shipping-off" })
    input(type: "checkbox", name: "free_shipping", value: "1", data: { testid: "free-shipping" })
    TIERS.each { input(type: "radio", name: "tier", value: it, data: { testid: "tier-#{it}" }) }
  end
end
