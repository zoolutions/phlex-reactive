# frozen_string_literal: true

require 'system_helper'

# Issue #373: the client-ops page's media preview demo — reactive_media follows
# the code field, js.copy_media copies a named image.
RSpec.describe 'Media preview demo', type: :system do
  before { visit '/docs/example-client-ops' }

  it 'shows the pool image for the code prefix, and clears on a miss' do
    expect(page).to have_css("#mpv-logo[src='/media-demo/north.svg'][alt='North']")
    expect(page).to have_css('#mpv-caption', text: 'North')

    fill_in 'code', with: '011-9'
    expect(page).to have_css("#mpv-logo[src='/media-demo/south.svg']")

    fill_in 'code', with: '999'
    expect(page).to have_css('#mpv-caption', text: 'Unknown branch')
    expect(page).to have_css('#mpv-logo:not([src])', visible: :all)
  end

  # Issue #380: below three digits (or a non-digit key) the binding is pending —
  # no "Unknown branch", and the figure hides itself on the state attribute.
  it 'stays pending until three digits are typed' do
    %w[00 ab1].each do |code|
      fill_in 'code', with: '999'
      expect(page).to have_css("#mpv-logo[data-reactive-media-state='miss']")
      fill_in 'code', with: code
      expect(page).to have_css("#mpv-logo[data-reactive-media-state='pending']", visible: :all)
      expect(page).to have_no_css('#mpv-logo')
      expect(page).to have_no_css('#mpv-caption', text: 'Unknown branch', visible: :all)
    end
  end

  it 'keeps the name of a branch with no logo file (issue #381)' do
    fill_in 'code', with: '050'
    expect(page).to have_css('#mpv-caption', text: 'Central')
    expect(page).to have_css("#mpv-logo[alt='Central']:not([src])", visible: :all)
  end

  it 'copies a named image with js.copy_media' do
    within('#media-preview') { click_button 'East' }
    expect(page).to have_css("#mpv-copied[src='/media-demo/east.svg'][alt='East']")
  end
end
