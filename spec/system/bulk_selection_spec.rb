# frozen_string_literal: true

require "system_helper"

# Issue #319: a bulk-selection list with zero per-list JavaScript, end to end in
# a real browser — reactive_select_all (tick/untick/indeterminate), reactive_count,
# reactive_enable from a { checked: 1.. } term (server first paint and live),
# rows appended/removed by a Turbo stream, a nested root's box excluded, and
# js.submit(…, submitter:) behind on_client(…, confirm:).
RSpec.describe "Bulk selection (issue #319)", type: :system do
  def box(testid) = find("[data-testid='#{testid}']")

  def header_state
    page.evaluate_script(<<~JS)
      (() => { const el = document.querySelector("[data-testid='all']"); return [el.checked, el.indeterminate] })()
    JS
  end

  def stream(html)
    page.execute_script("Turbo.renderStreamMessage(arguments[0])", html)
  end

  before { visit "/bulk_selection" }

  it "paints the enables disabled on the server, before any JavaScript runs" do
    expect(page).to have_css("[data-testid='delete'][disabled]")
    expect(page).to have_css("fieldset[data-testid='actions'][disabled]")
  end

  it "ticks and unticks the whole group from the header, and the header follows the group" do
    box("all").click
    %w[row-1 row-2 row-3].each { expect(box(it)).to be_checked }
    expect(page).to have_css("[data-testid='count']", text: "3")
    expect(header_state).to eq([true, false])

    box("row-2").click
    expect(page).to have_css("[data-testid='count']", text: "2")
    expect(header_state).to eq([false, true])

    box("all").click # from indeterminate → ticks all
    expect(page).to have_css("[data-testid='count']", text: "3")
    box("all").click
    %w[row-1 row-2 row-3].each { expect(box(it)).not_to be_checked }
    expect(page).to have_css("[data-testid='count']", text: "0")
    expect(header_state).to eq([false, false])
  end

  it "enables the button and the fieldset at one ticked box and disables them at zero" do
    box("row-1").click
    expect(page).to have_css("[data-testid='delete']:not([disabled])")
    expect(page).to have_css("fieldset[data-testid='actions']:not([disabled])")

    box("row-1").click
    expect(page).to have_css("[data-testid='delete'][disabled]")
    expect(page).to have_css("fieldset[data-testid='actions'][disabled]")
  end

  it "re-syncs the header and the count when a stream appends a row or removes a ticked one" do
    box("all").click
    expect(header_state).to eq([true, false])

    stream(<<~HTML)
      <turbo-stream action="append" target="rows"><template>
        <li id="row-4"><input type="checkbox" name="ids[]" value="4" data-testid="row-4"></li>
      </template></turbo-stream>
    HTML
    expect(page).to have_css("[data-testid='row-4']")
    expect(page).to have_css("[data-testid='count']", text: "3")
    expect(header_state).to eq([false, true])

    stream('<turbo-stream action="remove" target="row-1"></turbo-stream>')
    expect(page).to have_no_css("[data-testid='row-1']")
    expect(page).to have_css("[data-testid='count']", text: "2")
    expect(header_state).to eq([false, true])
  end

  it "never counts or flips a nested reactive root's box" do
    box("nested").click
    expect(page).to have_css("[data-testid='count']", text: "0")
    expect(page).to have_css("[data-testid='delete'][disabled]")

    box("all").click
    expect(page).to have_css("[data-testid='count']", text: "3")
    box("all").click
    expect(page).to have_css("[data-testid='count']", text: "0")
    expect(box("nested")).to be_checked
  end

  it "posts the submitter's name and value with the ticked ids after the confirm is accepted" do
    page.execute_script("window.confirm = () => true")
    box("row-1").click
    box("row-3").click
    box("delete").click

    expect(page).to have_css("[data-testid='result']", text: "delete:1,3")
  end

  it "submits nothing when the confirm is cancelled" do
    page.execute_script("window.__marker = 'kept'; window.confirm = () => { window.__asked = true; return false }")
    box("row-2").click
    box("delete").click

    expect(page).to have_css("[data-testid='delete']") # still on the page
    expect(page.evaluate_script("window.__asked")).to be(true)
    expect(page.evaluate_script("window.__marker")).to eq("kept")
    expect(box("result").text).to eq("")
    expect(box("row-2")).to be_checked
  end
end
