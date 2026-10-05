# frozen_string_literal: true

require "system_helper"

# Issue #275: the draft code (reactive_persist) is a FEATURE MODULE the client
# imports only on a page that has a draft-keeping root. So the restore no
# longer runs inside connect() — it runs when the module has arrived. These
# examples pin what that must not cost:
#
#   - a page without a draft-keeping root never fetches the module;
#   - an action fired before the restore posts the RESTORED values, exactly
#     once — with the controller registered eagerly, and loaded lazily behind
#     phlex/reactive/early (the trigger is then replayed on connect);
#   - what the user typed before the restore is still there after it.
#
# ?slow=<ms> serves the module after a delay, so the "controller connected,
# restore not yet run" window is wide enough to act in.
RSpec.describe "The persist feature module (issue #275)", type: :system do
  def storage_key = "phlex-reactive:persist:dummy-persist-action"
  # How late the slow copy of the module arrives: the window to act in.
  def slow_ms = 1500

  def feature_fetches
    page.evaluate_script(<<~JS)
      performance.getEntriesByType("resource").filter((e) => e.name.includes("/persist.js")).length
    JS
  end

  # A draft from "an earlier visit": written straight into localStorage.
  def seed_draft(fields)
    visit "/counter"
    page.execute_script(<<~JS)
      window.localStorage.clear()
      window.localStorage.setItem(#{storage_key.to_json}, JSON.stringify({ v: 1, savedAt: Date.now(), fields: #{fields.to_json} }))
    JS
  end

  def draft_fields
    raw = page.evaluate_script("window.localStorage.getItem(#{storage_key.to_json}) ?? '__none__'")
    return nil if raw == "__none__"

    (raw.is_a?(String) ? JSON.parse(raw) : raw).fetch("fields")
  end

  def action_posts = page.evaluate_script("window.__actionPosts")

  after { page.execute_script("window.localStorage.clear()") }

  it "is not fetched by a page without a draft-keeping root" do
    visit "/counter"
    find("[data-testid='inc']").click
    expect(page).to have_css("[data-testid='count']", text: "1")

    expect(feature_fetches).to eq(0)
  end

  it "is fetched once by a page with a draft-keeping root, and restores the draft" do
    seed_draft("note" => "Ada")
    expect(feature_fetches).to eq(0)

    visit "/persist_action"

    expect(page).to have_field("note", with: "Ada")
    expect(feature_fetches).to eq(1)
  end

  context "with the controller registered eagerly" do
    it "posts the restored value, once, for an action fired before the restore" do
      seed_draft("note" => "Ada")
      visit "/persist_action?slow=#{slow_ms}"
      expect(page).to have_css("#persist-action[data-reactive-connected]")
      # The window this example is about: connected, the draft not restored yet.
      expect(find("[data-testid='note']").value).to eq("")

      find("[data-testid='save']").click

      expect(page).to have_css("[data-testid='saved']", text: "got:Ada")
      expect(page).to have_reactive_requests(1, kind: :action)
      # The reply replaced the root; the fresh one restores from the same draft.
      expect(page).to have_field("note", with: "Ada")
    end

    it "keeps what was typed before the restore, and still restores the rest" do
      seed_draft("note" => "Ada")
      visit "/persist_action?slow=#{slow_ms}"
      expect(page).to have_css("#persist-action[data-reactive-connected]")
      expect(find("[data-testid='note']").value).to eq("")

      find("[data-testid='extra']").send_keys("typed early")

      expect(page).to have_field("note", with: "Ada")
      expect(page).to have_field("extra", with: "typed early")
      # What was typed in that window is drafted when the module arrives — with
      # the restored field, never the blank the server rendered for it — and
      # without another keystroke.
      expect(draft_fields).to eq("note" => "Ada", "extra" => "typed early")
    end

    it "drafts what was typed in that window even when the user leaves without typing again" do
      seed_draft("note" => "Ada")
      visit "/persist_action?slow=300"
      find("[data-testid='extra']").send_keys("typed early")
      expect(page).to have_field("note", with: "Ada")

      visit "/counter"
      visit "/persist_action"

      expect(page).to have_field("extra", with: "typed early")
      expect(page).to have_field("note", with: "Ada")
    end

    it "drafts what was typed even when the user leaves BEFORE the module arrives" do
      seed_draft("note" => "Ada")
      visit "/persist_action?slow=#{slow_ms}"
      expect(page).to have_css("#persist-action[data-reactive-connected]")
      find("[data-testid='extra']").send_keys("typed early")
      expect(find("[data-testid='note']").value).to eq("")

      # A Turbo visit: the page (and the import that is still on its way) lives on.
      page.execute_script("Turbo.visit('/counter')")
      expect(page).to have_css("#counter")
      # The module arrives after the root has gone, and is handed what it missed.
      deadline = Time.now + Capybara.default_max_wait_time
      sleep 0.05 until draft_fields == { "note" => "Ada", "extra" => "typed early" } || Time.now > deadline
      expect(draft_fields).to eq("note" => "Ada", "extra" => "typed early")

      visit "/persist_action"
      expect(page).to have_field("extra", with: "typed early")
      expect(page).to have_field("note", with: "Ada")
    end
  end

  context "with the controller loaded lazily behind phlex/reactive/early" do
    it "replays a click made before the controller existed and posts the restored value, once" do
      seed_draft("note" => "Ada")
      visit "/persist_action?layout=lazy&slow=300"
      expect(page.evaluate_script("window.__earlyReady === true")).to be(true)
      expect(page).to have_no_css("#persist-action[data-reactive-connected]")

      find("[data-testid='save']").click
      expect(action_posts).to eq(0)
      page.execute_script("window.__loadReactive()")

      expect(page).to have_css("[data-testid='saved']", text: "got:Ada")
      expect(action_posts).to eq(1)
      expect(page).to have_field("note", with: "Ada")
      expect(feature_fetches).to eq(1)
    end

    it "posts the restored value, once, when the controller is registered up front" do
      seed_draft("note" => "Ada")
      visit "/persist_action?layout=lazy&load=eager&slow=#{slow_ms}"
      expect(page).to have_css("#persist-action[data-reactive-connected]")
      expect(find("[data-testid='note']").value).to eq("")

      find("[data-testid='save']").click

      expect(page).to have_css("[data-testid='saved']", text: "got:Ada")
      expect(action_posts).to eq(1)
    end
  end
end
