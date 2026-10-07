# frozen_string_literal: true

require "system_helper"

# Issue #343: a list that is its own reactive root drives a bulk bar OUTSIDE it
# — the count, an enabled button and the bar's visibility — through
# reactive_group_targets (+ reactive_show_targets), with zero reactive requests
# for the ticking; a morph of the list (an action reply that drops a row)
# re-syncs the outside targets.
RSpec.describe "Cross-root group targets (issue #343)", type: :system do
  def box(testid) = find("[data-testid='#{testid}']")

  before { visit "/group_targets" }

  it "paints the outside bar from reactive_values: hidden, 0, both buttons disabled" do
    expect(page).to have_css("[data-testid='footer-count']", text: "0")
    expect(page).to have_css("#bulk-bar[hidden]", visible: :all)
    expect(page).to have_css("[data-testid='archive'][disabled]", visible: :all)
    expect(page).to have_css("[data-testid='merge'][disabled]", visible: :all)
  end

  it "drives the count, the enables and the bar from the nested root's boxes, client-only" do
    box("row-1").click
    expect(page).to have_css("[data-testid='bar']", visible: :visible)
    expect(page).to have_css("[data-testid='count']", text: "1")
    expect(page).to have_css("[data-testid='footer-count']", text: "1")
    expect(page).to have_css("[data-testid='archive']:not([disabled])")
    expect(page).to have_css("[data-testid='merge'][disabled]")

    box("row-2").click
    expect(page).to have_css("[data-testid='count']", text: "2")
    expect(page).to have_css("[data-testid='merge']:not([disabled])")

    box("row-1").click
    box("row-2").click
    expect(page).to have_css("[data-testid='footer-count']", text: "0")
    expect(page).to have_css("#bulk-bar[hidden]", visible: :all)
    expect(page).to have_css("[data-testid='archive'][disabled]", visible: :all)
    expect(page).to have_reactive_requests(0)
  end

  it "follows the select-all header's flip" do
    box("all").click
    expect(page).to have_css("[data-testid='count']", text: "3")
    expect(page).to have_css("[data-testid='footer-count']", text: "3")
    box("all").click
    expect(page).to have_css("[data-testid='footer-count']", text: "0")
    expect(page).to have_reactive_requests(0)
  end

  it "re-syncs the outside targets when a morph of the list drops a ticked row" do
    box("row-1").click
    expect(page).to have_css("[data-testid='footer-count']", text: "1")

    box("narrow").click
    expect(page).to have_no_css("[data-testid='row-1']")
    expect(page).to have_css("[data-testid='footer-count']", text: "0")
    expect(page).to have_css("[data-testid='archive'][disabled]", visible: :all)

    box("row-2").click # the morphed root still drives them
    expect(page).to have_css("[data-testid='footer-count']", text: "1")
    expect(page).to have_css("[data-testid='archive']:not([disabled])")
  end

  it "re-syncs the outside targets after js.check_group clears the selection (#342)" do
    box("row-1").click
    box("row-2").click
    expect(page).to have_css("[data-testid='footer-count']", text: "2")

    box("clear").click
    expect(page).to have_css("[data-testid='footer-count']", text: "0")
    expect(page).to have_css("#bulk-bar[hidden]", visible: :all)
    expect(page).to have_css("[data-testid='archive'][disabled]", visible: :all)
    expect(page).to have_no_css("[data-testid^='row-']:checked")
    expect(page).to have_reactive_requests(0)
  end
end
