# frozen_string_literal: true

require "system_helper"

# Issue #383: reactive_image_fallback marks (and hides) an <img> whose src
# fails, and every later src change lets it try again: reactive_media,
# js.copy_media, js.preview_file and a morph reply. Removing the src is not an
# error. /logos/missing.svg is a real 404 from the dummy's public dir, so the
# browser's own `error` drives these, not a synthetic event. Untagged, so it
# runs on both entries; `rake spec:system_split` lists it because
# reactive_media lives in the bindings feature module.
RSpec.describe "Image fallback (issue #383)", type: :system do
  let(:red) { Rails.root.join("..", "fixtures", "files", "photo_red.png").to_s }

  def img(testid, extra = "") = "[data-testid='#{testid}']#{extra}"
  def broken(testid) = img(testid, "[data-reactive-image-state='error'][hidden]")
  def shown(testid) = img(testid, "[data-reactive-image-state='loaded']:not([hidden])")

  before do
    visit "/image_fallback"
    find("#image-fallback[data-reactive-connected]")
  end

  it "hides a server-rendered img whose src 404s" do
    expect(page).to have_css(broken("server"), visible: :all)
    expect(page).to have_css(broken("photo"), visible: :all)
  end

  it "never hides an SVG that has only a viewBox (it loads; naturalWidth may read 0)" do
    expect(page).to have_css(shown("viewbox"))
    page.refresh
    find("#image-fallback[data-reactive-connected]")
    expect(page).to have_css(shown("viewbox"))
  end

  it "after a restoration visit (back), a broken copy is still shown again by a valid one" do
    find(img("use-broken")).click
    expect(page).to have_css(broken("copied"), visible: :all)

    page.execute_script("Turbo.visit('/logo_preview')")
    expect(page).to have_css("#logo-preview[data-reactive-connected]")
    page.go_back
    find("#image-fallback[data-reactive-connected]")
    expect(page).to have_css(broken("copied"), visible: :all)

    find(img("use-valid")).click
    expect(page).to have_css(shown("copied"))
  end

  it "reactive_media: a key whose image 404s hides the preview, the next key shows it" do
    find(img("rib")).fill_in(with: "001")
    expect(page).to have_css(broken("logo"), visible: :all)

    find(img("rib")).fill_in(with: "007")
    expect(page).to have_css(shown("logo"))
    expect(page).to have_css(img("logo", "[src='/logos/007.svg']"))
  end

  it "js.copy_media: a broken copy shows the alt text, a valid copy shows the image again" do
    find(img("use-broken")).click
    expect(page).to have_css(broken("copied"), visible: :all)
    expect(page).to have_css(img("copied-name"), text: "Broken Bank")

    find(img("use-valid")).click
    expect(page).to have_css(shown("copied"))
    expect(page).to have_css(img("copied-name"), visible: :hidden)
  end

  it "removing the src is not an error: the img is neither marked nor hidden" do
    find(img("use-broken")).click
    expect(page).to have_css(broken("copied"), visible: :all)

    find(img("use-none")).click
    expect(page).to have_css(img("copied", ":not([src]):not([hidden]):not([data-reactive-image-state])"), visible: :all)
    # Let any late event for the emptied request land; nothing marks it.
    expect(page.evaluate_async_script("requestAnimationFrame(() => setTimeout(() => arguments[0](true), 100))")).to be(true)
    expect(page).to have_no_css(img("copied", "[data-reactive-image-state]"), visible: :all)
  end

  it "js.preview_file: choosing an image shows the broken preview again" do
    expect(page).to have_css(broken("photo"), visible: :all)

    attach_file("photo", red, make_visible: false)
    expect(page).to have_css(img("photo", "[src^='blob:']"), visible: :all)
    expect(page).to have_css(shown("photo"))
  end

  it "a morph that changes the src shows it again; one that keeps a broken src keeps it hidden" do
    expect(page).to have_css(broken("server"), visible: :all)

    find(img("refresh")).click
    expect(page).to have_css(img("refreshes"), text: "Refreshed 1")
    expect(page).to have_css(broken("server"), visible: :all)

    find(img("fix")).click
    expect(page).to have_css(shown("server"))
    expect(page).to have_css(img("server", "[src='/logos/007.svg']"))

    find(img("refresh")).click
    expect(page).to have_css(img("refreshes"), text: "Refreshed 2")
    expect(page).to have_css(shown("server"))
  end
end
