# frozen_string_literal: true

require 'system_helper'

# Issue #375: the client-ops page's preview demo — js.preview_file paints the
# chosen image onto the img through a client-made object URL.
RSpec.describe 'Photo preview demo', type: :system do
  let(:photo) { Rails.public_path.join('icon.png').to_s }

  before { visit '/docs/example-client-ops' }

  it 'shows the chosen image and its name before any upload' do
    attach_file('pp-file', photo)

    expect(page).to have_css("#pp-photo[src^='blob:']")
    expect(page).to have_css('#pp-name', text: 'icon.png')
  end
end
