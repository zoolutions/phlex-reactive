# frozen_string_literal: true

require "system_helper"

# Issue #346: on_client("turbo:submit-end", js.check_group("ids[]", false),
# detail: { success: true }) clears the selection after a successful submit
# whose reply only swaps a flash, and keeps it after a failed (422) one so the
# user can retry.
RSpec.describe "Clear a selection on a successful submit only (issue #346)", type: :system do
  def box(testid) = find("[data-testid='#{testid}']")

  before { visit "/bulk_outcome" }

  it "clears the group after a 200 flash-only reply and keeps it after a 422" do
    box("row-1").click
    box("row-2").click
    expect(page).to have_css("[data-testid='count']", text: "2")

    box("fail").click
    expect(page).to have_css("#flash", text: "Could not publish 1,2")
    expect(page).to have_css("[data-testid='count']", text: "2")
    expect(box("row-1")).to be_checked
    expect(box("row-2")).to be_checked

    box("publish").click
    expect(page).to have_css("#flash", text: "Published 1,2")
    expect(page).to have_css("[data-testid='count']", text: "0")
    expect(box("row-1")).not_to be_checked
    expect(box("row-2")).not_to be_checked
    expect(box("all")).not_to be_checked
  end
end
