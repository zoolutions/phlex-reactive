# frozen_string_literal: true

require 'system_helper'

# Issue #442: the client-ops page's pickable list — bound once with
# on_client(within:), every value read off the picked row (:trigger).
RSpec.describe 'Pick list demo', type: :system do
  before do
    visit '/docs/example-client-ops'
    find('#pick-list[data-reactive-connected]')
  end

  it 'binds the list once: the list carries the one ops record, no row carries one' do
    expect(page.evaluate_script("document.querySelectorAll('#pick-list [data-reactive-ops-param]').length")).to eq(1)
    expect(page.evaluate_script("document.querySelectorAll('#pl-menu[data-reactive-ops-param]').length")).to eq(1)
    expect(page.evaluate_script("document.querySelectorAll('#pick-list [role=option][data-reactive-ops-param]').length"))
      .to eq(0)
  end

  it 'picks the row that was clicked, reading its value and label off it' do
    within('#pick-list') { find('#pl-2 .text-xs').click }

    expect(page).to have_css('#pl-label', exact_text: 'South')
    expect(page).to have_css('#pl-shown', exact_text: 'south')
    expect(page).to have_css("#pl-2[aria-selected='true']")
    expect(page.evaluate_script("document.getElementById('pl-value').value")).to eq('south')
  end

  it 'picks with the arrow keys and Enter through the same binding' do
    find_by_id('pl-query').send_keys(:down, :down, :down, :enter)

    expect(page).to have_css("#pl-3[aria-selected='true']")
    expect(page).to have_css('#pl-label', exact_text: 'East')
  end

  it 'runs nothing for a click on the heading inside the list, and keeps its default' do
    page.execute_script(<<~JS)
      window.__picked = 0
      document.addEventListener('region:picked', () => window.__picked++)
      document.addEventListener('click', (e) => { window.__prevented = e.defaultPrevented })
    JS
    within('#pick-list') { find('.menu-title').click }

    expect(page.evaluate_script('window.__prevented')).to be(false)
    expect(page.evaluate_script('window.__picked')).to eq(0)
    expect(page).to have_css('#pl-label', exact_text: 'nothing yet')
    expect(page).to have_no_css('[role=option][aria-selected]')
  end
end
