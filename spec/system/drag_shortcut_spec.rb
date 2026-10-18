# frozen_string_literal: true

require "system_helper"

# Issue #429: a window `esc` shortcut skips an Escape the drag feature already
# took to cancel a drag (it calls preventDefault), for on() and on_client
# alike; `handled: true` runs regardless, and with no drag one Escape runs
# every shortcut on the chord. DragShortcutComponent holds the box beside
# :close (esc) and :leave (handled: true); DragShortcutPanelComponent, a
# client-only root, shows a panel on esc.
#
# Every Escape shortcut's effect is checked after a LATER barrier: the
# component's requests run one after another, so once a second Escape (no
# drag) shows `leaves 2`, a :close the drag's Escape had sent would have
# landed too.
RSpec.describe "Shortcuts skip a key a drag already handled (issue #429)", type: :system do
  def wait_for_features
    page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1]
      const roots = [...document.querySelectorAll("[data-controller~='reactive']")]
      const tick = () => {
        const controllers = roots.map((el) => window.Stimulus?.getControllerForElementAndIdentifier(el, "reactive"))
        if (controllers.some((c) => !c)) return setTimeout(tick, 20)
        Promise.all(controllers.map((c) => c.featuresReady)).then(() => done(true))
      }
      tick()
    JS
  end

  def box_center
    page.evaluate_script(<<~JS)
      (() => { const r = document.querySelector("[data-testid='box']").getBoundingClientRect(); return [r.left + r.width * 0.5, r.top + r.height * 0.5] })()
    JS
  end

  def escape_with_no_drag
    page.driver.with_playwright_page { it.keyboard.press("Escape") }
  end

  # After the drag's Escape: the box is back, only the handled: true shortcut
  # ran; then a plain Escape runs them all, once each.
  def expect_only_handled_ran
    expect(page).to have_css("[data-testid='box'][style*='left: 10%']")
    expect(page).to have_css("[data-testid='leaves']", exact_text: "leaves 1")
    expect(page).to have_css("[data-testid='esc-panel']", visible: :hidden)

    escape_with_no_drag
    expect(page).to have_css("[data-testid='leaves']", exact_text: "leaves 2")
    expect(page).to have_css("[data-testid='closes']", exact_text: "closes 1")
    expect(page).to have_css("[data-testid='esc-panel']", visible: :visible)
    expect(page.evaluate_script("window.__noReload")).to eq("alive")
  end

  before do
    visit "/drag_shortcut"
    page.assert_selector("[data-testid='box'][data-reactive-box]")
    wait_for_features
    page.execute_script('window.__noReload = "alive"')
  end

  it "runs every Escape shortcut when no drag is on" do
    find("[data-testid='closes']").click
    escape_with_no_drag

    expect(page).to have_css("[data-testid='closes']", exact_text: "closes 1")
    expect(page).to have_css("[data-testid='leaves']", exact_text: "leaves 1")
    expect(page).to have_css("[data-testid='esc-panel']", visible: :visible)
  end

  it "cancels a keyboard drag on Escape without running the plain esc shortcuts" do
    page.execute_script("document.querySelector(\"[data-testid=box]\").focus()")
    page.driver.with_playwright_page do
      it.keyboard.down("ArrowRight")
      it.keyboard.press("Escape")
      it.keyboard.up("ArrowRight")
    end

    expect_only_handled_ran
  end

  it "cancels a pointer drag on Escape without running the plain esc shortcuts" do
    x0, y0 = box_center
    page.driver.with_playwright_page do
      it.mouse.move(x0, y0)
      it.mouse.down
      it.mouse.move(x0 + 80, y0 + 40, steps: 8)
    end
    expect(page).to have_css("[data-testid='box'][data-reactive-dragging][style*='left: 30%']")
    page.driver.with_playwright_page do
      it.keyboard.press("Escape")
      it.mouse.up
    end

    expect_only_handled_ran
  end
end
