# frozen_string_literal: true

require "rails_helper"

# Issue #208 Scenario A: fill-then-add — the server half. The GET renders the
# from:/clear: wiring on the add button (still tokenless, still client-only);
# the reconcile reuses the existing /orders and /orders_json endpoints, so no
# new persistence path is needed.
RSpec.describe "Draft order form — fill-then-add", type: :request do
  describe "GET /draft_order_fill (accepts_nested_attributes_for)" do
    it "renders the from: map + clear flag on the add trigger" do
      get "/draft_order_fill"

      expect(response).to have_http_status(:ok)
      body = response.body
      expect(body).to include('data-reactive-association-param="line_items"')
      # The from: map, JSON-encoded (HTML-escaped quotes in the attribute).
      expect(body).to include("data-reactive-nested-from-param")
      expect(body).to include("#src-qty").and include("#src-price")
      expect(body).to include('data-reactive-nested-clear-param="true"')
      # Still pure form state — no signed token.
      expect(body).not_to include("data-reactive-token-value")
    end
  end

  describe "GET /draft_order_fill_reset (clear: :reset, issue #466)" do
    it "renders the reset clear mode and the sources' rendered defaults" do
      get "/draft_order_fill_reset"

      expect(response).to have_http_status(:ok)
      body = response.body
      expect(body).to include('data-reactive-nested-clear-param="reset"')
      expect(body).to include("#src-gift")
      expect(body).not_to include("data-reactive-token-value")
    end
  end

  describe "GET /draft_order_fill_json (JSON mode)" do
    it "renders fill-then-add wiring + the json-mode markers together" do
      get "/draft_order_fill_json"

      expect(response).to have_http_status(:ok)
      body = response.body
      expect(body).to include("data-reactive-nested-from-param")
      expect(body).to include('data-reactive-nested-json="line_items"')
      expect(body).to include('name="order[line_items]"')
      expect(body).not_to include("data-reactive-token-value")
    end
  end
end
