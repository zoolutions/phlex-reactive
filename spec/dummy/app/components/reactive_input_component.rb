# frozen_string_literal: true

# Exercises the reactive_input/reactive_select param-binding helpers (issue #23).
# The edit-mode controls bind to the :save action's `value:`/`status:` params via
# reactive_input/reactive_select — no hand-written `name: "value"` magic string.
class ReactiveInputComponent < ApplicationComponent
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  reactive_record :record
  reactive_state :attribute

  action :save, params: { value: :string, status: :string }

  STATUSES = %w[open closed].freeze

  def initialize(record:, attribute: :title)
    @record = record
    @attribute = attribute.to_sym
  end

  def id = dom_id(@record, "reactive_input")

  # `status` is rendered only to exercise reactive_select's name binding (the
  # dummy Todo has no status column); the edited attribute is what we persist.
  def save(value: nil, status: nil)
    @record.update!(@attribute => value) if value
  end

  def view_template
    div(id:, **reactive_attrs) do
      # One binding helper (issue #184): reactive_field emits name="value"; the
      # element (input/select/textarea) is the caller's.
      input(**reactive_field(:value, value: @record.public_send(@attribute).to_s, data: { testid: "field" }))

      select(**reactive_field(:status, data: { testid: "status" })) do
        # Named param required: the inner Phlex content block reuses `s`, so `it`
        # would collapse both blocks onto one implicit param (wrong output).
        STATUSES.each { |s| option(value: s) { s } }
      end

      button(**mix(on(:save), data: { testid: "save" })) { "Save" }
    end
  end
end
