# frozen_string_literal: true

require "system_helper"

# Issue #391: js.preview_file with wrap:, max_bytes: and accept:. The frame
# follows the chosen file; a file of the wrong type or over the byte cap is
# refused: the img is cleared, the frame hidden, reactive:file-rejected
# dispatched on the input. The input keeps its files and its validity.
RSpec.describe "Preview a chosen file inside a frame (issue #391)", type: :system do
  let(:red) { Rails.root.join("..", "fixtures", "files", "photo_red.png").to_s }     # 73 B
  let(:large) { Rails.root.join("..", "fixtures", "files", "photo_large.png").to_s } # 3,698 B (> max_bytes 1024)
  let(:text) { Rails.root.join("..", "fixtures", "files", "receipt.txt").to_s }

  before do
    visit "/framed_photo_preview"
    find("[data-testid='framed-file']") # the page is up before the spies go in
    page.execute_script(<<~JS)
      window.__created = 0
      window.__rejected = []
      const create = URL.createObjectURL.bind(URL)
      URL.createObjectURL = (file) => { window.__created += 1; return create(file) }
      document.addEventListener("reactive:file-rejected", (event) => window.__rejected.push(event.detail.reason))
    JS
  end

  def created = page.evaluate_script("window.__created")
  def rejected = page.evaluate_script("window.__rejected")
  def input_state = page.evaluate_script(<<~JS)
    (() => {
      const input = document.querySelector("[data-testid=framed-file]")
      return { files: input.files.length, message: input.validationMessage }
    })()
  JS

  it "shows the frame and paints an accepted image under the cap" do
    expect(page).to have_css("[data-testid='framed-box'][hidden]", visible: :all)

    attach_file("framed", red)

    expect(page).to have_css("[data-testid='framed-box']:not([hidden])")
    expect(page).to have_css("[data-testid='framed-photo'][src^='blob:']")
    expect(page).to have_css("[data-testid='framed-name']", text: "photo_red.png")
  end

  it "refuses a later text file for its type: clears the img, hides the frame, keeps the input" do
    attach_file("framed", red)
    expect(page).to have_css("[data-testid='framed-photo'][src^='blob:']")

    attach_file("framed", text)

    expect(page).to have_css("[data-testid='framed-box'][hidden]", visible: :all)
    expect(page).to have_no_css("[data-testid='framed-photo'][src]", visible: :all)
    expect(page).to have_css("[data-testid='framed-name']", exact_text: "", visible: :all)
    expect(rejected).to eq(["type"])
    expect(input_state).to eq("files" => 1, "message" => "")
  end

  it "refuses a file over max_bytes for its size without making an object URL" do
    attach_file("framed", large)

    expect(page).to have_css("[data-testid='framed-box'][hidden]", visible: :all)
    expect(page).to have_no_css("[data-testid='framed-photo'][src]", visible: :all)
    expect(rejected).to eq(["size"])
    expect(created).to eq(0)
    expect(input_state).to eq("files" => 1, "message" => "")
  end

  it "never un-hides a frame the author hid" do
    attach_file("kept", red)

    expect(page).to have_css("[data-testid='kept-photo'][src^='blob:']", visible: :all)
    expect(page).to have_css("[data-testid='kept-box'][hidden]", visible: :all)
  end
end
