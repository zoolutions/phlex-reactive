# frozen_string_literal: true

require 'system_helper'

# The Editable text page (issue #351): typing into the card's title autosaves
# through a debounced action whose reply morphs the card, and the focused title
# keeps what was typed; Enter in the single-line title moves to the note.
RSpec.describe 'Editable text', type: :system do
  before { Todo.delete_all }

  it 'autosaves the title while typing and keeps the typed text through the morph' do
    visit '/docs/editable-text'
    page.execute_script("window.__noReload = 'alive'")

    within first("[data-testid='live-example-demo']") do
      title = find("[data-testid='editable-title']")
      page.execute_script(<<~JS)
        const el = document.querySelector("[data-testid='editable-title']")
        el.focus()
        const range = document.createRange()
        range.selectNodeContents(el)
        range.collapse(false)
        getSelection().removeAllRanges()
        getSelection().addRange(range)
      JS
      title.send_keys(' now')
      expect(page).to have_text('Saved title: Click to rename this card now')
      expect(title.text).to eq('Click to rename this card now')

      title.send_keys(:enter)
      expect(page.evaluate_script('document.activeElement.dataset.testid')).to eq('editable-note')
    end

    expect(page.evaluate_script('window.__noReload')).to eq('alive')
  end
end
