# frozen_string_literal: true

require "system_helper"

# Issue #273: triggers that fire BEFORE a lazily loaded reactive controller
# connects are captured by phlex/reactive/early and replayed on connect. The
# /early_triggers page uses its own layout: early.js is imported eagerly, the
# controller only after a 1.5 s setTimeout + import() (the stand-in for
# stimulus-loading's lazy load). A fetch spy installed before anything loads
# counts the action POSTs.
RSpec.describe "Early triggers (issue #273 — capture before connect, replay on connect)", type: :system do
  def action_posts = page.evaluate_script("window.__actionPosts")

  it "replays a click and a custom event fired before connect, one request each" do
    visit "/early_triggers"
    expect(find_by_id("early-triggers")[:"data-reactive-connected"]).to be_nil

    find("[data-testid='bump']").click
    # A :once custom-event trigger fired three times before connect.
    open_panel = %(document.getElementById("early-triggers").dispatchEvent(new CustomEvent("panel:opened")))
    3.times { page.execute_script(open_panel) }

    expect(page).to have_css("#early-triggers[data-reactive-connected]", wait: 10)
    expect(page).to have_css("[data-testid='clicks']", text: "1")
    expect(page).to have_css("[data-testid='loads']", text: "1")
    expect(page).to have_css("[data-testid='connects']", text: /\A[1-9]/)
    # Settled, and nothing more in flight: exactly one request per trigger.
    sleep 0.3
    expect(action_posts).to eq(2)
  end

  it "prevents the native default of a link trigger clicked before connect" do
    visit "/early_triggers"
    page.execute_script("window.__noReload = 'alive'")

    find("[data-testid='link']").click

    expect(page).to have_css("[data-testid='clicks']", text: "1", wait: 10)
    expect(page).to have_current_path("/early_triggers")
    expect(page.evaluate_script("window.__noReload")).to eq("alive")
    expect(action_posts).to eq(1)
  end

  it "behaves as before once connected: one request per click, no replay" do
    visit "/early_triggers"
    expect(page).to have_css("#early-triggers[data-reactive-connected]", wait: 10)

    find("[data-testid='bump']").click
    expect(page).to have_css("[data-testid='clicks']", text: "1")
    find("[data-testid='bump']").click
    expect(page).to have_css("[data-testid='clicks']", text: "2")
    sleep 0.3
    expect(action_posts).to eq(2)
  end
end
