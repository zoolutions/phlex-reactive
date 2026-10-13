# frozen_string_literal: true

require "system_helper"

# Issue #375: js.preview_file paints the chosen file onto an img before any
# upload, through an object URL the client creates from the input's own File
# and revokes itself — on a re-pick, a clear, a non-image file, and when the
# server's re-render strips the src (morph) or swaps the img (replace). A
# revoked blob: URL no longer fetches, which is how these examples prove the
# revoke really happened, not just that it was called.
RSpec.describe "Preview a chosen file (issue #375)", type: :system do
  let(:red) { Rails.root.join("..", "fixtures", "files", "photo_red.png").to_s }   # 4×3
  let(:blue) { Rails.root.join("..", "fixtures", "files", "photo_blue.png").to_s } # 6×5
  let(:text_file) { Rails.root.join("..", "fixtures", "files", "receipt.txt").to_s }

  before do
    visit "/photo_preview"
    find("[data-testid='photo-file']") # the page is up before the spy goes in
    page.execute_script(<<~JS)
      window.__revoked = []
      const revoke = URL.revokeObjectURL.bind(URL)
      URL.revokeObjectURL = (url) => { window.__revoked.push(url); revoke(url) }
    JS
  end

  def photo_src = page.evaluate_script("document.querySelector('[data-testid=photo]').getAttribute('src')")
  def revoked = page.evaluate_script("window.__revoked")

  def fetchable?(url)
    page.evaluate_async_script(<<~JS, url)
      const [url, done] = arguments
      fetch(url).then(() => done(true), () => done(false))
    JS
  end

  # Wait until the img has decoded a file of that width (proves it LOADED it).
  def expect_photo_width(width)
    page.document.synchronize(5) do
      actual = page.evaluate_script(
        "(() => { const img = document.querySelector('[data-testid=photo]'); " \
        "return img.complete && img.getAttribute('src') ? img.naturalWidth : null })()"
      )
      raise Capybara::ExpectationNotMet, "photo naturalWidth is #{actual.inspect}, want #{width}" unless actual == width
    end
  end

  def choose_file(path, field: "photo") = attach_file(field, path)

  it "paints the chosen image from a blob: URL the client made, with its name" do
    choose_file(red)

    expect(page).to have_css("[data-testid='photo'][src^='blob:']")
    expect_photo_width(4)
    expect(page).to have_css("[data-testid='photo-name']", text: "photo_red.png")
  end

  it "revokes the first URL when a second image is chosen, and loads the second" do
    choose_file(red)
    expect(page).to have_css("[data-testid='photo'][src^='blob:']")
    first = photo_src

    choose_file(blue)

    expect(page).to have_css("[data-testid='photo-name']", text: "photo_blue.png")
    expect_photo_width(6)
    expect(photo_src).not_to eq(first)
    expect(revoked).to eq([first])
    expect(fetchable?(first)).to be(false)
    expect(fetchable?(photo_src)).to be(true)
  end

  it "clears the preview and revokes the URL when the input is cleared" do
    choose_file(red)
    expect(page).to have_css("[data-testid='photo'][src^='blob:']")
    url = photo_src

    page.execute_script(<<~JS)
      const input = document.querySelector("[data-testid=photo-file]")
      input.value = ""
      input.dispatchEvent(new Event("change", { bubbles: true }))
    JS

    expect(page).to have_no_css("[data-testid='photo'][src]")
    expect(page).to have_css("[data-testid='photo-name']", exact_text: "")
    expect(revoked).to eq([url])
    expect(fetchable?(url)).to be(false)
  end

  it "clears the preview and revokes the URL when a non-image file is chosen" do
    choose_file(red)
    expect(page).to have_css("[data-testid='photo'][src^='blob:']")
    url = photo_src

    choose_file(text_file)

    expect(page).to have_no_css("[data-testid='photo'][src]")
    expect(page).to have_css("[data-testid='photo-name']", exact_text: "")
    expect(revoked).to eq([url])
  end

  it "never gives an iframe a src" do
    choose_file(red, field: "frame")

    # The change has run once the listener's turn is over; nothing to wait for.
    page.evaluate_async_script("requestAnimationFrame(() => arguments[0]())")
    expect(page).to have_css("[data-testid='frame']:not([src])")
  end

  it "revokes the URL when a morph reply renders the img without a src" do
    choose_file(red)
    expect(page).to have_css("[data-testid='photo'][src^='blob:']")
    url = photo_src

    find("[data-testid='refresh-morph']").click

    expect(page).to have_css("[data-testid='refreshes']", text: "Refreshed 1")
    expect(page).to have_no_css("[data-testid='photo'][src]")
    page.document.synchronize(5) { raise Capybara::ExpectationNotMet, "not revoked" unless revoked == [url] }
    expect(fetchable?(url)).to be(false)
  end

  it "revokes the URL when a replace reply swaps the img out" do
    choose_file(red)
    expect(page).to have_css("[data-testid='photo'][src^='blob:']")
    url = photo_src

    find("[data-testid='refresh-replace']").click

    expect(page).to have_css("[data-testid='refreshes']", text: "Refreshed 1")
    page.document.synchronize(5) { raise Capybara::ExpectationNotMet, "not revoked" unless revoked == [url] }
    expect(fetchable?(url)).to be(false)
  end
end
