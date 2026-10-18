# frozen_string_literal: true

require "system_helper"

# Issue #442, end to end in a real browser: a list bound ONCE with
# on_client(:click, ops, within: "[role=option]"). A click anywhere in a row
# (here on the span inside it) runs the list's record with that row as
# :trigger: the row's data-value lands in the hidden field (with one `input`),
# its data-label in the label node, it alone gets aria-selected, and the page
# hears app:item-picked with a detail read off the row. Enter on the row
# reactive_listnav highlights picks it through the same binding. A click on
# the list outside every row runs nothing and keeps its default. No fetch.
RSpec.describe "One delegated binding for a pickable list (issue #442)", type: :system do
  def install_probes
    page.execute_script(<<~JS)
      window.__picked = []
      document.addEventListener("app:item-picked", (e) => window.__picked.push(e.detail))
      window.__inputs = 0
      document.getElementById("item-value").addEventListener("input", () => window.__inputs++)
      window.__lastDefaultPrevented = null
      document.addEventListener("click", (e) => { window.__lastDefaultPrevented = e.defaultPrevented })
      window.__fetchCount = 0
      const original = window.fetch
      window.fetch = (...args) => { window.__fetchCount++; return original(...args) }
      window.__marker = "kept"
    JS
  end

  def item_value = page.evaluate_script("document.getElementById('item-value').value")

  before do
    visit "/item_picker"
    find("[data-testid='item-picker'][data-reactive-connected]")
    install_probes
  end

  it "binds the list once: no row carries an ops record" do
    expect(page.evaluate_script("document.querySelectorAll('#item-picker [data-reactive-ops-param]').length")).to eq(1)
    expect(page.evaluate_script("document.querySelectorAll('[role=option][data-reactive-ops-param]').length")).to eq(0)
  end

  it "a click on the text inside a row picks that row" do
    find("[data-testid='item-2-text']").click

    expect(page).to have_css("[data-testid='item-label']", exact_text: "South")
    expect(page).to have_css("[data-testid='item-2'][aria-selected='true']")
    expect(item_value).to eq("south")
    expect(page.evaluate_script("window.__inputs")).to eq(1)
    expect(page.evaluate_script("window.__picked")).to eq([{ "id" => "2", "value" => "south", "text" => "South" }])
    expect(page.evaluate_script("window.__fetchCount")).to eq(0)
    expect(page.evaluate_script("window.__marker")).to eq("kept")
  end

  it "picking another row moves the selection" do
    find("[data-testid='item-1-text']").click
    expect(page).to have_css("[data-testid='item-1'][aria-selected='true']")

    find("[data-testid='item-3']").click

    expect(page).to have_css("[data-testid='item-3'][aria-selected='true']")
    expect(page).to have_no_css("[data-testid='item-1'][aria-selected]")
    expect(page).to have_css("[data-testid='item-label']", exact_text: "East")
  end

  it "a click on the list outside every row runs nothing and keeps its default" do
    find("[data-testid='item-gap']").click

    expect(page.evaluate_script("window.__lastDefaultPrevented")).to be(false)
    expect(page.evaluate_script("window.__picked")).to eq([])
    expect(item_value).to eq("")
    expect(page).to have_no_css("[role=option][aria-selected]")
  end

  it "Enter on the highlighted row picks it through the same binding" do
    query = find("[data-testid='item-query']")
    query.send_keys(:down, :down)
    expect(page).to have_css("[data-testid='item-2'][data-reactive-highlighted]")

    query.send_keys(:enter)

    expect(page).to have_css("[data-testid='item-2'][aria-selected='true']")
    expect(item_value).to eq("south")
    expect(page.evaluate_script("window.__picked")).to eq([{ "id" => "2", "value" => "south", "text" => "South" }])
  end
end
