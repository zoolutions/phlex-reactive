# frozen_string_literal: true

require "system_helper"

# Issue #428: a box and a point with scale: 100 (DragScaleComponent) in a real
# browser — their visible number fields hold percentages while they move, a
# field the drag did not move keeps the server's text ("50.0") and gets no
# change, the actions still receive fractions, and a morph that moves the box
# brings the fields outside it along in percent.
RSpec.describe "Draggable regions on a scale (issue #428)", type: :system do
  def values(prefix)
    page.evaluate_script(<<~JS)
      Object.fromEntries([...document.querySelectorAll('[name^="#{prefix}["]')].map((el) => [el.name.slice(#{prefix.length + 1}, -1), Number(el.value)]))
    JS
  end

  def center(testid)
    page.evaluate_script(<<~JS)
      (() => { const r = document.querySelector("[data-testid='#{testid}']").getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2] })()
    JS
  end

  def mouse_drag(testid, right, down, release: true)
    x0, y0 = center(testid)
    page.driver.with_playwright_page do
      it.mouse.move(x0, y0)
      it.mouse.down
      it.mouse.move(x0 + right, y0 + down, steps: 8)
      it.mouse.up if release
    end
  end

  def wait_for_features
    page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1]
      const root = document.querySelector("[data-controller~='reactive']")
      const tick = () => {
        const controller = window.Stimulus?.getControllerForElementAndIdentifier(root, "reactive")
        if (!controller) return setTimeout(tick, 20)
        controller.featuresReady.then(() => done(true))
      }
      tick()
    JS
  end

  def expect_saved(text) = expect(page).to have_css("[data-testid='scale-last']", text:)

  before do
    visit "/drag_scale"
    page.assert_selector("[data-testid='scale-box'][data-reactive-box-scale='100']")
    wait_for_features
    page.execute_script(<<~JS)
      window.__noReload = "alive"
      window.__changes = []
      document.addEventListener("change", (event) => window.__changes.push(event.target.name))
    JS
  end

  it "writes percentages while the box moves, and :crop still gets fractions" do
    mouse_drag("scale-box", 40, 20, release: false)
    expect(page).to have_field("region[x]", with: "20")
    expect(page).to have_field("region[y]", with: "20")
    # Not moved: the server's text stays, though the client would write "50".
    expect(page).to have_field("region[width]", with: "50.0")
    page.driver.with_playwright_page { it.mouse.up }
    expect_saved("1 crop 0.2 0.2 0.5 0.4")
    expect(values("region")).to eq("x" => 20, "y" => 20, "width" => 50, "height" => 40)
    expect(page.evaluate_script("window.__changes")).to eq(["region[x]", "region[y]"])
    expect(page.evaluate_script("window.__noReload")).to eq("alive")
  end

  it "writes percentages while the point moves, and :focus still gets fractions" do
    # The frame is 400 × 200 px: 20 px right is 5%, 20 px down 10%.
    mouse_drag("scale-point", 20, 20, release: false)
    expect(page).to have_field("marker[x]", with: "80")
    expect(page).to have_field("marker[y]", with: "60")
    page.driver.with_playwright_page { it.mouse.up }
    expect_saved("1 focus 0.8 0.6")
    expect(values("marker")).to eq("x" => 80, "y" => 60)
  end

  it "brings the fields outside a morph that moved the box along, in percent" do
    page.execute_script(<<~JS)
      const frame = document.getElementById("drag-scale-frame")
      const html = frame.outerHTML.replace("left: 10%", "left: 30%")
      Turbo.renderStreamMessage(`<turbo-stream action="replace" method="morph" target="drag-scale-frame"><template>${html}</template></turbo-stream>`)
    JS
    expect(page).to have_css("[data-testid='scale-box'][style*='left: 30%']")
    expect(page).to have_field("region[x]", with: "30")
    expect(page).to have_field("region[y]", with: "10.0")
  end
end
