# frozen_string_literal: true

require "rails_helper"

# Issue #258: a checkbox group posts the CHECKED VALUES under its `[]` name.
# This is the server half — it asserts what an action receives once the client
# sends what a group actually means. The wire shape is unit-tested in
# spec/javascript/reactive_collect_checkbox_groups.test.js, and the two meet in
# the browser in spec/system/checkbox_group_spec.rb.
RSpec.describe "Checkbox group param coercion (issue #258)", type: :request do
  let(:payload) { { "s" => { "received" => nil } } }

  # The reflected params the dummy component renders, the same extraction the
  # other request specs in this directory carry.
  def received(response)
    JSON.parse(CGI.unescapeHTML(response.body[%r{data-testid="received">(.*?)</pre>}m, 1]))
  end

  it "coerces the group's values into the declared array of strings" do
    post_action(CheckboxGroupComponent, payload:, act: "save",
      params: { "features[]" => %w[news events] })

    expect(response).to have_http_status(:ok)
    expect(received(response)["features"]).to eq(%w[news events])
  end

  it "keeps an empty group as an empty array, not as nil" do
    # With nothing ticked the client sends []. That has to survive as [], so an
    # action can tell "the operator cleared the group" from "the group never
    # rendered" — the latter arrives as a missing key.
    post_action(CheckboxGroupComponent, payload:, act: "save", params: { "features[]" => [] })

    expect(received(response)["features"]).to eq([])
  end

  it "distinguishes a cleared group from a group that never rendered" do
    post_action(CheckboxGroupComponent, payload:, act: "save", params: { "subscribe" => "yes" })

    expect(received(response)["features"]).to be_nil
  end

  it "takes the lone checkbox as the boolean it still posts" do
    post_action(CheckboxGroupComponent, payload:, act: "save", params: { "subscribe" => true })

    expect(received(response)["subscribe"]).to be(true)
  end

  it "coerces a <select multiple> group the same way" do
    post_action(CheckboxGroupComponent, payload:, act: "save",
      params: { "regions[]" => %w[north south] })

    expect(received(response)["regions"]).to eq(%w[north south])
  end

  describe "through a form-encoded body" do
    # `post_reactive_multipart` sends `application/x-www-form-urlencoded`, not
    # `multipart/form-data` — measured, the name promises more than it does. It
    # is still the right driver here: `params[features][]` reaches Rack exactly
    # as the client's FormData writes it, which is the parity the JSON cases
    # above assert from the other side. A true multipart body needs a file part,
    # which the browser suite covers.
    it "coerces a repeated params[features][] group into the declared array" do
      post_reactive_multipart(CheckboxGroupComponent, "save", payload:,
        params: { "features" => %w[news events] })

      expect(response).to have_http_status(:ok)
      expect(received(response)["features"]).to eq(%w[news events])
    end

    describe "the empty-group announcement (issue #258)" do
      it "fills an announced group that is absent from params" do
        post_reactive_multipart(CheckboxGroupComponent, "save", payload:,
          params: { "subscribe" => "yes" }, empty_groups: ["features"])

        expect(response).to have_http_status(:ok)
        expect(received(response)["features"]).to eq([])
      end

      it "lets VALUES win over an announcement" do
        # The announcement only fills an absence. A group that carries values
        # keeps them, whatever the field says.
        post_reactive_multipart(CheckboxGroupComponent, "save", payload:,
          params: { "features" => %w[news] }, empty_groups: ["features"])

        expect(received(response)["features"]).to eq(%w[news])
      end

      it "changes nothing when the field is absent — an old client stays correct" do
        post_reactive_multipart(CheckboxGroupComponent, "save", payload:,
          params: { "subscribe" => "yes" })

        expect(response).to have_http_status(:ok)
        expect(received(response)["features"]).to be_nil # the keyword default
      end
    end
  end
end
