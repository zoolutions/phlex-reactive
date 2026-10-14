# frozen_string_literal: true

require "system_helper"

# Issue #400: reactive_countdown in a real browser. The client counts the
# server's deadline down from Date.now, and at zero shows 0:00, marks the
# state done, swaps the waiting node for the done node and fires
# reactive:countdown-done once. A morph that keeps the deadline (refresh)
# repaints the done state without a second event; one that moves it (restart)
# counts down again. Untagged, so it runs on both entries; `rake
# spec:system_split` lists it because the countdown is a feature module.
RSpec.describe "Countdown (issue #400)", type: :system do
  def clock(state = nil)
    state ? "[data-testid='clock'][data-reactive-countdown-state='#{state}']" : "[data-testid='clock']"
  end

  def visit_countdown(seconds)
    visit "/countdown?seconds=#{seconds}"
    find("#countdown[data-reactive-connected]")
    page.execute_script(<<~JS)
      window.__done = 0
      document.addEventListener("reactive:countdown-done", () => window.__done++)
    JS
  end

  it "counts a 90-second deadline down from the client clock" do
    visit_countdown(90)
    expect(page).to have_css(clock("running"), text: /\A1:[23]\d\z/)
    first = find(clock).text
    expect(page).to have_no_css(clock, exact_text: first, wait: 3)
    expect(page).to have_css("[data-testid='wait']")
    expect(page).to have_no_css("[data-testid='done']")
  end

  it "finishes at zero once, keeps it through a morph, and restarts on a new deadline" do
    visit_countdown(3)
    expect(page).to have_css(clock("done"), exact_text: "0:00", wait: 6)
    expect(page).to have_css("[data-testid='done']", text: "Finished")
    expect(page).to have_no_css("[data-testid='wait']")
    expect(page.evaluate_script("window.__done")).to eq(1)

    find("[data-testid='refresh']").click
    expect(page).to have_css("[data-testid='refreshes']", text: "Refreshed 1")
    expect(page).to have_css(clock("done"), exact_text: "0:00")
    expect(page).to have_css("[data-testid='done']")
    expect(page.evaluate_script("window.__done")).to eq(1)

    find("[data-testid='restart']").click
    expect(page).to have_css(clock("running"))
    expect(page).to have_css("[data-testid='wait']")
    expect(page).to have_css(clock("done"), exact_text: "0:00", wait: 6)
    expect(page.evaluate_script("window.__done")).to eq(2)
  end

  it "finishes a deadline already past on connect" do
    visit "/countdown?seconds=-5"
    expect(page).to have_css(clock("done"), exact_text: "0:00")
    expect(page).to have_css("[data-testid='done']")
    expect(page).to have_no_css("[data-testid='wait']")
  end
end
