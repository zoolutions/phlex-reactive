# frozen_string_literal: true

require "system_helper"

# Issue #382: js.preview_file under an app's upload validation. An app that
# rejects a file clears the input without a change event, or marks it invalid
# with setCustomValidity. The documented reactive:file-changed event re-runs
# the op after a silent clear; valid: true treats an invalid input as empty.
# A revoked blob: URL no longer fetches, which proves the revoke happened.
RSpec.describe "Preview a chosen file under upload validation (issue #382)", type: :system do
  let(:red) { Rails.root.join("..", "fixtures", "files", "photo_red.png").to_s }     # 73 B, 4×3
  let(:large) { Rails.root.join("..", "fixtures", "files", "photo_large.png").to_s } # 3,698 B, 40×30

  before do
    visit "/validated_photo_preview"
    find("[data-testid='upload-file']") # the page is up before the spies go in
    page.execute_script(<<~JS)
      window.__created = 0
      window.__revoked = []
      const create = URL.createObjectURL.bind(URL)
      const revoke = URL.revokeObjectURL.bind(URL)
      URL.createObjectURL = (file) => { window.__created += 1; return create(file) }
      URL.revokeObjectURL = (url) => { window.__revoked.push(url); revoke(url) }
    JS
  end

  def src(testid) = page.evaluate_script("document.querySelector('[data-testid=#{testid}]').getAttribute('src')")
  def created = page.evaluate_script("window.__created")
  def revoked = page.evaluate_script("window.__revoked")

  def fetchable?(url)
    page.evaluate_async_script(<<~JS, url)
      const [url, done] = arguments
      fetch(url).then(() => done(true), () => done(false))
    JS
  end

  # The change listeners have run once this frame is over.
  def settle = page.evaluate_async_script("requestAnimationFrame(() => arguments[0]())")

  # The app's validator: on change, a file over 1 KB is rejected by clearing
  # the input, with NO change event, and the documented event says so.
  def install_size_validator
    page.execute_script(<<~JS)
      const input = document.querySelector("[data-testid=upload-file]")
      input.addEventListener("change", () => {
        const file = input.files[0]
        if (!file || file.size <= 1024) return
        input.value = ""
        input.dispatchEvent(new CustomEvent("reactive:file-changed", { bubbles: true }))
      })
    JS
  end

  it "previews a valid pick as today" do
    attach_file("upload", red)

    expect(page).to have_css("[data-testid='upload-photo'][src^='blob:']")
    expect(page).to have_css("[data-testid='upload-name']", text: "photo_red.png")
  end

  it "clears src and name and revokes the URL when the app clears the input and dispatches reactive:file-changed" do
    attach_file("upload", red)
    expect(page).to have_css("[data-testid='upload-photo'][src^='blob:']")
    url = src("upload-photo")

    page.execute_script(<<~JS)
      const input = document.querySelector("[data-testid=upload-file]")
      input.value = ""
      input.dispatchEvent(new CustomEvent("reactive:file-changed", { bubbles: true }))
    JS

    expect(page).to have_no_css("[data-testid='upload-photo'][src]")
    expect(page).to have_css("[data-testid='upload-name']", exact_text: "")
    expect(revoked).to eq([url])
    expect(fetchable?(url)).to be(false)
  end

  it "leaves no preview of a file an app validator rejects on change" do
    install_size_validator
    attach_file("upload", red)
    expect(page).to have_css("[data-testid='upload-photo'][src^='blob:']")

    attach_file("upload", large)

    expect(page).to have_no_css("[data-testid='upload-photo'][src]")
    expect(page).to have_css("[data-testid='upload-name']", exact_text: "")
    expect(page.evaluate_script("document.querySelector('[data-testid=upload-file]').files.length")).to eq(0)
    expect(revoked.size).to eq(created) # every URL made, whichever listener ran first, is revoked
  end

  it "never previews a file while the input has a custom validity error (valid: true)" do
    page.execute_script("document.querySelector('[data-testid=upload-file]').setCustomValidity('Too big')")

    attach_file("upload", red)
    settle

    expect(page).to have_css("[data-testid='upload-photo']:not([src])")
    expect(page).to have_css("[data-testid='upload-name']", exact_text: "")
    expect(created).to eq(0)
  end

  it "clears a preview when the app marks the input invalid and dispatches reactive:file-changed" do
    attach_file("upload", red)
    expect(page).to have_css("[data-testid='upload-photo'][src^='blob:']")
    url = src("upload-photo")

    page.execute_script(<<~JS)
      const input = document.querySelector("[data-testid=upload-file]")
      input.setCustomValidity("Too big")
      input.dispatchEvent(new CustomEvent("reactive:file-changed", { bubbles: true }))
    JS

    expect(page).to have_no_css("[data-testid='upload-photo'][src]")
    expect(page).to have_css("[data-testid='upload-name']", exact_text: "")
    expect(revoked).to eq([url])
  end

  it "still previews an invalid input that did not opt into valid:" do
    page.execute_script("document.querySelector('[data-testid=plain-file]').setCustomValidity('Too big')")

    attach_file("plain", red)

    expect(page).to have_css("[data-testid='plain-photo'][src^='blob:']")
  end
end
