# frozen_string_literal: true

require "system_helper"

# Issue #271: an accessible disclosure menu (the WAI-ARIA menu-button pattern)
# built from on_client alone — zero actions, zero custom JS. It exercises all
# three gaps: aria-expanded kept honest (two-value toggle_attr on click,
# expanded: on ArrowDown/Escape/outside/item), roving focus among
# role=menuitem (reactive_listnav(focus: true)), and two on_client bindings on
# one element composing through mix (trigger: click + keydown.down; root:
# click@window outside + keydown.esc). A fetch spy proves nothing is posted.
RSpec.describe "Disclosure menu (issue #271 — on_client only)", type: :system do
  def install_fetch_spy
    page.execute_script(<<~JS)
      window.__fetchCount = 0
      const original = window.fetch
      window.fetch = (...args) => { window.__fetchCount += 1; return original(...args) }
    JS
  end

  def trigger = find("[data-testid='dm-trigger']")

  def expect_expanded(value)
    expect(page).to have_css("[data-testid='dm-trigger'][aria-expanded='#{value}']")
  end

  def expect_focused(testid)
    expect(page).to have_css("[data-testid='#{testid}']:focus")
  end

  before do
    visit "/disclosure_menu"
    page.execute_script("window.__noReload = 'alive'")
    install_fetch_spy
  end

  # Every example ends here: the whole exchange was client-side.
  def expect_no_round_trip
    expect(page.evaluate_script("window.__fetchCount")).to eq(0)
    expect(page.evaluate_script("window.__noReload")).to eq("alive")
  end

  it "toggles on click with aria-expanded in sync" do
    expect_expanded("false")
    expect(page).to have_css("[data-testid='dm-menu']", visible: :hidden)

    trigger.click
    expect(page).to have_css("[data-testid='dm-menu']")
    expect_expanded("true")

    trigger.click
    expect(page).to have_css("[data-testid='dm-menu']", visible: :hidden)
    expect_expanded("false")

    expect_no_round_trip
  end

  it "opens on ArrowDown, roves focus with Arrow/Home/End, and closes on Escape back to the trigger" do
    trigger.send_keys(:down)
    expect(page).to have_css("[data-testid='dm-menu']")
    expect_expanded("true")
    expect_focused("dm-item-1")

    find("[data-testid='dm-item-1']").send_keys(:down)
    expect_focused("dm-item-2")

    find("[data-testid='dm-item-2']").send_keys(:end)
    expect_focused("dm-item-3")

    find("[data-testid='dm-item-3']").send_keys(:home)
    expect_focused("dm-item-1")

    find("[data-testid='dm-item-1']").send_keys(:up)
    expect_focused("dm-item-3") # wrapped

    find("[data-testid='dm-item-3']").send_keys(:escape)
    expect(page).to have_css("[data-testid='dm-menu']", visible: :hidden)
    expect_expanded("false")
    expect_focused("dm-trigger")

    expect_no_round_trip
  end

  it "closes on an outside click" do
    trigger.click
    expect(page).to have_css("[data-testid='dm-menu']")

    find("[data-testid='dm-outside']").click
    expect(page).to have_css("[data-testid='dm-menu']", visible: :hidden)
    expect_expanded("false")

    expect_no_round_trip
  end

  it "closes when an item is picked and paints the pick" do
    trigger.click
    find("[data-testid='dm-item-2']").click

    expect(page).to have_css("[data-testid='dm-menu']", visible: :hidden)
    expect_expanded("false")
    expect(page).to have_css("[data-testid='dm-status']", text: "Duplicate")

    expect_no_round_trip
  end
end
