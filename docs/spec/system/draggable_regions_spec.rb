# frozen_string_literal: true

require 'system_helper'

# The draggable-regions guide's live demo (issue #416) in a real browser: a
# mouse drag moves the crop box and saves it, a preset re-fits it, and the
# keyboard moves it.
RSpec.describe 'Draggable regions', type: :system do
  def rect(testid)
    page.evaluate_script(<<~JS)
      (() => { const r = document.querySelector("[data-testid='#{testid}']").getBoundingClientRect(); return [r.left, r.top, r.width, r.height] })()
    JS
  end

  before do
    visit '/docs/draggable-regions'
    page.execute_script("document.querySelector(\"[data-testid='region-picker']\").scrollIntoView({ block: 'center' })")
    find("[data-testid='region-picker'][data-reactive-connected]")
  end

  it 'moves the crop box with a mouse drag and saves it on release' do
    left, top, width, height = rect('region-box')
    x0 = left + (width * 0.2) # off the focal point in the middle
    y0 = top + (height * 0.2)
    right = rect('region-frame')[2] * 0.1
    page.driver.with_playwright_page do |pw|
      pw.mouse.move(x0, y0)
      pw.mouse.down
      pw.mouse.move(x0 + right, y0, steps: 8)
      pw.mouse.up
    end
    expect(page).to have_css("[data-testid='region-saved']", text: 'Saved: 45% × 60% at 30%, 15%')
    expect(page).to have_field('crop[x]', with: '0.3')
  end

  it 're-fits the box when a preset is picked' do
    find("[data-testid='region-aspect-square']").click
    expect(page).to have_css("[data-testid='region-aspect-square']:checked")
    expect(page).to have_no_css("[data-testid='region-saved']", text: 'Saved: 45% × 60%')
    _, _, width, height = rect('region-box')
    expect(width).to be_within(2).of(height)
  end

  it 'moves the box with the keyboard' do
    find("[data-testid='region-box']").send_keys(:right)
    expect(page).to have_css("[data-testid='region-saved']", text: 'at 21%, 15%')
  end
end
