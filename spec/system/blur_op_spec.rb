# frozen_string_literal: true

require "system_helper"

# Issue #399: js.blur(to) blurs document.activeElement when it is the target or
# inside it, so Escape ends a menu's :focus-within; focus elsewhere stays.
RSpec.describe "js.blur (issue #399)", type: :system do
  before do
    visit "/blur_menu"
    page.find("#blur-menu[data-controller='reactive']")
  end

  def active_id = page.evaluate_script("document.activeElement?.id")
  def menu_focus_within? = page.evaluate_script("document.getElementById('bm-menu').matches(':focus-within')")

  it "blurs a field inside the target, ending its :focus-within" do
    find("[data-testid='query']").click
    expect(menu_focus_within?).to be(true)

    find("[data-testid='query']").send_keys(:escape)

    expect(page).to have_no_css("#bm-menu:focus-within")
    expect(active_id).not_to eq("bm-query")
  end

  it "leaves focus alone when the active element is outside the target" do
    find("[data-testid='outside']").click
    find("[data-testid='outside']").send_keys(:escape)

    expect(page).to have_css("#bm-outside:focus")
    expect(active_id).to eq("bm-outside")
  end

  it "blurs the target itself when it is the active element" do
    find("[data-testid='self']").click
    expect(page).to have_css("#bm-self:focus")

    find("[data-testid='self']").send_keys(:escape)

    expect(page).to have_no_css("#bm-self:focus")
  end
end
