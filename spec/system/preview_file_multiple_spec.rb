# frozen_string_literal: true

require "system_helper"

# Issue #439: js.preview_file(…, per_file: true) on an <input multiple>. Every
# file of a real multi-file pick is checked (accept, then max_bytes); the
# refused ones leave input.files before the action mixed in after the op on
# the same change collects it, so only the accepted files are posted, and one
# reactive:file-rejected fires per refused file.
RSpec.describe "Preview and check every file of a multiple input (issue #439)", type: :system do
  let(:red) { Rails.root.join("..", "fixtures", "files", "photo_red.png").to_s }     # 73 B
  let(:blue) { Rails.root.join("..", "fixtures", "files", "photo_blue.png").to_s }   # 74 B
  let(:large) { Rails.root.join("..", "fixtures", "files", "photo_large.png").to_s } # 3,698 B (> max_bytes 1024)
  let(:text) { Rails.root.join("..", "fixtures", "files", "receipt.txt").to_s }

  before do
    visit "/multi_photo_preview"
    find("[data-testid='photos-file']") # the page is up before the spy goes in
    page.execute_script(<<~JS)
      window.__rejected = []
      document.addEventListener("reactive:file-rejected", (event) => window.__rejected.push({
        reason: event.detail.reason, file: event.detail.file?.name, index: event.detail.index,
        remaining: event.detail.remaining, target: event.target.id, files: event.target.files.length
      }))
    JS
  end

  def rejected = page.evaluate_script("window.__rejected")

  it "posts only the accepted file of a pick and announces each refused one" do
    attach_file("photos", [red, large, text])

    expect(page).to have_css("[data-testid='posted']", exact_text: "Posted 1: photo_red.png")
    expect(rejected).to eq([
      { "reason" => "size", "file" => "photo_large.png", "index" => 1, "remaining" => 1,
        "target" => "photos-file", "files" => 1 },
      { "reason" => "type", "file" => "receipt.txt", "index" => 2, "remaining" => 1,
        "target" => "photos-file", "files" => 1 }
    ])
  end

  it "posts every file when none is refused" do
    attach_file("photos", [red, blue])

    expect(page).to have_css("[data-testid='posted']", exact_text: "Posted 2: photo_red.png, photo_blue.png")
    expect(rejected).to eq([])
  end

  it "empties the input and posts no file when every file is refused" do
    attach_file("photos", [large, text])

    expect(page).to have_css("[data-testid='posted']", exact_text: "Posted 0:")
    expect(rejected.map { it.values_at("reason", "index", "remaining", "files") })
      .to eq([["size", 0, 0, 0], ["type", 1, 0, 0]])
  end

  it "paints the first accepted image and keeps only the accepted files in the input" do
    attach_file("gallery-file", [large, blue, text])

    expect(page).to have_css("[data-testid='gallery-shot'][src^='blob:']")
    expect(page).to have_css("[data-testid='gallery-name']", text: "photo_blue.png")
    expect(page.evaluate_script("[...document.getElementById('gallery-file').files].map((f) => f.name)"))
      .to eq(["photo_blue.png"])
    expect(rejected.map { it.values_at("reason", "file", "index", "remaining") })
      .to eq([["size", "photo_large.png", 0, 1], ["type", "receipt.txt", 2, 1]])
  end
end
