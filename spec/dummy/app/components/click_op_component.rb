# frozen_string_literal: true

# Issue #471: js.click activates an element the way a user click does. The
# row link answers Space (js.click on its own trigger), and a button outside
# the form clicks the form's submit button. Both land as Turbo Drive visits
# back to this page, which says what arrived. No click binding sits on or above
# the link or the submit button (one would prevent the synthetic click's
# default). Declares no actions (client-op only).
class ClickOpComponent < ApplicationComponent
  include Phlex::Reactive::Component

  def initialize(arrived: nil)
    @arrived = arrived
  end

  def id = "click-op"

  def view_template
    div(**reactive_root) do
      p(data: { testid: "arrived" }) { @arrived || "none" }
      a(**mix(on_client("keydown.space", js.click), href: "/click_op?arrived=link", id: "co-link",
        data: { testid: "link" })) { "Item 1" }
      form(action: "/click_op", method: "get", id: "co-form") do
        input(type: "hidden", name: "arrived", value: "form")
        button(type: "submit", id: "co-submit") { "Submit" }
      end
      button(**mix(on_client(:click, js.click("#co-submit")), type: "button", data: { testid: "proxy" })) { "Send" }
    end
  end
end
