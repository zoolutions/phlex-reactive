# frozen_string_literal: true

require "system_helper"

# Issue #433: an element-bound on_client or on trigger with prevent: false
# keeps the event's default. A file dropped (a trusted drag, through CDP) on a
# native file input inside the bound element reaches the input, while the
# trigger's ops or action still run; the same trigger without the keyword
# cancels the drop.
RSpec.describe "on_client prevent: false (issue #433)", type: :system do
  let(:file) { File.expand_path("../fixtures/files/receipt.txt", __dir__) }

  before do
    visit "/drop_zone"
    page.find("#drop-zones[data-reactive-connected]")
    page.find("#drop-track[data-reactive-connected]")
  end

  def point(testid)
    page.evaluate_script(<<~JS)
      (() => { const r = document.querySelector("[data-testid='#{testid}']").getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2] })()
    JS
  end

  # A trusted drag of `file` onto the middle of `testid`: enter, over, drop.
  def drop_file(testid)
    x, y = point(testid)
    page.driver.with_playwright_page do
      cdp = it.context.new_cdp_session(it)
      data = { items: [], files: [file], dragOperationsMask: 1 }
      %w[dragEnter dragOver drop].each { cdp.send_message("Input.dispatchDragEvent", params: { type: it, x:, y:, data: }) }
    end
  end

  def files(testid) = page.evaluate_script("document.querySelector(\"[data-testid='#{testid}']\").files.length")

  it "delivers the dropped file to the input and still runs the drop trigger's ops" do
    drop_file("kept-input")

    expect(page).to have_css("[data-testid='kept-status']", text: "received") # the input's change fired
    expect(page).to have_css("[data-testid='kept-drop']", text: "dropped")
    expect(page).to have_no_css("#dz-kept.is-over")
    expect(files("kept-input")).to eq(1)
  end

  it "cancels the drop without the keyword (the default prevents)" do
    drop_file("prevented-input")

    expect(page).to have_css("[data-testid='prevented-drop']", text: "dropped") # the drop landed: the barrier
    expect(page).to have_no_css("#dz-prevented.is-over")
    expect(page).to have_css("[data-testid='prevented-status']", text: "empty")
    expect(files("prevented-input")).to eq(0)
  end

  it "keeps the default for a server trigger too: the file lands and the action still runs" do
    # On document, capture phase: the :track reply re-renders the zone, so a
    # listener on the input itself would be gone with it.
    page.execute_script(<<~JS)
      document.addEventListener("change", (e) => {
        if (e.target.dataset.testid === "track-input") window.__trackFiles = e.target.files.length
      }, true)
    JS

    drop_file("track-input")

    expect(page).to have_css("[data-testid='drops']", text: "1") # the :track round trip ran
    expect(page.evaluate_script("window.__trackFiles")).to eq(1)
  end
end
