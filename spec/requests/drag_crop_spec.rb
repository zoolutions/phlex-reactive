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

    # The action takes declared keywords only: an `admin:` reaching it would raise, not save.
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("1 crop 0.2 0.2 0.5 0.4")
    expect(response.body).not_to include("admin")
  end

  it "ignores a forged release outside the frame (the schema casts, it does not range-check)" do
    post_action(described_class, act: "crop", payload: { "s" => state }, params: { x: 0.8, y: 0.1, width: 0.5, height: 0.4 })

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("left: 10%; top: 10%; width: 50%; height: 40%;", "0 ")
  end

  it "ignores a forged release below 0 or of no size, and a forged focus outside 0..1" do
    [{ x: -0.1, y: 0.1, width: 0.5, height: 0.4 }, { x: 0.1, y: 0.1, width: 0, height: 0.4 }].each do
      post_action(described_class, act: "crop", payload: { "s" => state }, params: it)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("left: 10%; top: 10%; width: 50%; height: 40%;", "0 ")
    end

    post_action(described_class, act: "focus", payload: { "s" => state }, params: { x: 1.5, y: 0.1 })

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("left: 50%; top: 50%; translate: -50% -50%;")
  end

  it "re-renders the focal point at its released fractions" do
    post_action(described_class, act: "focus", payload: { "s" => state }, params: { x: 0.75, y: 0.1 })

    expect(response.body).to include("left: 75%; top: 10%; translate: -50% -50%;")
  end
end
