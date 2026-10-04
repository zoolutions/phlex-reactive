# frozen_string_literal: true

require "system_helper"

# Issues #274 + #276 + #277 together: a DORMANT reactive_lazy(on:, cache:)
# shell on a page that loads the controller lazily. Nothing reactive is fetched
# on page load; `panel:opened` wakes the root and GETs the cacheable fragment
# once; the next page view's first open is answered by the browser cache; and
# another viewer of the same browser gets their own render.
RSpec.describe "A dormant reactive_lazy(on:, cache:) shell (issues #274/#276/#277)", type: :system do
  def fragment_fetches
    page.evaluate_script(<<~JS)
      performance.getEntriesByType("resource")
        .filter((e) => e.name.includes("/reactive/fragment/"))
        .map((e) => e.transferSize)
    JS
  end

  def controller_fetches
    page.evaluate_script(<<~JS)
      performance.getEntriesByType("resource").filter((e) => e.name.includes("reactive_controller")).length
    JS
  end

  def view_as(viewer)
    visit "/cached_panel"
    page.execute_script("document.cookie = 'viewer=#{viewer}; path=/'")
  end

  def visit_panel(load)
    visit "/dormant_cached?load=#{load}"
    expect(page).to have_css("#dormant-cached-panel[data-reactive-dormant='reactive']")
    expect(page.evaluate_script("window.__earlyReady === true")).to be(true)
    page.execute_script(<<~JS)
      window.__beforeDispatch = []
      document.addEventListener("reactive:before-dispatch", (e) => window.__beforeDispatch.push(e.detail.action))
    JS
  end

  def open_panel
    page.execute_script(
      %(document.getElementById("dormant-cached-panel").dispatchEvent(new CustomEvent("panel:opened")))
    )
  end

  def before_dispatches = page.evaluate_script("window.__beforeDispatch")

  before do
    DormantCachedPanelComponent::RENDERS.value = 0
    view_as("alice")
  end

  # "auto" loads the controller when an element first lists it (the
  # lazyLoadControllersFrom stand-in); "eager" registers it up front.
  %w[auto eager].each_with_index do |load, _index|
    context "with the controller registered #{load}" do
      it "requests nothing until the event, then one GET; the next page view is a cache hit" do
        visit_panel(load)
        sleep 0.3 # give a wrongly eager fetch every chance to show up
        expect(fragment_fetches).to be_empty
        expect(controller_fetches).to eq(0) if load == "auto"

        2.times { open_panel }
        expect(page).to have_css("[data-testid='dormant-cached-item']", text: "panel:mine:alice")
        open_panel
        wait_for_reactive

        expect(page).to have_css("#dormant-cached-panel[data-controller~='reactive']")
        expect(page).to have_no_css("[data-reactive-dormant]")
        expect(fragment_fetches.size).to eq(1)
        expect(fragment_fetches.first).to be > 0
        expect(before_dispatches).to eq(["__materialize"])
        expect(page.evaluate_script("window.__actionPosts")).to eq(0)
        expect(DormantCachedPanelComponent::RENDERS.value).to eq(1)

        visit_panel(load)
        open_panel
        expect(page).to have_css("[data-testid='dormant-cached-item']", text: "panel:mine:alice")

        expect(fragment_fetches).to eq([0])
        expect(before_dispatches).to eq(["__materialize"])
        expect(DormantCachedPanelComponent::RENDERS.value).to eq(1)
      end

      it "gives another viewer of the same browser their own render" do
        visit_panel(load)
        open_panel
        expect(page).to have_css("[data-testid='dormant-cached-item']", text: "panel:mine:alice")

        view_as("bob")
        visit_panel(load)
        open_panel

        expect(page).to have_css("[data-testid='dormant-cached-item']", text: "panel:mine:bob")
        expect(page).to have_no_text("alice")
        expect(fragment_fetches.first).to be > 0
      end
    end
  end
end
