# frozen_string_literal: true

require "rails_helper"
require "turbo/broadcastable/test_helper"

# Dormant roots (issue #274): the ACTOR's reply renders a dormant root AWAKE —
# the reply only exists because that page's controller is loaded and connected,
# so a dormant replacement would cost one more wake and save nothing. A
# broadcast keeps the root dormant: its subscribers may never have loaded the
# client.
RSpec.describe "Dormant roots in replies (issue #274)", type: :request do
  include Turbo::Broadcastable::TestHelper

  let(:payload) { { "s" => { "clicks" => 0, "loads" => 0 } } }

  it "renders the page-embedded root dormant" do
    html = DormantPanelComponent.new.call

    expect(html).to include('data-reactive-dormant="reactive"')
    expect(html).to include('data-controller="probe"')
  end

  describe "the actor reply (POST action_path)" do
    it "renders the replacement awake, keeping the app's own controller" do
      post_action(DormantPanelComponent, payload:, act: "bump")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('<turbo-stream action="replace" target="dormant-panel">')
      expect(response.body).to include('data-controller="probe reactive"')
      expect(response.body).not_to include("data-reactive-dormant")
    end

    it "renders an explicit reply (built inside the action body) awake too" do
      post_action(DormantPanelComponent, payload:, act: "load")

      expect(response.body).to include('method="morph"')
      expect(response.body).to include('data-controller="probe reactive"')
      expect(response.body).not_to include("data-reactive-dormant")
    end

    it "does not leak the awake state into the next render on the same thread" do
      post_action(DormantPanelComponent, payload:, act: "bump")

      expect(Phlex::Reactive::Dormant.awake?).to be(false)
      expect(DormantPanelComponent.new.call).to include('data-reactive-dormant="reactive"')
    end

    it "leaves it dormant-free after a failed action too" do
      post_action(DormantPanelComponent, payload:, act: "nope")

      expect(response).to have_http_status(:forbidden)
      expect(Phlex::Reactive::Dormant.awake?).to be(false)
    end
  end

  describe "a broadcast fired INSIDE the action" do
    it "stays dormant while the actor's reply is awake" do
      broadcasts = capture_turbo_stream_broadcasts("dormant") do
        post_action(DormantPanelComponent, payload:, act: "bump_and_broadcast")
      end
      broadcast_html = broadcasts.map(&:to_s).join # rubocop:disable Style/MapJoin

      expect(broadcast_html).to include('data-reactive-dormant="reactive"')
      expect(response.body).to include('data-controller="probe reactive"')
      expect(response.body).not_to include("data-reactive-dormant")
    end
  end

  # reactive_lazy(on:) (issue #276): the event shell is dormant; the real
  # content `__materialize` returns is awake, so it needs no second wake.
  describe "a dormant reactive_lazy(on:) component" do
    it "ships a dormant shell with its once-bound trigger" do
      html = DormantLazyPanelComponent.new(scope: "mine").call

      expect(html).to include('data-reactive-dormant="reactive"')
      expect(html).not_to include("data-controller")
      expect(html).to include('data-reactive-action-param="__materialize"')
    end

    it "materializes awake" do
      post_action(DormantLazyPanelComponent, payload: { "s" => { "scope" => "mine" } }, act: "__materialize")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("item:mine")
      expect(response.body).to include('data-controller="reactive"')
      expect(response.body).not_to include("data-reactive-dormant")
      expect(Phlex::Reactive::Dormant.awake?).to be(false)
    end
  end

  describe "the defer endpoint (POST defer_path)" do
    it "renders awake: the client that fetched it is loaded" do
      token = Phlex::Reactive.sign_defer({ "c" => "DormantPanelComponent", **payload })
      post Phlex::Reactive.defer_path, params: { token: }.to_json,
        headers: { "Accept" => "text/vnd.turbo-stream.html", "Content-Type" => "application/json" }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-controller="probe reactive"')
      expect(response.body).not_to include("data-reactive-dormant")
    end
  end
end
