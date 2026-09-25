# frozen_string_literal: true

# Exercises nested/array param coercion (issue #16). The `save` action declares
# an array-of-scalar param and an array-of-hash (Rails nested-attributes shape)
# plus a flat scalar, then reflects the COERCED result as JSON so request specs
# can assert exact types (integers stay integers, floats floats, booleans
# booleans) and that undeclared nested keys are dropped.
class NestedParamsComponent < ApplicationComponent
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  reactive_state :received

  action :save, params: {
    date: :string,
    bank_account_ids: [:integer],
    invoice_items_attributes: [{ id: :integer, quantity: :float, price: :float, _destroy: :boolean }]
  }

  # Issue #21: a model-scoped nested hash, matching what a Rails Form(model:)
  # posts as flat bracketed keys (invoice[date], invoice[status], …).
  action :save_invoice, params: {
    date: :string,
    invoice: { date: :string, status: :string, total: :float, active: :boolean }
  }

  # The same two shapes declared with STRING keys, which `compile` keeps as
  # written — so the dropped-param hints have to read both forms.
  action :save_string_schema, params: {
    "date" => :string,
    "invoice" => { "status" => :string }
  }

  def initialize(received: nil)
    @received = received
  end

  def id = "nested-params"

  def save(date: nil, bank_account_ids: nil, invoice_items_attributes: nil)
    @received = {
      date:,
      bank_account_ids:,
      invoice_items_attributes:
    }
  end

  def save_invoice(date: nil, invoice: nil)
    @received = { date:, invoice: }.compact
  end

  def save_string_schema(date: nil, invoice: nil)
    @received = { date:, invoice: }.compact
  end

  def view_template
    div(id:, **reactive_attrs) do
      # Reflect the exact coerced structure (types intact) for assertions.
      pre(data: { testid: "received" }) { @received.to_json }
    end
  end
end
