# frozen_string_literal: true

require "system_helper"

# Issue #416: draggable regions in a real browser — a crop box over a
# 400 × 200 px frame (DragCropComponent) moved and resized with a mouse and a
# finger, clamped to the frame and min:, re-fitted by its aspect presets,
# driven by the keyboard with its announcements, put back by Escape, moved by
# a server morph (also one that lands mid-drag), and its :crop action sent
# once per release. A client-only box (DragClientComponent) does it all with
# no action and no token.
RSpec.describe "Draggable regions (issue #416)", type: :system do
  # Where a drag presses, in fractions of the element: the crop box off-centre,
  # since its focal point sits in the middle.
  def off_centre(testid) = testid == "crop-box" ? [0.25, 0.25] : [0.5, 0.5]

  def values(prefix = "crop")
    page.evaluate_script(<<~JS)
      Object.fromEntries(["x", "y", "width", "height"].map((k) => [k, document.querySelector('[name="#{prefix}[' + k + ']"]')?.value]).filter(([, v]) => v != null).map(([k, v]) => [k, Number(v)]))
    JS
  end

  # A spot inside the element, in fractions of its rect.
  def center(testid, spot = [0.5, 0.5])
    page.evaluate_script(<<~JS)
      (() => { const r = document.querySelector("[data-testid='#{testid}']").getBoundingClientRect(); return [r.left + r.width * #{spot[0]}, r.top + r.height * #{spot[1]}] })()
    JS
  end

  # A real mouse drag: press on `testid`, move `right` and `down` px in steps,
  # release (or not).
  def mouse_drag(testid, right, down, release: true)
    x0, y0 = center(testid, off_centre(testid))
    page.driver.with_playwright_page do
      it.mouse.move(x0, y0)
      it.mouse.down
      it.mouse.move(x0 + right, y0 + down, steps: 8)
      it.mouse.up if release
    end
  end

  # A real touch drag: Chromium's Input.dispatchTouchEvent.
  def touch_drag(testid, right, down)
    x0, y0 = center(testid, off_centre(testid))
    page.driver.with_playwright_page do
      cdp = it.context.new_cdp_session(it)
      cdp.send_message("Emulation.setTouchEmulationEnabled", params: { enabled: true, maxTouchPoints: 1 })
      touch = lambda { |type, left, top|
        points = type == "touchEnd" ? [] : [{ x: left, y: top }]
        cdp.send_message("Input.dispatchTouchEvent", params: { type:, touchPoints: points })
      }
      touch.call("touchStart", x0, y0)
      8.times { touch.call("touchMove", x0 + (right * (it + 1) / 8.0), y0 + (down * (it + 1) / 8.0)) }
      touch.call("touchEnd", x0 + right, y0 + down)
    end
  end

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

  def expect_saved(count, text = nil)
    expect(page).to have_css("[data-testid='crop-last']", text: [count, text].compact.join(" "))
  end

  before do
    visit "/drag"
    page.assert_selector("[data-testid='crop-box'][data-reactive-box]")
    wait_for_features
    page.execute_script('window.__noReload = "alive"')
  end

  it "renders the box where value: puts it, with no JavaScript needed" do
    box = page.evaluate_script(<<~JS)
      (() => { const f = document.querySelector("[data-testid='crop-frame']").getBoundingClientRect(); const b = document.querySelector("[data-testid='crop-box']").getBoundingClientRect(); return [b.left - f.left, b.top - f.top, b.width, b.height] })()
    JS
    expect(box).to eq([40, 20, 200, 80])
  end

  it "moves with a mouse drag, sends :crop once on release, and the reply agrees" do
    mouse_drag("crop-box", 40, 20)
    expect_saved(1, "crop 0.2 0.2 0.5 0.4")
    expect(values).to eq("x" => 0.2, "y" => 0.2, "width" => 0.5, "height" => 0.4)
    expect(page).to have_no_css("[data-reactive-dragging], [data-reactive-frame-active]")
    expect(page.evaluate_script("window.__noReload")).to eq("alive")
  end

  it "resizes from a handle, stopping at the frame's edge and at min:" do
    mouse_drag("handle-se", 400, 400)
    expect_saved(1, "crop 0.1 0.1 0.9 0.9")
    mouse_drag("handle-nw", 400, 400)
    expect_saved(2, "crop 0.9 0.9 0.1 0.1")
  end

  it "moves with a touch drag" do
    touch_drag("crop-box", -20, 20)
    expect_saved(1, "crop 0.05 0.2 0.5 0.4")
  end

  it "keeps the picked aspect while resizing, and re-fits the box when the preset changes" do
    find("[data-testid='aspect-2:1']").click
    # 2:1 in a 2:1 frame: as many fractions wide as tall, same area, same centre
    expect_saved(1, "crop 0.1264 0.0764 0.4472 0.4472")
    mouse_drag("handle-e", 40, 0)
    expect_saved(2)
    width, height = values.values_at("width", "height")
    expect(width).to be_within(0.001).of(height)
  end

  it "moves and resizes with the keyboard, announcing each step, and Escape puts it back" do
    box = find("[data-testid='crop-box']")
    box.send_keys(:right)
    expect(page).to have_css("[data-reactive-drag-live]", text: "Moved to 11%, 10%", visible: :all)
    expect_saved(1, "crop 0.11 0.1 0.5 0.4")
    box.send_keys(%i[shift down])
    expect_saved(2, "crop 0.11 0.2 0.5 0.4")
    box.send_keys(%i[alt right])
    expect(page).to have_css("[data-reactive-drag-live]", text: "Resized to 51% by 40%", visible: :all)
    expect_saved(3, "crop 0.11 0.2 0.51 0.4")
    # Escape while the arrow is still down puts the step back; its keyup sends nothing.
    page.execute_script("document.querySelector(\"[data-testid=crop-box]\").focus()")
    page.driver.with_playwright_page do
      it.keyboard.down("ArrowRight")
      it.keyboard.press("Escape")
      it.keyboard.up("ArrowRight")
    end
    expect(page).to have_css("[data-reactive-drag-live]", text: "Cancelled", visible: :all)
    expect(values).to eq("x" => 0.11, "y" => 0.2, "width" => 0.51, "height" => 0.4)
    # The next release is save #4 (requests are queued in order).
    box.send_keys(:left)
    expect_saved(4, "crop 0.1 0.2 0.51 0.4")
  end

  it "puts a pointer drag back on Escape, sending nothing" do
    mouse_drag("crop-box", 80, 40, release: false)
    expect(page).to have_css("[data-testid='crop-box'][style*='left: 30%']")
    page.driver.with_playwright_page do
      it.keyboard.press("Escape")
      it.mouse.up
    end
    expect(page).to have_css("[data-testid='crop-box'][style*='left: 10%']")
    expect(values).to eq("x" => 0.1, "y" => 0.1, "width" => 0.5, "height" => 0.4)
    # The next release is the FIRST request (requests are queued in order).
    find("[data-testid='crop-box']").send_keys(:right)
    expect_saved(1, "crop 0.11 0.1 0.5 0.4")
  end

  it "moves the box when a server morph renders new values" do
    find("[data-testid='crop-reset']").click
    expect(page).to have_css("[data-testid='crop-box'][style*='left: 25%']")
    expect(values).to eq("x" => 0.25, "y" => 0.25, "width" => 0.5, "height" => 0.5)
  end

  it "keeps a drag going through a morph that lands mid-drag" do
    mouse_drag("crop-box", 40, 0, release: false)
    # A server-side morph of the whole root with the box somewhere else.
    page.execute_script(<<~JS)
      const root = document.getElementById("drag-crop")
      const html = root.outerHTML.replace(/left: [\\d.]+%/, "left: 70%").replace('value="0.1"', 'value="0.7"')
      Turbo.renderStreamMessage(`<turbo-stream action="replace" method="morph" target="drag-crop"><template>${html}</template></turbo-stream>`)
    JS
    expect(page).to have_css("[data-testid='crop-box'][data-reactive-dragging]")
    page.driver.with_playwright_page do
      x, y = center("crop-box", off_centre("crop-box"))
      it.mouse.move(x + 40, y, steps: 4)
      it.mouse.up
    end
    expect_saved(1, "crop 0.3 0.1 0.5 0.4")
  end

  it "moves the focal point inside the box, its fields fractions of the box" do
    # The box is 200 × 80 px: 40 px right is 0.2 of it, 8 px down 0.1.
    mouse_drag("crop-point", 40, 8)
    expect_saved(1, "focus 0.7 0.6")
    expect(values("focus")).to eq("x" => 0.7, "y" => 0.6)
  end

  it "works on a client-only root: the fields follow, nothing is sent" do
    mouse_drag("client-box", 100, 50)
    expect(page).to have_field("area[x]", with: "0.25")
    expect(page).to have_field("area[y]", with: "0.25")
  end

  it "fetches the drag module on a page with a frame, and only there", :split_client do
    fetched = lambda {
      page.evaluate_script(<<~JS)
        performance.getEntriesByType("resource").filter((e) => e.name.includes("/features/drag.js")).length
      JS
    }
    expect(fetched.call).to eq(1)
    visit "/counter"
    expect(page).to have_css("[data-testid='count']")
    expect(fetched.call).to eq(0)
  end
end
