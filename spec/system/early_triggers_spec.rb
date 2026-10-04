# frozen_string_literal: true

require "system_helper"

# Issue #273: triggers that fire BEFORE a lazily loaded reactive controller
# connects are captured by phlex/reactive/early and replayed on connect. The
# /early_triggers page uses its own layout: early.js is imported eagerly, the
# controller only when the spec calls window.__loadReactive() (a setTimeout-
# delayed import(), the stand-in for stimulus-loading's lazy load). A fetch spy
# installed before anything loads counts the action POSTs.
RSpec.describe "Early triggers (issue #273 — capture before connect, replay on connect)", type: :system do
  def open_panel
    page.execute_script(%(document.getElementById("early-triggers").dispatchEvent(new CustomEvent("panel:opened"))))
  end

  def action_posts = page.evaluate_script("window.__actionPosts")

  # The page with early.js running and NO reactive controller yet.
  def visit_unconnected
    visit "/early_triggers"
    expect(page).to have_css("#early-triggers")
    expect(page.evaluate_script("window.__earlyReady === true")).to be(true)
    expect(page).to have_css("[data-testid='connects']", exact_text: "0")
  end

  # Waits on the page's reactive:connect counter, not on
  # data-reactive-connected: a morph reply strips that attribute again.
  def load_controller
    page.execute_script("window.__loadReactive()")
    expect(page).to have_css("[data-testid='connects']", text: /\A[1-9]/)
  end

  it "replays a click and a custom event fired before connect, one request each" do
    visit_unconnected
    find("[data-testid='bump']").click
    # A :once custom-event trigger fired three times before connect.
    3.times { open_panel }
    expect(action_posts).to eq(0)

    load_controller

    expect(page).to have_css("[data-testid='clicks']", text: "1")
    expect(page).to have_css("[data-testid='loads']", text: "1")
    # Settled, and nothing more in flight: exactly one request per trigger.
    sleep 0.3
    expect(action_posts).to eq(2)
  end

  it "keeps a replayed :once trigger spent when its reply morphs the root in place" do
    visit_unconnected
    open_panel
    load_controller

    expect(page).to have_css("[data-testid='loads']", text: "1")
    # The morph kept the root element, and with it Stimulus's own still-armed
    # `once` listener: its one firing must not send a second request.
    2.times { open_panel }
    sleep 0.3
    expect(action_posts).to eq(1)
    expect(page).to have_css("[data-testid='loads']", text: "1")
  end

  it "prevents the native default of a link trigger clicked before connect" do
    visit_unconnected
    page.execute_script("window.__noReload = 'alive'")
    find("[data-testid='link']").click
    load_controller

    expect(page).to have_css("[data-testid='clicks']", text: "1")
    expect(page).to have_current_path("/early_triggers")
    expect(page.evaluate_script("window.__noReload")).to eq("alive")
    expect(action_posts).to eq(1)
  end

  it "behaves as before once connected: one request per click, no replay" do
    visit_unconnected
    load_controller

    find("[data-testid='bump']").click
    expect(page).to have_css("[data-testid='clicks']", text: "1")
    find("[data-testid='bump']").click
    expect(page).to have_css("[data-testid='clicks']", text: "2")
    sleep 0.3
    expect(action_posts).to eq(2)
  end
end
