# frozen_string_literal: true

require "system_helper"

# Issue #392: reactive_image_fallback(wrap:) hides the box around a logo whose
# src 404s (a real 404 from the dummy's public dir), and shows it again when a
# later src loads. A box the author hid stays hidden through the recovery, and
# the box that holds the img never has its text rewritten.
RSpec.describe "Image fallback wrapper (issue #392)", type: :system do
  before do
    visit "/image_fallback"
    find("#image-fallback[data-reactive-connected]")
  end

  def css(testid, extra = "") = "[data-testid='#{testid}']#{extra}"

  it "hides the wrapper of a broken img and marks the img, leaving the img itself unhidden (hide: false)" do
    expect(page).to have_css(css("badge", "[hidden][data-reactive-wrap-hidden]"), visible: :all)
    expect(page).to have_css(css("badge-logo", "[data-reactive-image-state='error']:not([hidden])"), visible: :all)
    expect(page).to have_css(css("badge", " > img#badge-logo"), visible: :all)
  end

  it "shows the wrapper again when a later src loads, and clears the state" do
    expect(page).to have_css(css("badge", "[hidden]"), visible: :all)

    find(css("fix-badges")).click

    expect(page).to have_css(css("badge", ":not([hidden]):not([data-reactive-wrap-hidden])"))
    expect(page).to have_css(css("badge-logo", "[data-reactive-image-state='loaded']"))
  end

  it "never un-hides a wrapper the author hid" do
    expect(page).to have_css(css("kept-logo", "[data-reactive-image-state='error']"), visible: :all)

    find(css("fix-badges")).click

    expect(page).to have_css(css("kept-logo", "[data-reactive-image-state='loaded']"), visible: :all)
    expect(page).to have_css(css("kept-badge", "[hidden]:not([data-reactive-wrap-hidden])"), visible: :all)
  end
end
