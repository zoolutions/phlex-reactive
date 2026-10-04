# frozen_string_literal: true

# Issue #271: an accessible disclosure menu (the WAI-ARIA menu-button pattern)
# with NO actions and NO custom JS — every behavior is a declared on_client op:
#
# * the trigger keeps aria-expanded honest: a two-value toggle_attr on click,
#   expanded: on ArrowDown (open + focus the first item);
# * the menu roves focus among role=menuitem with Arrow/Home/End
#   (reactive_listnav(focus: true));
# * the root closes the menu on an outside click AND on Escape (focus back to
#   the trigger) — two on_client bindings on one element, composed by mix.
#
# The trigger deliberately uses BOTH aria forms so the demo covers each.
class DisclosureMenuComponent < ApplicationComponent
  include Phlex::Reactive::Component

  ITEMS = %w[Rename Duplicate Archive].freeze

  def id = "disclosure-menu"

  def view_template
    close = js.hide("#dm-menu", expanded: "#dm-trigger")

    div(**mix(reactive_root,
      on_client(:click, close, outside: true),
      on_client("keydown.esc", close.focus("#dm-trigger")))) do
      trigger
      menu
      p do
        plain "Picked: "
        span(id: "dm-status", data: { testid: "dm-status" }) { "nothing" }
      end
    end
  end

  private

  def trigger
    # aria_expanded is the STRING "false": Phlex drops a boolean false entirely.
    button(id: "dm-trigger", aria_haspopup: "menu", aria_expanded: "false", aria_controls: "dm-menu",
      **mix(on_client(:click, js.toggle("#dm-menu").toggle_attr("#dm-trigger", "aria-expanded", "true", "false").focus_first("#dm-menu")),
        on_client("keydown.down", js.show("#dm-menu", expanded: "#dm-trigger").focus_first("#dm-menu")),
        data: { testid: "dm-trigger" })) { "Actions" }
  end

  def menu
    ul(id: "dm-menu", role: "menu", hidden: true, aria_labelledby: "dm-trigger",
      **mix(reactive_listnav(focus: true), data: { testid: "dm-menu" })) do
      ITEMS.each.with_index(1) do |label, index|
        li(role: "none") do
          button(role: "menuitem", tabindex: "-1",
            **mix(on_client(:click, js.hide("#dm-menu", expanded: "#dm-trigger").text("#dm-status", label).focus("#dm-trigger")),
              data: { testid: "dm-item-#{index}" })) { label }
        end
      end
    end
  end
end
