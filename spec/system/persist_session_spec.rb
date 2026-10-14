# frozen_string_literal: true

require "system_helper"

# Issue #397: reactive_persist(storage: :session) keeps the draft in
# sessionStorage under the same key. The same tab restores it on reload,
# another tab (a fresh page in the same browser context: it shares
# localStorage, not sessionStorage) does not, a successful submit removes
# the entry, and the localStorage key is never written. A localStorage draft
# under the same key is never restored by the session root.
RSpec.describe "Session-scoped drafts (issue #397 — reactive_persist storage: :session)", type: :system do
  def storage_key = "phlex-reactive:persist:dummy-apply"
  def session_page = "/persist_form?storage=session"

  # The Playwright driver hands a JSON string back already decoded (and a
  # null as {}), so read through a sentinel and accept either shape.
  def draft_in(store)
    raw = page.evaluate_script(
      "(() => { const r = window.#{store}.getItem(#{storage_key.to_json}); return r === null ? '__none__' : r })()"
    )
    return nil if raw == "__none__"

    raw.is_a?(String) ? JSON.parse(raw) : raw
  end

  def wait_for(store)
    deadline = Time.now + Capybara.default_max_wait_time
    loop do
      current = draft_in(store)
      return current if current && yield(current)
      raise "#{store} draft never matched: #{current.inspect}" if Time.now > deadline

      sleep 0.05
    end
  end

  def clear_storage = page.execute_script("window.localStorage.clear(); window.sessionStorage.clear()")

  before do
    visit session_page
    clear_storage
    visit session_page
  end

  it "restores on reload in the same tab, not in another tab, and forgets on submit" do
    fill_in "apply[name]", with: "Ada"
    fill_in "apply[secret]", with: "hunter2"
    saved = wait_for("sessionStorage") { it["fields"]["apply[name]"] == "Ada" }
    expect(saved["fields"].keys).not_to include("fuckery", "apply[tz]", "apply[secret]")
    expect(draft_in("localStorage")).to be_nil

    # Same tab: the reload restores the draft.
    visit session_page
    expect(page).to have_field("apply[name]", with: "Ada")
    expect(page).to have_field("apply[secret]", with: "")

    # Another tab: its sessionStorage is its own, so nothing comes back.
    other = open_new_window
    within_window(other) do
      visit session_page
      expect(page).to have_css("#persist-form")
      expect(page).to have_field("apply[name]", with: "")
      expect(draft_in("sessionStorage")).to be_nil
    end
    other.close

    # A successful Turbo submit removes the sessionStorage entry.
    find("[data-testid='submit']").click
    expect(page).to have_current_path(/submitted=1/)
    expect(draft_in("sessionStorage")).to be_nil
    expect(draft_in("localStorage")).to be_nil
  end

  it "never restores a localStorage draft under the same key" do
    visit "/persist_form"
    fill_in "apply[name]", with: "Local"
    wait_for("localStorage") { it["fields"]["apply[name]"] == "Local" }

    visit session_page
    expect(page).to have_css("#persist-form")
    expect(page).to have_field("apply[name]", with: "")
    expect(draft_in("sessionStorage")).to be_nil
  end
end
