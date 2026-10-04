# frozen_string_literal: true

require "rails_helper"

# The cacheable-fragment endpoint (issue #277): GET <fragment_path>/<signed id>
# renders a `reactive_lazy cache:` component's REAL template as a replace
# stream the browser may keep PRIVATELY for max-age. It is a read: no action
# runs. Every non-200 reply is no-store, a component that did not opt in is
# not reachable (404), and the viewer always comes from the session — the URL
# carries no user data, so two sessions get two renders.
#
# Two fixtures, the two ways a cached copy is kept from another viewer:
#   * CachedPanelComponent — the default: the reply says `Vary: Cookie`.
#   * CachedMenuComponent  — declares reactive_cache_viewer: the URL is keyed
#     on the viewer, and the reply is cacheable only for the viewer it names.
RSpec.describe "cacheable lazy fragments", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:headers) { { "Accept" => "text/vnd.turbo-stream.html" } }
  let(:panel_payload) { { "c" => "CachedPanelComponent", "s" => { "scope" => "mine" } } }
  let(:menu_payload) { { "c" => "CachedMenuComponent", "s" => { "scope" => "main" } } }

  # The URL a page rendered for `viewer` carries (the shell's own attribute).
  def menu_url(viewer: nil, scope: "main")
    html = Viewer.set(who: viewer) { CachedMenuComponent.new(scope:).call }
    CGI.unescapeHTML(html[/data-reactive-defer-src="([^"]+)"/, 1])
  end

  def panel_url(payload = panel_payload)
    Phlex::Reactive::Fragment.src(payload)
  end

  def get_fragment(url = panel_url, extra_headers: {})
    get url, headers: headers.merge(extra_headers)
  end

  def vary
    response.headers["Vary"].to_s.split(",").map(&:strip)
  end

  def cache_directives
    response.headers["Cache-Control"].to_s.split(",").map(&:strip).sort
  end

  before { CachedMenuComponent.version = nil }

  describe "a successful render" do
    it "returns the real template as a replace stream carrying a fresh identity token" do
      get_fragment

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/vnd.turbo-stream.html")
      expect(response.body).to include('<turbo-stream action="replace" target="cached-panel">')
      expect(response.body).to include("panel:mine")
      expect(response.body).to include("data-reactive-token-value")
      expect(response.body).not_to include("reactive-defer-placeholder")
      expect(response.body).not_to include("__materialize")
    end

    it "is privately cacheable for the declared max-age — never public" do
      get_fragment

      # Rails normalizes the directive order (ActionDispatch::Http::Cache).
      expect(response.headers["Cache-Control"]).to eq("max-age=600, private")
      expect(cache_directives).to eq(["max-age=600", "private"])
      expect(response.headers["Cache-Control"]).not_to include("public")
    end

    it "varies on the cookie" do
      get_fragment

      expect(vary).to include("Cookie")
    end

    it "carries an ETag and answers a matching revalidation with 304, still private" do
      get_fragment
      etag = response.headers["ETag"]
      expect(etag).to be_present

      get_fragment(extra_headers: { "If-None-Match" => etag })

      expect(response).to have_http_status(:not_modified)
      expect(response.body).to be_empty
      expect(response.headers["Cache-Control"]).to eq("max-age=600, private")
      expect(vary).to include("Cookie")
    end

    it "caps max-age at Phlex::Reactive.fragment_cache_max_age_limit" do
      original = Phlex::Reactive.fragment_cache_max_age_limit
      Phlex::Reactive.fragment_cache_max_age_limit = 60
      get_fragment

      expect(response.headers["Cache-Control"]).to eq("max-age=60, private")
    ensure
      Phlex::Reactive.fragment_cache_max_age_limit = original
    end

    it "works however old the URL is (the id has no expiry)" do
      url = panel_url

      travel(30.days) { get url, headers: headers }

      expect(response).to have_http_status(:ok)
    end

    it "instruments as a defer (a read), naming the component" do
      events = []
      sub = ActiveSupport::Notifications.subscribe("defer.phlex_reactive") { |*args| events << args.last }
      begin
        get_fragment
      ensure
        ActiveSupport::Notifications.unsubscribe(sub)
      end

      expect(events.size).to eq(1)
      expect(events.first).to include(component: "CachedPanelComponent", outcome: :ok)
    end

    it "never writes the session: a stored reply must not carry Set-Cookie" do
      get "/lazy_stats" # a page view: the layout's CSRF meta tag creates the session
      expect(response.headers["Set-Cookie"].to_s).to include("_dummy_session")

      get_fragment

      expect(response).to have_http_status(:ok)
      expect(response.headers["Set-Cookie"]).to be_blank
    end
  end

  describe "a component that names its viewer (reactive_cache_viewer)" do
    it "keys the URL on the viewer: the same for one viewer, different for another" do
      alice = menu_url(viewer: "alice")

      expect(menu_url(viewer: "alice")).to eq(alice)
      expect(menu_url(viewer: "bob")).not_to eq(alice)
      expect(menu_url(viewer: nil)).to match(/[?&]u=\h{16}\z/)
    end

    it "is cacheable WITHOUT Vary: Cookie when the URL names this session's viewer" do
      cookies[:viewer] = "alice"
      get_fragment(menu_url(viewer: "alice"))

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("menu:main:alice")
      expect(response.headers["Cache-Control"]).to eq("max-age=600, private")
      expect(vary).not_to include("Cookie")
      expect(response.headers["ETag"]).to be_present
    end

    it "renders for THIS viewer but is no-store when the URL names another viewer" do
      cookies[:viewer] = "bob"
      get_fragment(menu_url(viewer: "alice"))

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("menu:main:bob")
      expect(response.body).not_to include("alice")
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end

    it "is no-store when the URL names no viewer at all" do
      cookies[:viewer] = "alice"
      get_fragment(Phlex::Reactive::Fragment.src(menu_payload))

      expect(response).to have_http_status(:ok)
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end

    it "treats the anonymous viewer as a viewer" do
      get_fragment(menu_url(viewer: nil))

      expect(response.body).to include("menu:main:guest")
      expect(response.headers["Cache-Control"]).to eq("max-age=600, private")
    end
  end

  describe "the ETag" do
    it "follows the rendered body, not the v parameter" do
      get_fragment(Phlex::Reactive::Fragment.src(panel_payload, version: 1))
      first = response.headers["ETag"]
      get_fragment(Phlex::Reactive::Fragment.src(panel_payload, version: 2))

      expect(response.headers["ETag"]).to eq(first)
    end

    it "changes when the render changes" do
      get_fragment(menu_url(viewer: nil))
      first = response.headers["ETag"]
      cookies[:viewer] = "alice"
      get_fragment(menu_url(viewer: "alice"))

      expect(response.headers["ETag"]).not_to eq(first)
    end

    it "does not answer 304 to another viewer's ETag" do
      cookies[:viewer] = "alice"
      get_fragment(menu_url(viewer: "alice"))
      alices = response.headers["ETag"]

      cookies[:viewer] = "bob"
      get_fragment(menu_url(viewer: "bob"), extra_headers: { "If-None-Match" => alices })

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("menu:main:bob")
    end
  end

  describe "the query parameters" do
    it "never reach the render — an attacker-chosen v only varies the cache key" do
      get_fragment
      body = response.body
      get "#{panel_url}?v=#{"9" * 64}&scope=evil&c=CounterComponent&s[scope]=evil", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.body).to eq(body)
    end

    it "changes the URL when reactive_cache_version changes" do
      CachedMenuComponent.version = 1
      one = menu_url
      CachedMenuComponent.version = 2

      expect(menu_url).not_to eq(one)
    end
  end

  describe "the viewer comes from the session, never the URL" do
    it "gives each session its own render of the same URL" do
      url = panel_url({ "c" => "CachedMenuComponent", "s" => { "scope" => "main" } })
      alice = open_session
      bob = open_session
      alice.cookies[:viewer] = "alice"
      bob.cookies[:viewer] = "bob"

      alice.get url, headers: headers
      bob.get url, headers: headers

      expect(alice.response.body).to include("menu:main:alice")
      expect(alice.response.body).not_to include("bob")
      expect(bob.response.body).to include("menu:main:bob")
      expect(bob.response.body).not_to include("alice")
    end

    it "renders on every origin hit (the server keeps no copy)" do
      CachedMenuComponent.renders = 0

      2.times { get_fragment(menu_url) }

      expect(CachedMenuComponent.renders).to eq(2)
    end
  end

  describe "errors are never cacheable" do
    def expect_no_store(status)
      expect(response).to have_http_status(status)
      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(response.headers["ETag"]).to be_nil
    end

    it "404s a component that did not opt in with cache: (plain reactive_lazy keeps POST)" do
      get_fragment(panel_url({ "c" => "LazyStatsComponent", "s" => { "scope" => "week" } }))

      expect_no_store(:not_found)
      expect(response.body).not_to include("stats:")
    end

    it "404s an on: component without cache:" do
      get_fragment(panel_url({ "c" => "LazyPanelComponent", "s" => { "scope" => "mine" } }))

      expect_no_store(:not_found)
    end

    it "404s a component that is not lazy at all" do
      get_fragment(panel_url({ "c" => "CounterComponent", "s" => { "count" => 1 } }))

      expect_no_store(:not_found)
      expect(response.body).not_to include('target="counter"')
    end

    it "400s a tampered id" do
      id = Phlex::Reactive.sign_fragment(panel_payload)
      get_fragment("#{Phlex::Reactive.fragment_path}/#{id.reverse}")

      expect_no_store(:bad_request)
    end

    it "400s an id whose class was swapped (the signature covers it)" do
      token = Base64.urlsafe_decode64(Phlex::Reactive.sign_fragment(panel_payload))
      data, digest = token.split("--")
      swapped = Base64.strict_encode64(Base64.decode64(data).sub("CachedPanelComponent", "CachedMenuComponent"))
      get_fragment("#{Phlex::Reactive.fragment_path}/#{Base64.urlsafe_encode64("#{swapped}--#{digest}", padding: false)}")

      expect_no_store(:bad_request)
    end

    it "400s an IDENTITY token used as a fragment id" do
      token = Phlex::Reactive.sign(panel_payload)
      get_fragment("#{Phlex::Reactive.fragment_path}/#{Base64.urlsafe_encode64(token, padding: false)}")

      expect_no_store(:bad_request)
    end

    it "400s a DEFER token used as a fragment id" do
      token = Phlex::Reactive.sign_defer(panel_payload, unbound: true)
      get_fragment("#{Phlex::Reactive.fragment_path}/#{Base64.urlsafe_encode64(token, padding: false)}")

      expect_no_store(:bad_request)
    end

    it "403s a render the viewer may not see" do
      cookies[:viewer] = "banned"
      get_fragment(menu_url(viewer: "banned"))

      expect_no_store(:forbidden)
      expect(response.body).not_to include("menu:")
    end

    it "is no-store when the base controller rejects the session (401) before the endpoint runs" do
      cookies[:viewer] = "expired"
      get_fragment

      expect_no_store(:unauthorized)
      expect(response.body).not_to include("panel:")
    end

    it "is no-store for render? false (204: keep the shell)" do
      get_fragment(panel_url({ "c" => "CachedMenuComponent", "s" => { "scope" => "hidden" } }))

      expect_no_store(:no_content)
    end

    it "404s when the component's record is gone" do
      allow(CachedPanelComponent).to receive(:from_identity).and_raise(ActiveRecord::RecordNotFound)
      get_fragment

      expect_no_store(:not_found)
    end
  end

  describe "a fragment id on the POST endpoints (purposes are disjoint)" do
    let(:json_headers) { headers.merge("Content-Type" => "application/json") }
    let(:id) { Phlex::Reactive.sign_fragment(panel_payload) }

    it "400s as an action token, wrapped or unwrapped" do
      [id, Base64.urlsafe_decode64(id)].each do
        post Phlex::Reactive.action_path, params: { token: it, act: "__materialize", params: {} }.to_json,
          headers: json_headers
        expect(response).to have_http_status(:bad_request)
      end
    end

    it "400s as a defer token, wrapped or unwrapped" do
      [id, Base64.urlsafe_decode64(id)].each do
        post Phlex::Reactive.defer_path, params: { token: it }.to_json, headers: json_headers
        expect(response).to have_http_status(:bad_request)
      end
    end
  end

  describe "a read with no side effects" do
    it "answers GET only" do
      url = panel_url

      expect(Rails.application.routes.recognize_path(url, method: :get))
        .to include(controller: "phlex/reactive/fragments", action: "show")
      routable = %i[post put patch delete].select do
        Rails.application.routes.recognize_path(url, method: it)
      rescue ActionController::RoutingError
        false
      end
      expect(routable).to be_empty
    end

    it "runs no around_action wrapper and opens no action" do
      calls = []
      original = Phlex::Reactive.around_actions.dup
      Phlex::Reactive.around_action { |_component, _action, &block| calls << :wrapped and block.call }
      events = []
      sub = ActiveSupport::Notifications.subscribe("action.phlex_reactive") { |*args| events << args.last }

      get_fragment

      expect(response).to have_http_status(:ok)
      expect(calls).to be_empty
      expect(events).to be_empty
    ensure
      ActiveSupport::Notifications.unsubscribe(sub) if sub
      Phlex::Reactive.around_actions.replace(original) if original
    end
  end

  describe "a render that embeds a form authenticity token" do
    it "still renders, but is NOT cacheable (a cached token outlives its session) and says so" do
      logged = []
      allow(Rails.logger).to receive(:warn) { logged << it }

      get_fragment(panel_url({ "c" => "CachedFormComponent", "s" => { "label" => "go" } }))

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('name="authenticity_token"')
      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(logged.join).to include("CachedFormComponent").and include("authenticity token")
    end
  end
end
