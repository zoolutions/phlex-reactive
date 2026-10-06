# frozen_string_literal: true

require "system_helper"

RSpec.describe "Counter (state-backed reactive component)", type: :system do
  it "increments, decrements, and resets without a full page reload" do
    visit "/counter"
    expect(page).to have_css("[data-testid='count']", text: "0")

    # Marker proves no full-page navigation happened during interactions.
    page.execute_script("window.__noReload = 'alive'")

    # Assert the count after each click so Capybara waits for the morph to land
    # before re-finding the (re-rendered) button.
    find("[data-testid='inc']").click
    expect(page).to have_css("[data-testid='count']", text: "1")

    find("[data-testid='inc']").click
    expect(page).to have_css("[data-testid='count']", text: "2")

    find("[data-testid='inc']").click
    expect(page).to have_css("[data-testid='count']", text: "3")

    find("[data-testid='dec']").click
    expect(page).to have_css("[data-testid='count']", text: "2")

    # reset is a Response.replace(self).flash(...) — count resets in place AND a
    # flash is appended into #flash, all without a reload.
    find("[data-testid='reset']").click
    expect(page).to have_css("[data-testid='count']", text: "0")
    expect(page).to have_css("#flash", text: "Reset")

    expect(page.evaluate_script("window.__noReload")).to eq("alive")
  end

  it "accumulates rapid clicks correctly (no in-flight token race)" do
    visit "/counter"
    expect(page).to have_css("[data-testid='count']", text: "0")

    # Fire five increments as fast as possible.
    page.execute_script(<<~JS)
      const btn = document.querySelector("[data-testid='inc']")
      for (let i = 0; i < 5; i++) btn.click()
    JS

    expect(page).to have_css("[data-testid='count']", text: "5")
  end

  it "bump_via_update morphs inner HTML in place (update-style Response)" do
    visit "/counter"
    expect(page).to have_css("[data-testid='count']", text: "0")
    page.execute_script("window.__noReload = 'alive'")

    # Tag the reactive root and keep a handle to it. An update morphs the root's
    # children, so this exact node survives; a replace would swap the root out,
    # disconnecting this reference — that's how we distinguish update from replace.
    page.execute_script(<<~JS)
      const root = document.querySelector("[data-reactive-token-value]")
      root.dataset.marker = "kept"
      window.__reactiveRoot = root
    JS

    # bump_via_update returns Response.update(self) — an inner-HTML morph (not a
    # replace). The count still updates in place and the token still refreshes.
    find("[data-testid='bump-update']").click
    expect(page).to have_css("[data-testid='count']", text: "1")
    # The SAME root node is still connected (a replace would have swapped it).
    expect(page.evaluate_script("window.__reactiveRoot.isConnected")).to be(true)
    expect(page.evaluate_script("window.__reactiveRoot.dataset.marker")).to eq("kept")

    # A second click proves the token refreshed (a stale token would 400 and the
    # count would stay at 1).
    find("[data-testid='bump-update']").click
    expect(page).to have_css("[data-testid='count']", text: "2")

    expect(page.evaluate_script("window.__noReload")).to eq("alive")
  end

  # Issue #301: a morph from OUTSIDE the controller's reply (a broadcast, a page
  # refresh) keeps the root and its controller, so the token it brings must win
  # over the one the controller cached from its own last (update) reply.
  it "signs the next action with the token an outside morph brought" do
    visit "/counter"
    find("[data-testid='bump-update']").click
    expect(page).to have_css("[data-testid='count']", text: "1")
    page.execute_script("window.__counterRoot = document.getElementById('counter')")

    page.execute_script(<<~JS)
      fetch("/counter?count=5").then((r) => r.text()).then((html) => {
        const el = new DOMParser().parseFromString(html, "text/html").getElementById("counter")
        window.Turbo.renderStreamMessage(
          '<turbo-stream action="replace" method="morph" target="counter"><template>' +
            el.outerHTML + "</template></turbo-stream>"
        )
      })
    JS
    expect(page).to have_css("[data-testid='count']", text: "5")
    # Morphed in place: the same root (and its controller) is still connected.
    expect(page.evaluate_script("window.__counterRoot.isConnected")).to be(true)

    find("[data-testid='inc']").click
    expect(page).to have_css("[data-testid='count']", exact_text: "6")
  end

  it "Response.redirect drives a Turbo.visit to the new URL" do
    visit "/counter"
    expect(page).to have_css("[data-testid='go-home']")

    find("[data-testid='go-home']").click

    # The reactive:visit custom stream action navigates the browser. Capybara
    # waits for the new page (the todos demo) to load.
    expect(page).to have_current_path("/todos")
    expect(page).to have_css("[data-testid='new-todo']")
  end
end
