# frozen_string_literal: true

require "system_helper"

# Issue #380: reactive_media is PENDING until the field has `take` characters
# (or while match: rejects the key) — blank_label only names a full-length key
# that misses the pool. The preview carries data-reactive-media-state, and the
# bank row hides itself on it with plain CSS. Untagged, so it runs on both
# entries; `rake spec:system_split` lists it because the binding lives in the
# bindings feature module.
RSpec.describe "Media binding pending state (issue #380)", type: :system do
  def type_rib(value)
    find("[data-testid='rib']").fill_in(with: value)
  end

  # The label's text even while its row is hidden.
  def caption = page.evaluate_script("document.querySelector('[data-testid=bank-name]').textContent")

  def preview(state) = "[data-testid='preview'][data-reactive-media-state='#{state}']"

  before do
    visit "/rib_preview"
    find("#rib-preview[data-reactive-connected]")
  end

  it "stays pending (no blank_label, row hidden) below take characters" do
    expect(page).to have_css(preview("pending"), visible: :all)
    expect(page).to have_no_css("[data-testid='bank-row']")
    expect(caption).to eq("")

    # From a miss, so each pending state below is a real transition.
    ["0", "00", ""].each do
      type_rib("009")
      expect(page).to have_css(preview("miss"))
      type_rib(it)
      expect(page).to have_css(preview("pending"), visible: :all)
      expect(page).to have_no_css("[data-testid='bank-row']")
      expect(caption).to eq("")
    end
  end

  it "a full-length key that misses writes blank_label; one in the pool copies its image" do
    type_rib("009")
    expect(page).to have_css(preview("miss"))
    expect(page).to have_css("[data-testid='bank-name']", exact_text: "Unknown bank")

    type_rib("007")
    expect(page).to have_css("#{preview("hit")}[src='/logos/007.svg'][alt='Attijariwafa']")
    expect(page).to have_css("[data-testid='bank-name']", exact_text: "Attijariwafa")

    type_rib("00")
    expect(page).to have_css("#{preview("pending")}:not([src])", visible: :all)
    expect(page).to have_no_css("[data-testid='bank-row']")
  end

  it "with match:, a non-digit key is pending, not a miss" do
    type_rib("009")
    expect(page).to have_css(preview("miss"))
    type_rib("ab1")
    expect(page).to have_css(preview("pending"), visible: :all)
    expect(caption).to eq("")
  end

  # Issue #390: when: tests the whole RIB; the pool key stays the prefix.
  def whole(state) = "[data-testid='whole'][data-reactive-media-state='#{state}']"

  it "with when:, a pool prefix whose whole value fails is pending; a passing one hits, or misses with blank_label" do
    type_rib("007bad")
    expect(page).to have_css("#{whole("pending")}:not([src])", visible: :all)
    expect(page).to have_no_css("[data-testid='whole-row']")
    # match: tests the key only, so the first binding still hits on the prefix.
    expect(page).to have_css(preview("hit"))

    type_rib("007123")
    expect(page).to have_css("#{whole("hit")}[src='/logos/007.svg'][alt='Attijariwafa']")
    expect(page).to have_css("[data-testid='whole-name']", exact_text: "Attijariwafa")

    type_rib("009123")
    expect(page).to have_css(whole("miss"))
    expect(page).to have_css("[data-testid='whole-name']", exact_text: "Unknown bank")
  end

  it "pending: :keep leaves the preview and its label alone" do
    expect(page).to have_css("[data-testid='kept'][data-reactive-media-state='pending'][src='/logos/011.svg']")
    expect(page).to have_css("[data-testid='kept-name']", exact_text: "Previous")

    type_rib("007")
    expect(page).to have_css("[data-testid='kept'][data-reactive-media-state='hit'][src='/logos/007.svg']")

    type_rib("0")
    expect(page).to have_css("[data-testid='kept'][data-reactive-media-state='pending'][src='/logos/007.svg']")
    expect(page).to have_css("[data-testid='kept-name']", exact_text: "Attijariwafa")
  end
end
