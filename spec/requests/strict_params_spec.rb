# frozen_string_literal: true

require "rails_helper"

# Issue #460 end to end: an emptied number field reaches the action as its
# keyword default under a strict type, and a typed 0 stays 0. The value matrix
# lives in spec/phlex/reactive/param_schema_spec.rb.
RSpec.describe "Strict numeric param types (issue #460)", type: :request do
  let(:payload) { { "s" => { "received" => nil } } }
  let(:default) { StrictParamsComponent::KEYWORD_DEFAULT }

  def received(response)
    JSON.parse(CGI.unescapeHTML(response.body[%r{data-testid="received">(.*?)</pre>}m, 1]))
  end

  def save(params)
    post_action(StrictParamsComponent, payload:, act: "save", params:)
    expect(response).to have_http_status(:ok)
    received(response)
  end

  it "gives a cleared number field the keyword default, not a fabricated 0" do
    expect(save("quantity" => "", "weight" => "")).to include("quantity" => default, "weight" => default)
  end

  it "tells a typed 0 from a cleared field" do
    expect(save("quantity" => "0", "weight" => "0")).to include("quantity" => 0, "weight" => 0.0)
  end

  it "coerces a JSON number the same as the string a form posts" do
    expect(save("quantity" => 15, "weight" => 1.5)).to include("quantity" => 15, "weight" => 1.5)
  end

  it "gives an unparsable value the keyword default" do
    expect(save("quantity" => "12abc", "weight" => "0x10")).to include("quantity" => default, "weight" => default)
  end

  it "leaves :integer reading the same cleared field as 0" do
    expect(save("cap" => "")).to include("cap" => 0)
  end

  it "keeps the array elements that coerce" do
    expect(save("sizes" => ["1", "", "x", "2"])).to include("sizes" => [1, 2])
  end

  # A root holding a file posts a form body instead of JSON: every value arrives
  # as a string, and a cleared field as "".
  context "when the action arrives as a form body" do
    def save_form(params)
      post_reactive_multipart(StrictParamsComponent, "save", payload:, params:)
      expect(response).to have_http_status(:ok)
      received(response)
    end

    it "gives a cleared number field the keyword default" do
      expect(save_form("quantity" => "", "weight" => "")).to include("quantity" => default, "weight" => default)
    end

    it "tells a typed 0 from a cleared field" do
      expect(save_form("quantity" => "0", "weight" => "0")).to include("quantity" => 0, "weight" => 0.0)
    end

    it "coerces numbers and drops what will not parse" do
      expect(save_form("quantity" => "15", "weight" => "abc")).to include("quantity" => 15, "weight" => default)
    end

    it "keeps the array elements that coerce" do
      expect(save_form("sizes" => ["1", "", "2"])).to include("sizes" => [1, 2])
    end
  end
end
