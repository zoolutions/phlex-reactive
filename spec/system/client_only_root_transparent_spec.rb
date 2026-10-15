# frozen_string_literal: true

require "system_helper"

# Issue #410: a server trigger inside a tokenless client-only root (a
# ClientBindings helper with its own reactive_filter) dispatches on the
# token-bearing component around it, and that component's action receives the
# controls under every client-only root it contains.
RSpec.describe "Client-only roots are transparent to server round trips (issue #410)", type: :system do
  before do
    visit "/tag_picker"
    page.execute_script("window.__noReload = 'alive'")
  end

  it "a box inside a client-only root reaches the outer action" do
    find("[data-testid='tag-blue']").check

    expect(page).to have_css("[data-testid='picked']", text: "picked:blue")
    expect(page.evaluate_script("window.__noReload")).to eq("alive")
  end

  it "the outer action receives boxes from its own root and from every client-only root" do
    find("[data-testid='tag-red']").check
    expect(page).to have_css("[data-testid='picked']", text: "picked:red")

    find("[data-testid='tag-square']").check
    expect(page).to have_css("[data-testid='picked']", text: "picked:red,square")

    find("[data-testid='tag-green']").check
    expect(page).to have_css("[data-testid='picked']", text: "picked:red,green,square")
  end

  it "the client-only root still filters its own options without a round trip" do
    page.execute_script(<<~JS)
      window.__actionPosts = 0
      const fetch = window.fetch
      window.fetch = (input, init) => {
        if (String(input?.url ?? input).includes("/reactive/actions")) window.__actionPosts++
        return fetch(input, init)
      }
    JS
    find("[data-testid='search-colours']").fill_in(with: "gre")

    expect(page).to have_css("[data-testid='option-green']")
    expect(page).to have_no_css("[data-testid='option-blue']")
    expect(page).to have_css("[data-testid='option-circle']")
    expect(page).to have_css("[data-testid='picked']", text: "picked:")
    expect(page.evaluate_script("window.__actionPosts")).to eq(0)

    find("[data-testid='tag-green']").check
    expect(page).to have_css("[data-testid='picked']", text: "picked:green")
  end
end
