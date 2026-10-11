# frozen_string_literal: true

# The editable LateEditableComponent appends into its slot (issue #351).
class LateEditableTitleComponent < ApplicationComponent
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::ClientBindings

  def id = "late-title"

  def view_template
    h3(id:, **mix(reactive_editable(:title), data: { testid: "late-title" })) { "Draft" }
  end
end
