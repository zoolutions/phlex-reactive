# frozen_string_literal: true

require "system_helper"

# Editable text (issue #351): reactive_editable makes a contenteditable heading
# a plain-text field. Typing saves on a debounced `input` and the reply morphs
# the root; while the heading is focused the morph must leave its text and
# caret alone (attributes still morph), so nothing typed during a round trip
# is lost and the caret stays at the end.
#
# Runs under Puma (sync) AND Falcon (async) in CI's server matrix.
RSpec.describe "Editable text (issue #351)", type: :system do
  let(:todo) { Todo.create!(title: "Card") }
  let(:title) { find("[data-testid='title']") }

  def caret_at_end
    page.execute_script(<<~JS)
      const el = document.querySelector("[data-testid='title']")
      el.focus()
      const range = document.createRange()
      range.selectNodeContents(el)
      range.collapse(false)
      const selection = getSelection()
      selection.removeAllRanges()
      selection.addRange(range)
    JS
  end

  def caret_offset_from_end
    page.evaluate_script(<<~JS)
      (() => {
        const el = document.querySelector("[data-testid='title']")
        const selection = getSelection()
        if (!el.contains(selection.anchorNode)) return null
        const range = document.createRange()
        range.selectNodeContents(el)
        range.setStart(selection.anchorNode, selection.anchorOffset)
        return range.toString().length
      })()
    JS
  end

  before do
    visit "/editable_title/#{todo.id}"
    page.execute_script("window.__noReload = 'alive'")
    caret_at_end
  end

  it "keeps the typed text and the caret through the morphs that land while typing" do
    # A trailing space the server squishes away: its morph lands while the
    # heading is focused and must not take the space (nor the caret) with it.
    title.send_keys(" Hello ")
    expect(page).to have_css("[data-testid='current']", text: "Card Hello") # saved + morphed
    expect(page).to have_css("[data-testid='title'][data-saved-length='10']") # attributes still morph

    title.send_keys("world")
    expect(page).to have_css("[data-testid='current']", text: "Card Hello world")
    expect(page).to have_css("[data-testid='title'][data-saved-length='16']")

    expect(title.text).to eq("Card Hello world")
    expect(caret_offset_from_end).to eq(0)
    expect(todo.reload.title).to eq("Card Hello world")
    expect(page.evaluate_script("window.__noReload")).to eq("alive")
  end

  it "takes the server's text once the heading is no longer focused" do
    title.send_keys(" draft")
    expect(page).to have_css("[data-testid='current']", text: "Card draft")
    find("[data-testid='shout']").click # blurs the heading; its reply morphs it
    expect(page).to have_css("[data-testid='title']", exact_text: "CARD DRAFT")
  end

  it "swallows Enter in a single-line field and reverts to the saved text on Escape" do
    title.send_keys(" one")
    expect(page).to have_css("[data-testid='current']", text: "Card one")

    title.send_keys(:enter)
    expect(page).to have_no_css("[data-testid='title'] br, [data-testid='title'] div")
    expect(title.text).to eq("Card one")

    # Escape inside the debounce window, so " typo" was never saved.
    title.send_keys(" typo", :escape)
    expect(title.text).to eq("Card one")
    expect(page.evaluate_script("document.activeElement.dataset.testid")).not_to eq("title")
  end
end
