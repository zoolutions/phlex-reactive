# frozen_string_literal: true

require "system_helper"

# Issue #398: nested select-all groups in a real browser — a branch header
# ticks and unticks its descendant leaves, every header is checked /
# indeterminate / unchecked from its own leaves (a parent follows a nested
# header), the headers never post, every leaf posts under one perms[] name,
# and a nested reactive root's leaf is never flipped.
RSpec.describe "Nested selection groups (issue #398)", type: :system do
  def box(testid) = find("[data-testid='#{testid}']")

  def state(testid)
    page.evaluate_script(<<~JS)
      (() => { const el = document.querySelector("[data-testid='#{testid}']"); return [el.checked, el.indeterminate] })()
    JS
  end

  before { visit "/nested_selection" }

  it "ticks and unticks a branch's descendant leaves from its header" do
    box("library").click
    %w[notes view edit].each { expect(box(it)).to be_checked }
    expect(box("billing")).not_to be_checked
    expect(box("nested")).not_to be_checked
    expect(page).to have_css("[data-testid='count']", text: "3")
    expect(state("books")).to eq([true, false])
    expect(state("all")).to eq([false, true])

    box("library").click
    %w[notes view edit].each { expect(box(it)).not_to be_checked }
    expect(page).to have_css("[data-testid='count']", text: "0")
    expect(state("library")).to eq([false, false])
  end

  it "makes a nested header and its parents indeterminate on a partial branch" do
    box("view").click
    expect(page).to have_css("[data-testid='count']", text: "1")
    expect(state("books")).to eq([false, true])
    expect(state("library")).to eq([false, true])
    expect(state("all")).to eq([false, true])

    box("books").click
    expect(box("edit")).to be_checked
    expect(state("books")).to eq([true, false])
    expect(state("library")).to eq([false, true])

    box("notes").click
    expect(page).to have_css("[data-testid='count']", text: "3")
    expect(state("library")).to eq([true, false])
  end

  it "posts the leaves under one name and never the headers" do
    box("books").click
    box("billing").click
    expect(page).to have_css("[data-testid='count']", text: "3")
    box("save").click
    expect(page).to have_css("[data-testid='result']", text: "perms:view,edit,billing")
  end
end
