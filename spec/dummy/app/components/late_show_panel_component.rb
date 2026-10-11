# frozen_string_literal: true

# The show target LateShowComponent appends into its slot (issue #356). It is
# rendered visible: only the client's binding hides it while mode is not "pro".
class LateShowPanelComponent < ApplicationComponent
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::ClientBindings

  def id = "late-show-panel"

  def view_template
    div(id:, **reactive_show(if: { mode: "pro" }, data: { testid: "pro-panel" })) { "Pro options" }
  end
end
