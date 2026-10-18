# frozen_string_literal: true

# The host of SharedBindingsPickerComponent (issue #440): a server component
# inside a native <form>. A group hidden by `mode` wraps the picker and disables
# its controls while hidden, so the picker's required value field must not
# block a native submit then. A section, the save button and a compute mirror
# follow the picker's value.
class SharedBindingsFormComponent < ApplicationComponent
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  reactive_state :saved
  reactive_compute :choice_echo, inputs: { choice: :string }, outputs: []
  action :save, params: { choice: :string, mode: :string }

  def initialize(saved: nil)
    @saved = saved
  end

  def id = "shared-bindings-form"

  def reactive_values = { mode: "a", choice: "" }

  def save(choice: nil, mode: nil)
    @saved = "choice=#{choice} mode=#{mode}"
  end

  def view_template
    form(action: "/shared_bindings", method: "get", data: { testid: "native-form" }) do
      div(**reactive_root(compute: :choice_echo, data: { testid: "shared-bindings-form" })) do
        select(name: "mode", data: { testid: "mode" }) do
          option(value: "a", selected: true) { "a" }
          option(value: "other") { "other" }
        end
        div(**reactive_show(if: { mode: "other" }, disable: true, data: { testid: "picker-group" })) do
          render SharedBindingsPickerComponent.new
        end
        div(**reactive_show(if: { choice: "b" }, data: { testid: "b-picked" })) { "b picked" }
        button(**mix(on(:save), reactive_enable(if: { choice: "b" }), type: "button", data: { testid: "save" })) { "Save" }
        p { reactive_text(:choice, data: { testid: "choice-echo" }) }
        span(data: { testid: "saved" }) { @saved.to_s }
      end
      button(type: "submit", data: { testid: "native-submit" }) { "Submit the form" }
    end
  end
end
