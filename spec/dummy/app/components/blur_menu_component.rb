# frozen_string_literal: true

# Issue #399: js.blur. Escape anywhere in the root blurs the focused element
# only when it sits inside #bm-menu, so the menu's :focus-within ends; a field
# outside the menu keeps its focus. #bm-self blurs itself on Escape. Declares
# no actions (client-op only).
class BlurMenuComponent < ApplicationComponent
  include Phlex::Reactive::Component

  def id = "blur-menu"

  def view_template
    div(**mix(reactive_root, on_client("keydown.esc", js.blur("#bm-menu")))) do
      div(id: "bm-menu") do
        input(id: "bm-query", type: "search", data: { testid: "query" })
      end
      input(id: "bm-outside", type: "text", data: { testid: "outside" })
      input(**mix(on_client("keydown.esc", js.blur("#bm-self")), id: "bm-self", type: "text", data: { testid: "self" }))
    end
  end
end
