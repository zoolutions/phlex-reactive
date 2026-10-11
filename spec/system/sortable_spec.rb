# frozen_string_literal: true

require "system_helper"

# Issue #350: sortable lists in a real browser — a mouse drag reorders and the
# server's reply agrees, a touch drag (real touch input through Chromium's
# DevTools protocol) does the same, a row dragged in from a source list is
# inserted by the target's action, the keyboard model, and a failing action
# putting the row back. Rows are 40 px tall (SortablePageComponent).
RSpec.describe "Sortable lists (issue #350)", type: :system do
  def order(id = "sortable")
    page.evaluate_script(<<~JS)
      [...document.querySelectorAll("[data-testid='#{id}-list'] [data-reactive-sortable-item]")].map((el) => JSON.parse(el.dataset.reactiveSortableItem))
    JS
  end

  def center(testid)
    page.evaluate_script(<<~JS)
      (() => { const r = document.querySelector("[data-testid='#{testid}']").getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2] })()
    JS
  end

  # A real mouse drag: press on `from`, move in steps to `nudge` px below/above
  # `to`'s middle, release.
  def mouse_drag(from, to, nudge: 0)
    x0, y0 = center(from)
    x1, y1 = center(to)
    page.driver.with_playwright_page do
      it.mouse.move(x0, y0)
      it.mouse.down
      it.mouse.move(x0, y0 + 8, steps: 2)
      it.mouse.move(x1, y1 + nudge, steps: 8)
      it.mouse.up
    end
  end

  # A real touch drag: Chromium's Input.dispatchTouchEvent, held past the
  # 200 ms press before it moves.
  def touch_drag(from, to, nudge: 0)
    x0, y0 = center(from)
    x1, y1 = center(to)
    page.driver.with_playwright_page do
      cdp = it.context.new_cdp_session(it)
      cdp.send_message("Emulation.setTouchEmulationEnabled", params: { enabled: true, maxTouchPoints: 1 })
      touch = lambda { |type, left, top|
        points = type == "touchEnd" ? [] : [{ x: left, y: top }]
        cdp.send_message("Input.dispatchTouchEvent", params: { type:, touchPoints: points })
      }
      touch.call("touchStart", x0, y0)
      sleep 0.3
      8.times { touch.call("touchMove", x0 + ((x1 - x0) * (it + 1) / 8.0), y0 + ((y1 + nudge - y0) * (it + 1) / 8.0)) }
      touch.call("touchEnd", x1, y1 + nudge)
    end
  end

  # Every root's features have connected (on the split client the sortable
  # module is imported at connect, after the server HTML is already there).
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

  before do
    visit "/sortable"
    page.assert_selector("[data-testid='sortable-list'][data-reactive-sortable]")
    wait_for_features
    page.execute_script('window.__noReload = "alive"')
  end

  it "reorders with a mouse drag: the action gets item/position/after/from and the reply keeps the order" do
    mouse_drag("sortable-alpha", "sortable-charlie", nudge: 10) # past charlie's middle
    expect(page).to have_css("[data-testid='sortable-last']", text: "move alpha 2 charlie self")
    expect(order).to eq(%w[bravo charlie alpha delta])
    expect(page).to have_no_css("[data-reactive-sortable-placeholder], [data-reactive-sortable-dragging]")
    expect(page.evaluate_script("window.__noReload")).to eq("alive")
  end

  it "reorders with a touch drag (a press, then a move)" do
    touch_drag("sortable-delta", "sortable-alpha", nudge: -10)
    expect(page).to have_css("[data-testid='sortable-last']", text: "move delta 0 - self")
    expect(order).to eq(%w[delta alpha bravo charlie])
  end

  it "copies a source row in: the target's from: action inserts it, the source keeps its row" do
    # (The placeholder opens a row's height of room above the pointer as the
    # clone enters the list, pushing the rows down: aim below charlie's
    # original middle to land after bravo.)
    mouse_drag("template-bug", "sortable-charlie", nudge: 10)
    expect(page).to have_css("[data-testid='sortable-last']", text: "insert bug 2 bravo templates")
    expect(order).to eq(%w[alpha bravo bug-5 charlie delta])
    expect(page).to have_css("[data-testid='template-bug']")
  end

  it "moves a row with the keyboard and announces each step" do
    find("[data-testid='sortable-bravo']").send_keys(:space)
    expect(page).to have_css("[data-reactive-sortable-live]", text: "Picked up item 2 of 4", visible: :all)
    find("[data-testid='sortable-bravo']").send_keys(:down, :down)
    expect(page).to have_css("[data-reactive-sortable-live]", text: "Moved to position 4 of 4", visible: :all)
    find("[data-testid='sortable-bravo']").send_keys(:enter)
    expect(page).to have_css("[data-testid='sortable-last']", text: "move bravo 3 delta self")
    expect(order).to eq(%w[alpha charlie delta bravo])
  end

  it "puts the row back when the action fails" do
    mouse_drag("sortable-fail-alpha", "sortable-fail-charlie", nudge: 10)
    expect(page).to have_css("[data-testid='sortable-fail'][data-reactive-error]")
    expect(order("sortable-fail")).to eq(%w[alpha bravo charlie delta])
  end

  it "fetches the sortable module on a page with a sortable, and only there", :split_client do
    fetched = lambda {
      page.evaluate_script(<<~JS)
        performance.getEntriesByType("resource").filter((e) => e.name.includes("/features/sortable.js")).length
      JS
    }
    expect(fetched.call).to eq(1)
    visit "/counter"
    expect(page).to have_css("[data-testid='count']")
    expect(fetched.call).to eq(0)
  end
end
