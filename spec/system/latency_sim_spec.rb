# frozen_string_literal: true

require "system_helper"

# Latency simulator dev aid end-to-end (issue #102). On localhost the click→morph
# round trip is ~5ms, so aria-busy (and the loading/optimistic affordances) flash
# by unobservably — the reason LiveView ships enableLatencySim(ms). This spec
# enables the simulator from the page (the dev-gated window.PhlexReactive handle),
# then observes aria-busy DURING the injected delay — finally covering aria-busy in
# a real browser. Runs under Puma AND Falcon (the round trip must behave the same
# sync and async).
RSpec.describe "Latency simulator (issue #102)", type: :system do
  # typeof window.PhlexReactive — once the client has attached it. The default
  # client does so while its module evaluates; the split client (issue #275)
  # imports the dev feature module first, so wait for it.
  def latency_handle
    Timeout.timeout(5) { sleep 0.05 until page.evaluate_script("typeof window.PhlexReactive") == "object" }
    "object"
  rescue Timeout::Error
    page.evaluate_script("typeof window.PhlexReactive")
  end

  it "makes aria-busy visible during the injected delay, then clears on the morph" do
    visit "/latency"
    expect(page).to have_css("[data-testid='bump']")

    # The dev gate: the page carries <meta name="phlex-reactive-env" content=
    # "development">, so the client attached the global handle.
    expect(latency_handle).to eq("object")

    # Enable a generous delay so the busy window is reliably observable under both
    # servers (Capybara's waiting matcher polls within the window).
    page.execute_script("window.PhlexReactive.enableLatencySim(1500)")

    page.execute_script('window.__noReload = "alive"')
    find("[data-testid='bump']").click

    # DURING the injected delay the root carries aria-busy="true" — the whole point
    # of the aid: an affordance that would be invisible on a ~5ms localhost trip is
    # now observable. (aria-busy is applied at enqueue; the sim awaits before the
    # fetch, so the window is stretched to 1.5s.)
    expect(page).to have_css("#latency[aria-busy='true']")

    # After the delay elapses and the morph lands, the action applied (count → 1)
    # and aria-busy cleared — no full-page reload.
    expect(page).to have_css("[data-testid='count']", text: "1", wait: 8)
    expect(page).to have_no_css("#latency[aria-busy='true']")
    expect(page.evaluate_script("window.__noReload")).to eq("alive")
  end

  it "disableLatencySim removes the delay (aria-busy no longer lingers)" do
    visit "/latency"
    expect(page).to have_css("[data-testid='bump']")
    expect(latency_handle).to eq("object")

    page.execute_script("window.PhlexReactive.enableLatencySim(1500)")
    page.execute_script("window.PhlexReactive.disableLatencySim()")

    # With the sim disabled the fast action round-trips immediately: the count
    # updates and aria-busy is never stuck on (it clears on the near-instant morph).
    find("[data-testid='bump']").click
    expect(page).to have_css("[data-testid='count']", text: "1", wait: 8)
    expect(page).to have_no_css("#latency[aria-busy='true']")
  end
end
