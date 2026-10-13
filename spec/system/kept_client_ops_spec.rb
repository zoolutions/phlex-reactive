# frozen_string_literal: true

require "system_helper"

# Issue #369: keep: on client ops. Clicking an item selects it with kept ops
# (class, aria-selected, its details shown) and marks it "touched" with an op
# without keep:. Then the list is morphed by the stream broadcast_to(…,
# morph: true) sends — rendered here from a fresh server render of the page,
# with one item renamed — and the kept state must survive while the render's
# own changes land. (Same-tab Action Cable delivery is too flaky to assert in a
# headless harness, see chat_spec.rb; the stream is what a broadcast delivers.)
RSpec.describe "Kept client ops (issue #369)", type: :system do
  # Fetch /kept_selection with `query` and render its list as a stream into
  # the page: a morph (what broadcast_to(morph: true) sends) or a replace.
  def stream_list(query, morph: true)
    page.execute_script(<<~JS)
      fetch("/kept_selection?#{query}").then((r) => r.text()).then((html) => {
        const el = new DOMParser().parseFromString(html, "text/html").getElementById("kept-list")
        window.Turbo.renderStreamMessage(
          '<turbo-stream action="replace"#{' method="morph"' if morph} target="kept-list"><template>' +
            el.outerHTML + "</template></turbo-stream>"
        )
      })
    JS
  end

  before do
    visit "/kept_selection"
    page.execute_script("window.__list = document.getElementById('kept-list')")
  end

  it "keeps the selection, aria-selected and the shown details through a morph, and the render still lands" do
    find("[data-testid='item-2']").click
    expect(page).to have_css("#item-2.selected.touched[aria-selected='true']")
    expect(page).to have_css("[data-testid='details-2']", visible: :visible)

    stream_list("renamed=3")
    expect(page).to have_css("[data-testid='name-3']", text: "Charlie (renamed)")

    # Morphed in place, not replaced.
    expect(page.evaluate_script("window.__list.isConnected")).to be(true)
    # Kept: the class, the attribute, the visibility.
    expect(page).to have_css("#item-2.selected[aria-selected='true']")
    expect(page).to have_css("[data-testid='details-2']", visible: :visible)
    # Not kept: the op without keep: is undone by the render.
    expect(page).to have_no_css("#item-2.touched")
    # The server's own class change on another item follows the render.
    expect(page).to have_css("#item-3.renamed:not(.selected)[aria-selected='false']")
    expect(page).to have_css("[data-testid='details-3']", visible: :hidden)
  end

  it "keeps only the latest selection: a kept remove_class cancels the earlier kept add" do
    find("[data-testid='item-1']").click
    expect(page).to have_css("#item-1.selected")
    find("[data-testid='item-3']").click
    expect(page).to have_css("#item-3.selected")

    stream_list("renamed=2")
    expect(page).to have_css("[data-testid='name-2']", text: "Bravo (renamed)")

    expect(page).to have_css(".item.selected", count: 1)
    expect(page).to have_css("#item-3.selected")
    expect(page).to have_css("[data-testid='details-3']", visible: :visible)
    expect(page).to have_css("[data-testid='details-1']", visible: :hidden)
  end

  it "starts clean when a stream replaces the list instead of morphing it" do
    find("[data-testid='item-2']").click
    expect(page).to have_css("#item-2.selected")

    stream_list("renamed=1", morph: false)
    expect(page).to have_css("[data-testid='name-1']", text: "Alpha (renamed)")

    expect(page.evaluate_script("window.__list.isConnected")).to be(false)
    expect(page).to have_no_css(".item.selected")
    expect(page).to have_css("[data-testid='details-2']", visible: :hidden)
  end
end
