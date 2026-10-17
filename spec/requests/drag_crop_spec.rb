# frozen_string_literal: true

require "rails_helper"

# Issue #416: the dummy's crop box (state-backed). A release posts x/y/width/
# height as JSON numbers; the declared :float schema casts them, and the reply
# renders the box at the new values, so the morph moves it.
RSpec.describe DragCropComponent, type: :request do
  let(:state) do
    { "x" => 0.1, "y" => 0.1, "width" => 0.5, "height" => 0.4, "focus_x" => 0.5, "focus_y" => 0.5,
      "aspect" => "", "saves" => 0, "last" => "" }
  end

  it "re-renders the box and its fields at the released values" do
    post_action(described_class, act: "crop", payload: { "s" => state },
      params: { x: 0.2, y: 0.25, width: 0.5, height: 0.4, aspect: "2:1" })

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("left: 20%; top: 25%; width: 50%; height: 40%;")
    expect(response.body).to include('name="crop[y]" value="0.25"', "1 crop 0.2 0.25 0.5 0.4")
    expect(response.body).to match(/value="2:1"[^>]*checked/)
  end

  it "drops undeclared params (default-deny)" do
    post_action(described_class, act: "crop", payload: { "s" => state },
      params: { x: 0.2, y: 0.2, width: 0.5, height: 0.4, admin: true })

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("admin")
  end

  it "re-renders the focal point at its released fractions" do
    post_action(described_class, act: "focus", payload: { "s" => state }, params: { x: 0.75, y: 0.1 })

    expect(response.body).to include("left: 75%; top: 10%; translate: -50% -50%;")
  end
end
