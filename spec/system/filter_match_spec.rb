# frozen_string_literal: true

require "system_helper"

# reactive_filter's match: and fold: (issue #425) in a real browser, on the
# minified client: the list narrows by word start with diacritics folded on
# both sides (String#normalize("NFD") and the \p{M} strip run in the engine
# the page runs in), with zero action POSTs.
RSpec.describe "reactive_filter match: :word_start, fold: true", type: :system do
  let(:cities) { %w[arhus barcelona berlin nantes new-york santander zurich] }

  # Waiting matchers on both sides: every named city shows, every other hides.
  def expect_visible(*shown)
    shown.each { expect(page).to have_css("[data-testid='city-#{it}']") }
    (cities - shown).each { expect(page).to have_css("[data-testid='city-#{it}']", visible: :hidden) }
  end

  def visit_city_filter
    visit "/city_filter"
    expect(page).to have_css("[role=option]", count: 7)
    page.execute_script(<<~JS)
      window.__actionPosts = 0
      const orig = window.fetch
      window.fetch = (url, opts) => {
        if (String(url).includes("/reactive/actions")) window.__actionPosts++
        return orig(url, opts)
      }
    JS
  end

  it "keeps only the names that start a word with the query, accents folded" do
    visit_city_filter
    query = find("[data-testid='city-query']")

    query.set("n")
    expect_visible("nantes", "new-york")

    query.set("ar") # Århus by its folded start; Barcelona's interior "ar" does not count
    expect_visible("arhus")

    query.set("zur")
    expect_visible("zurich")

    query.set("zür") # typed with the accent: both sides fold
    expect_visible("zurich")

    query.set("york") # the second word of New York
    expect_visible("new-york")

    query.set("")
    expect(page).to have_css("[role=option]", count: 7)
    expect(page.evaluate_script("window.__actionPosts")).to eq(0)
  end

  it "reveals the empty node when no word starts with the query" do
    visit_city_filter
    find("[data-testid='city-query']").set("ich") # only inside Zürich
    expect(page).to have_css("[data-testid='city-none']", text: "No match")
    expect(page).to have_css("[role=option]", count: 0)
  end
end
