# frozen_string_literal: true

require 'system_helper'

# Issue #365: the client-ops page's modal dialog demo — a picker opened with
# js.show_modal, and a server-rendered dialog upgraded by data-reactive-modal.
RSpec.describe 'Modal dialog demo', type: :system do
  def modal?(id)
    page.evaluate_script("document.getElementById('#{id}').matches(':modal')")
  end

  before { visit '/docs/example-client-ops' }

  it 'opens the picker as a modal, picks an item and closes it' do
    click_button 'Choose a fruit…'
    expect(page).to have_css('#mp-picker[open]')
    expect(modal?('mp-picker')).to be(true)

    within('#mp-picker') { click_button 'Banana' }
    expect(page).to have_css('#mp-status', text: 'Banana')
    expect(modal?('mp-picker')).to be(false)
  end

  it 'makes the dialog a reply renders open modal, and closes it when the server does' do
    click_button 'Delete (asks the server)'
    expect(page).to have_css('#mp-confirm[open]')
    expect(modal?('mp-confirm')).to be(true)

    within('#mp-confirm') { click_button 'Cancel (the server closes it)' }
    expect(page).to have_no_css('#mp-confirm[open]', visible: :all)
    expect(modal?('mp-confirm')).to be(false)
  end

  it 'closes the server-rendered dialog through the server on Escape' do
    click_button 'Delete (asks the server)'
    expect(page).to have_css('#mp-confirm[open]')
    confirming_token = find_by_id('modal-picker')['data-reactive-token-value']

    page.driver.with_playwright_page { it.keyboard.press('Escape') }
    expect(page).to have_no_css('#mp-confirm[open]', visible: :all)
    expect(modal?('mp-confirm')).to be(false)
    # The server re-rendered with @confirming cleared: the root carries a new token.
    expect(page).to have_no_css("#modal-picker[data-reactive-token-value='#{confirming_token}']")

    click_button 'Delete (asks the server)'
    expect(page).to have_css('#mp-confirm[open]')
    expect(modal?('mp-confirm')).to be(true)
  end
end
