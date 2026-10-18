# frozen_string_literal: true

# A client-only picker (issue #440): its own root for the option filter and its
# ops, and the chosen value in a REQUIRED named field inside that root, marked
# with reactive_shared_field so the form around it reads it in its client
# bindings (a show, an enable, a disable: true group, a compute input).
class SharedBindingsPickerComponent < ApplicationComponent
  include Phlex::Reactive::ClientBindings

  OPTIONS = %w[a b c].freeze

  def reactive_values = { q: "" }

  def view_template
    div(**mix(
      reactive_root(id: "bindings-picker", data: { testid: "bindings-picker" }),
      reactive_filter(:q, option: "[data-option]")
    )) do
      input(**reactive_shared_field(name: "choice", required: true, value: "", data: { testid: "picker-choice" }))
      input(name: "q", form: "bindings-picker-unowned", data: { testid: "picker-q" })
      OPTIONS.each do |option|
        button(**mix(
          on_client(:click, js.set_value("[name=choice]", option)),
          type: "button", data: { option: true, testid: "picker-option-#{option}" }
        )) { option }
      end
    end
  end
end
