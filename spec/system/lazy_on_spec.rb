# frozen_string_literal: true

require "system_helper"

# reactive_lazy(on:) in a real browser (issue #276): the shell makes NO
# request on page load. An event-triggered shell materializes exactly once
# when its event reaches it (a later event finds the real render, which has no
# trigger); a :visible shell below the fold materializes only after scrolling.
RSpec.describe "reactive_lazy(on:) (issue #276)", type: :system do
  def install_reactive_fetch_spy
    page.execute_script(<<~JS)
      window.__reactiveFetches = 0
      const original = window.fetch
      window.fetch = (input, ...rest) => {
        const url = typeof input === "string" ? input : input.url
        if (url.includes("/reactive/")) window.__reactiveFetches += 1
        return original(input, ...rest)
      }
    JS
  end

  def reactive_fetches = page.evaluate_script("window.__reactiveFetches")

  # Resource Timing covers the page load itself (the spy installs after
  # connect). Valid here because every example starts with a full visit.
  def reactive_resources_on_load
    page.evaluate_script(<<~JS)
      performance.getEntriesByType("resource").filter((e) => e.name.includes("/reactive/")).length
    JS
  end

  def fire_panel_opened
    page.execute_script(%(document.getElementById("lazy-panel").dispatchEvent(new CustomEvent("panel:opened"))))
  end

  it "an event shell requests nothing until the event, then exactly once" do
    visit "/lazy_on"
    install_reactive_fetch_spy
    page.execute_script("window.__noReload = 'alive'")

    expect(page).to have_css("[data-testid='panel-skeleton']")
    # Give a (wrongly) connect-time fetch every chance to happen.
    sleep 0.3
    expect(reactive_resources_on_load).to eq(0)
    expect(reactive_fetches).to eq(0)
    expect(page).to have_css("[data-testid='panel-skeleton']")

    fire_panel_opened
    expect(page).to have_css("[data-testid='panel-item']", text: "item:mine")
    expect(page).to have_no_css("[data-testid='panel-skeleton']")
    expect(reactive_fetches).to eq(1)

    # The real render carries no trigger: a second event is a no-op.
    fire_panel_opened
    sleep 0.3
    expect(reactive_fetches).to eq(1)
    expect(page.evaluate_script("window.__noReload")).to eq("alive")

    # …and it arrived as a live reactive root with a fresh token.
    token = page.evaluate_script(%(document.getElementById("lazy-panel").getAttribute("data-reactive-token-value")))
    expect(token.to_s.length).to be > 20
  end

  it "a bubbling event from inside the shell counts" do
    visit "/lazy_on"
    install_reactive_fetch_spy

    page.execute_script(<<~JS)
      document.querySelector("[data-testid='panel-skeleton']")
        .dispatchEvent(new CustomEvent("panel:opened", { bubbles: true }))
    JS
    expect(page).to have_css("[data-testid='panel-item']", text: "item:mine")
    expect(reactive_fetches).to eq(1)
  end

  it "a :visible shell below the fold requests only after it scrolls into view" do
    visit "/lazy_on"
    install_reactive_fetch_spy

    expect(page).to have_css("[data-testid='fold-skeleton']", visible: :all)
    sleep 0.3
    expect(reactive_resources_on_load).to eq(0)
    expect(reactive_fetches).to eq(0)

    page.execute_script(%(document.getElementById("lazy-fold").scrollIntoView()))
    expect(page).to have_css("[data-testid='fold-value']", text: "loaded:below")
    expect(reactive_fetches).to eq(1)

    page.execute_script("window.scrollTo(0, 0)")
    page.execute_script(%(document.getElementById("lazy-fold").scrollIntoView()))
    sleep 0.3
    expect(reactive_fetches).to eq(1)
  end
end
