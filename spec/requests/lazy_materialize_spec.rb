# frozen_string_literal: true

require "rails_helper"

# `__materialize` (issue #276): the framework-owned act a reactive_lazy(on:)
# shell dispatches. It rides the ACTION endpoint with the identity token (no
# TTL), renders the REAL template, and shares the defer endpoint's
# authorization step. It is refused (403) for any component that is not
# reactive_lazy(on:) — the identity token of a plain component cannot reach it.
RSpec.describe "reactive_lazy(on:) materialize", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  def materialize(klass, payload)
    post_action(klass, act: :__materialize, payload:)
  end

  it "renders the real template as a replace stream carrying a fresh identity token" do
    materialize(LazyPanelComponent, { "s" => { "scope" => "mine" } })

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/vnd.turbo-stream.html")
    expect(response.body).to include('<turbo-stream action="replace" target="lazy-panel">')
    expect(response.body).to include("item:mine")
    expect(response.body).to include("data-reactive-token-value")
  end

  it "never re-renders the shell or its trigger, so once: cannot re-arm" do
    materialize(LazyPanelComponent, { "s" => { "scope" => "mine" } })

    expect(response.body).not_to include("__materialize")
    expect(response.body).not_to include("reactive-defer-placeholder")
    expect(response.body).not_to include("panel:opened")
  end

  it "materializes a visibility-triggered component" do
    materialize(LazyFoldComponent, { "s" => { "label" => "x" } })

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("loaded:x")
  end

  it "works with a token minted long past defer_token_ttl (the shell has no expiry)" do
    token = reactive_token_for(LazyPanelComponent, { "s" => { "scope" => "old" } })

    travel(Phlex::Reactive.defer_token_ttl.seconds + 1.day) do
      post Phlex::Reactive.action_path,
        params: { token:, act: "__materialize", params: {} }.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "text/vnd.turbo-stream.html" }
    end

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("item:old")
  end

  it "is refused (403) for a component that is not reactive_lazy" do
    materialize(CounterComponent, { "s" => { "count" => 1 } })

    expect(response).to have_http_status(:forbidden)
    expect(response.body).not_to include('action="replace" target="counter"')
  end

  it "is refused (403) for a plain reactive_lazy (no on:) — it keeps the defer endpoint" do
    materialize(LazyStatsComponent, { "s" => { "scope" => "week" } })

    expect(response).to have_http_status(:forbidden)
  end

  it "maps a registered authorization error from the render to 403 (the defer endpoint's contract)" do
    materialize(LazyPanelComponent, { "s" => { "scope" => "forbidden" } })

    expect(response).to have_http_status(:forbidden)
    expect(response.body).not_to include("item:")
  end

  it "keeps the shell when the component opts out via render? false (empty stream, not an error)" do
    materialize(LazyPanelComponent, { "s" => { "scope" => "hidden" } })

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/vnd.turbo-stream.html")
    expect(response.body).to be_empty
  end

  it "400s a tampered token" do
    post Phlex::Reactive.action_path,
      params: { token: "garbage", act: "__materialize", params: {} }.to_json,
      headers: { "Content-Type" => "application/json", "Accept" => "text/vnd.turbo-stream.html" }

    expect(response).to have_http_status(:bad_request)
  end

  it "rejects a DEFER token posted as __materialize (purposes are disjoint)" do
    post Phlex::Reactive.action_path,
      params: { token: Phlex::Reactive.sign_defer({ "c" => "LazyPanelComponent", "s" => { "scope" => "x" } }),
                act: "__materialize", params: {} }.to_json,
      headers: { "Content-Type" => "application/json", "Accept" => "text/vnd.turbo-stream.html" }

    expect(response).to have_http_status(:bad_request)
  end

  it "instruments as a defer (a read), naming the component" do
    events = []
    sub = ActiveSupport::Notifications.subscribe("defer.phlex_reactive") { |*args| events << args.last }
    materialize(LazyPanelComponent, { "s" => { "scope" => "mine" } })
    ActiveSupport::Notifications.unsubscribe(sub)

    expect(events.size).to eq(1)
    expect(events.first).to include(component: "LazyPanelComponent", outcome: :ok)
  end
end
