# frozen_string_literal: true

# Issue #471: js.click activates an element the way a user click does. The
# row link answers Space (js.click on its own trigger), and a button outside
# the form clicks the form's submit button. Both land as Turbo Drive visits
# back to this page, which says what arrived. No click binding sits on or above
# the first link or the submit button (one would prevent the synthetic click's
# default); the second link sits under a click binding with prevent: false,
# which lets the activation through. Declares no actions (client-op only).
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
      div(**mix(on_client(:click, js.set_attr(:trigger, "data-heard", "true"), prevent: false), id: "co-wrap",
        data: { testid: "wrap" })) do
        a(href: "/click_op?arrived=wrapped", id: "co-wrapped") { "Wrapped" }
      end
      button(**mix(on_client(:click, js.click("#co-wrapped")), type: "button", data: { testid: "wrapped-proxy" })) do
        "Open wrapped"
      end
    end
  end
end
