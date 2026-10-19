# frozen_string_literal: true

require "system_helper"

# Issue #446: Turbo renders every stream message inside its focus preservation.
# It reads document.activeElement, appends the streams, waits one animation
# frame and, when the element focused before has an id and focus moved,
# focuses that element again. A reply's focus, focus_first and blur ops run in
# that window, so they were undone, and the old field's focus binding ran
# again. Every field in ReplyFocusOpsComponent has an id.
#
# Runs under BOTH real servers (Puma default, Falcon via CAPYBARA_SERVER=falcon).
RSpec.describe "A reply's focus ops survive Turbo's stream focus restore (issue #446)", type: :system do
  # Turbo's restore runs one frame after the reply's streams render; two more
  # frames are past anything it could still do.
  def settle_frames
    page.evaluate_async_script("requestAnimationFrame(() => requestAnimationFrame(() => arguments[0]()))")
  end

  def count_focuses(testid)
    page.execute_script(<<~JS, testid)
      window.__focuses = 0
      document.querySelector(`[data-testid="${arguments[0]}"]`).addEventListener("focus", () => window.__focuses++)
    JS
  end

  def active_testid
    page.evaluate_script("document.activeElement && document.activeElement.dataset.testid")
  end

  it "a listnav Enter pick blurs the query, and its focus binding does not run again" do
    visit "/reply_focus_ops"
    page.execute_script("window.__noReload = 'alive'")
    query = find("[data-testid='picker-query']")
    query.click
    expect(page).to have_css("[data-testid='picker-list']", visible: :visible)
    count_focuses("picker-query")

    query.send_keys(:down)
    query.send_keys(:enter)

    expect(page).to have_css("[data-testid='picked']", text: "Alpha")
    expect(page).to have_no_css("[data-testid='picker-query']:focus")
    settle_frames
    expect(page).to have_no_css("[data-testid='picker-query']:focus")
    expect(page).to have_css("[data-testid='picker-list']", visible: :hidden)
    expect(page.evaluate_script("window.__focuses")).to eq(0)
    expect(page.evaluate_script("window.__noReload")).to eq("alive")
  end

  it "a focus op moves focus off a field with an id, and it stays moved" do
    visit "/reply_focus_ops"
    field = find("[data-testid='jump-to-field']")
    field.click
    count_focuses("jump-to-field")

    field.send_keys(:enter)

    expect(page).to have_css("[data-testid='jumps']", text: "1")
    expect(page).to have_css("[data-testid='jump-target']:focus")
    settle_frames
    expect(active_testid).to eq("jump-target")
    expect(page.evaluate_script("window.__focuses")).to eq(0)
  end

  it "a focus_first op moves focus into the menu, and it stays there" do
    visit "/reply_focus_ops"
    field = find("[data-testid='jump-to-menu']")
    field.click
    count_focuses("jump-to-menu")

    field.send_keys(:enter)

    expect(page).to have_css("[data-testid='jumps']", text: "1")
    expect(page).to have_css("[data-testid='jump-menu-first']:focus")
    settle_frames
    expect(active_testid).to eq("jump-menu-first")
    expect(page.evaluate_script("window.__focuses")).to eq(0)
  end
end
