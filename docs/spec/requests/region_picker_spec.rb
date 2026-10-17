# frozen_string_literal: true

require 'rails_helper'

# The draggable-regions demo (issue #416): the crop and the focal point are
# signed state; a release sends :crop or :focus with fractions, and the reply
# morphs the box, the point and the checked preset to what the server stored.
RSpec.describe 'Region picker demo', type: :request do
  let(:state) do
    { 's' => { 'crop' => RegionPickerComponent::CROP, 'focus' => RegionPickerComponent::FOCUS, 'aspect' => '' } }
  end

  it 'renders the frame, the box with its handles, the point and the presets' do
    get '/docs/draggable-regions'

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-reactive-frame', 'data-reactive-box=', 'data-reactive-box-aspect="aspect"')
    expect(response.body.scan('data-reactive-box-handle=').size).to eq(8)
    expect(response.body).to include('data-reactive-point-within="[data-reactive-box]"')
    expect(response.body).to include('left: 20%; top: 15%; width: 45%; height: 60%;')
  end

  it 'stores the released crop and the preset, and morphs' do
    post_action(RegionPickerComponent, payload: state, act: 'crop',
                                       params: { x: 0.1, y: 0.2, width: 0.5, height: 0.5, aspect: '1:1' })

    expect(response.body).to include('method="morph"', 'left: 10%; top: 20%; width: 50%; height: 50%;')
    expect(response.body).to match(/value="1:1"[^>]*checked/)
    expect(response.body).to include('Saved: 50% × 50% at 10%, 20%')
  end

  it 'ignores a forged crop outside the picture (the schema casts, it does not range-check)' do
    post_action(RegionPickerComponent, payload: state, act: 'crop',
                                       params: { x: 2, y: 0.1, width: 0.5, height: 0.5, aspect: '1:1' })

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('left: 20%; top: 15%; width: 45%; height: 60%;')
    expect(response.body).not_to match(/value="1:1"[^>]*checked/)
  end

  it 'stores the released focal point' do
    post_action(RegionPickerComponent, payload: state, act: 'focus', params: { x: 0.25, y: 0.75 })

    expect(response.body).to include('left: 25%; top: 75%; translate: -50% -50%;', 'focus 25%, 75%')
  end
end
