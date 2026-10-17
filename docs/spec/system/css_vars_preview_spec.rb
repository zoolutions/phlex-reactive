# frozen_string_literal: true

require 'system_helper'

# Issue #417: the client-ops page's live preview — reactive_css_vars feeds the
# sliders, the select and the checkbox into custom properties on the image,
# with no request.
RSpec.describe 'Live CSS properties demo', type: :system do
  def image_style(expression)
    page.evaluate_script("(() => { const i = document.querySelector('[data-testid=cvp-image]'); return #{expression} })()")
  end

  def expect_style(expression, value)
    page.document.synchronize do
      actual = image_style(expression)
      raise Capybara::ExpectationNotMet, "#{expression} is #{actual.inspect}, expected #{value.inspect}" unless
        actual == value
    end
  end

  before do
    visit '/docs/example-client-ops'
    find('#css-vars-preview[data-reactive-connected]')
    page.execute_script(<<~JS)
      window.__fetches = 0
      const original = window.fetch
      window.fetch = function () { window.__fetches++; return original.apply(this, arguments) }
    JS
  end

  it 'brightens, rotates and greys the image as the controls move, with no request' do
    find("[data-testid='cvp-light']").send_keys(:right, :right)
    expect_style("i.style.getPropertyValue('--light')", '1.1')
    expect(image_style('getComputedStyle(i).filter')).to eq('brightness(1.1) saturate(1) grayscale(0)')

    find("[data-testid='cvp-turn']").select('90°')
    expect_style('getComputedStyle(i).rotate', '90deg')

    find("[data-testid='cvp-gray']").check
    expect_style("i.style.getPropertyValue('--gray')", '1')
    expect(image_style('getComputedStyle(i).filter')).to eq('brightness(1.1) saturate(1) grayscale(1)')

    find("[data-testid='cvp-radius']").send_keys(:right)
    expect_style('getComputedStyle(i).borderTopLeftRadius', '12px')

    expect(page.evaluate_script('window.__fetches')).to eq(0)
  end
end
