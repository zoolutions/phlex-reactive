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

    it "adds Cookie to a Vary the base controller already set, instead of replacing it" do
      get_fragment(extra_headers: { "X-Dummy-Vary" => "Accept-Language" })

      expect(vary).to contain_exactly("Accept-Language", "Cookie")
    end

    it "does not repeat Cookie when the base controller already varies on it" do
      get_fragment(extra_headers: { "X-Dummy-Vary" => "Cookie" })

      expect(vary).to eq(["Cookie"])
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

    # Dormant roots (#274): the client asking for a fragment is loaded and
    # connected, so the real root renders AWAKE — like the defer and
    # __materialize renders — and the stored copy is the awake one.
    it "renders a reactive_dormant component awake, and cacheable" do
      get_fragment(panel_url({ "c" => "DormantCachedPanelComponent", "s" => { "scope" => "mine" } }))

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('target="dormant-cached-panel"')
      expect(response.body).to include('data-controller="reactive"')
      expect(response.body).not_to include("data-reactive-dormant")
      expect(response.headers["Cache-Control"]).to eq("max-age=600, private")
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

    it "does not re-issue an unchanged session: a stored reply must not carry Set-Cookie" do
      get "/lazy_stats" # a page view: the layout's CSRF meta tag creates the session
      expect(response.headers["Set-Cookie"].to_s).to include("_dummy_session")

      get_fragment

      expect(response).to have_http_status(:ok)
      expect(response.headers["Cache-Control"]).to eq("max-age=600, private")
      expect(response.headers["Set-Cookie"]).to be_blank
    end

    it "keeps a session write a base-controller filter made, and is then not cacheable" do
      get "/lazy_stats"
      cookies[:viewer] = "tracked" # the dummy gate stamps session[:seen_at] for this viewer

      get_fragment

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("panel:mine")
      expect(response.headers["Set-Cookie"].to_s).to include("_dummy_session")
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end

    it "is not cacheable when a base-controller filter set ANY cookie (a stored reply must not carry it)" do
      cookies[:viewer] = "cookied" # the dummy gate sets a last_seen cookie for this viewer

      get_fragment

      expect(response).to have_http_status(:ok)
      expect(response.headers["Set-Cookie"].to_s).to include("last_seen=")
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end

    it "is not cacheable when the request's cookie writes cannot be read (fails closed)" do
      allow_any_instance_of(ActionDispatch::Cookies::CookieJar).to receive(:write).and_call_original # rubocop:disable RSpec/AnyInstance
      allow_any_instance_of(ActionDispatch::Cookies::CookieJar) # rubocop:disable RSpec/AnyInstance
        .to receive(:write).with(an_instance_of(Phlex::Reactive::FragmentsController::CookieWrites)).and_raise("unreadable")

      get_fragment

      expect(response).to have_http_status(:ok)
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end

    # The decision is made after ALL callbacks ran — a write from an
    # after_action or the tail of an around_action counts like any other.
    it "keeps a session write an AFTER_ACTION made, and is then not cacheable" do
      get "/lazy_stats"
      cookies[:viewer] = "tracked_after"

      get_fragment

      expect(response).to have_http_status(:ok)
      expect(response.headers["Set-Cookie"].to_s).to include("_dummy_session")
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end

    it "keeps a session write an AROUND_ACTION made after the action, and is then not cacheable" do
      get "/lazy_stats"
      cookies[:viewer] = "tracked_around"

      get_fragment

      expect(response).to have_http_status(:ok)
      expect(response.headers["Set-Cookie"].to_s).to include("_dummy_session")
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end

    it "is not cacheable when an AFTER_ACTION set a cookie" do
      cookies[:viewer] = "cookied_after"

      get_fragment

      expect(response).to have_http_status(:ok)
      expect(response.headers["Set-Cookie"].to_s).to include("left_at=")
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end

    it "is not cacheable when a filter re-set a cookie to the SAME value with a new expiry" do
      cookies[:viewer] = "rolling"
      cookies[:roll] = "same"

      get_fragment

      expect(response).to have_http_status(:ok)
      expect(response.headers["Set-Cookie"].to_s).to include("roll=same")
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end

    it "is not cacheable when a filter deleted a cookie" do
      cookies[:viewer] = "forgetful"
      cookies[:gone] = "x"

      get_fragment

      expect(response).to have_http_status(:ok)
      expect(response.headers["Set-Cookie"].to_s).to include("gone=")
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end

    # The policy is re-asserted after every callback: an inherited after_action
    # must not be able to widen it (public → a shared cache) or drop the Vary.
    it "stays private and bounded when an after_action tried to make the reply public" do
      cookies[:viewer] = "publisher"

      get_fragment

      expect(response).to have_http_status(:ok)
      expect(response.headers["Cache-Control"]).to eq("max-age=600, private")
      expect(response.headers["Cache-Control"]).not_to include("public")
      expect(vary).to include("Cookie")
    end

    it "revalidates (304) without a Set-Cookie when nothing wrote the session" do
      get "/lazy_stats"
      get_fragment
      etag = response.headers["ETag"]

      get_fragment(extra_headers: { "If-None-Match" => etag })

      expect(response).to have_http_status(:not_modified)
      expect(response.headers["Cache-Control"]).to eq("max-age=600, private")
      expect(response.headers["Set-Cookie"]).to be_blank
    end

    it "keeps a session a filter CREATED on a sessionless request, and is then not cacheable" do
      cookies[:viewer] = "tracked"

      get_fragment

      expect(response).to have_http_status(:ok)
      expect(response.headers["Set-Cookie"].to_s).to include("_dummy_session")
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end
  end

  describe "a component that names its viewer (reactive_cache_viewer)" do
    it "keys the URL on the viewer: the same for one viewer, different for another" do
      alice = menu_url(viewer: "alice")

      expect(alice).to match(/[?&]u=\h{32}\z/)
      expect(menu_url(viewer: "alice")).to eq(alice)
      expect(menu_url(viewer: "bob")).not_to eq(alice)
    end

    it "leaves a Vary the base controller set untouched (no Cookie added)" do
      cookies[:viewer] = "alice"
      get_fragment(menu_url(viewer: "alice"), extra_headers: { "X-Dummy-Vary" => "Accept-Language" })

      expect(vary).to eq(["Accept-Language"])
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

    it "falls back to the default mode for an anonymous (nil) viewer: no u, Vary: Cookie" do
      url = menu_url(viewer: nil)
      get_fragment(url)

      expect(url).not_to include("u=")
      expect(response.body).to include("menu:main:guest")
      expect(response.headers["Cache-Control"]).to eq("max-age=600, private")
      expect(vary).to include("Cookie")
    end

    it "is no-store when the URL names a viewer but this session has none" do
      get_fragment(menu_url(viewer: "alice"))

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("menu:main:guest")
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end
  end

  # A blank reactive_cache_viewer names NO viewer. It must never become a shared
  # "anonymous" key: two sessions would then store, and read, each other's
  # render under one URL with no Vary. It falls back to the default mode.
  describe "a blank reactive_cache_viewer (fails closed)" do
    let(:probe_payload) { { "c" => "CachedProbeComponent", "s" => { "markup" => nil } } }

    after { CachedProbeComponent.viewer = nil }

    def probe_shell_url
      CGI.unescapeHTML(CachedProbeComponent.new.call[/data-reactive-defer-src="([^"]+)"/, 1])
    end

    # Two block params on purpose: a lone one would have to be `it`, which the examples below shadow.
    [nil, "", "   ", false, [], [nil, 5], ["", "en"]].each_with_index do |blank, _index|
      it "renders no u for #{blank.inspect}, and two sessions each get a Vary: Cookie reply" do
        CachedProbeComponent.viewer = blank
        url = probe_shell_url
        alice = open_session
        bob = open_session
        alice.cookies[:viewer] = "alice"
        bob.cookies[:viewer] = "bob"

        alice.get url, headers: headers
        bob.get url, headers: headers

        expect(url).not_to include("u=")
        [alice, bob].each do
          expect(it.response).to have_http_status(:ok)
          expect(it.response.headers["Vary"].to_s).to include("Cookie")
        end
        expect(alice.response.body).to include("who:alice")
        expect(bob.response.body).to include("who:bob")
      end
    end

    it "keeps the viewer mode for a present value, including 0 and a full Array" do
      [0, "alice", [7, "en"]].each do
        CachedProbeComponent.viewer = it
        url = probe_shell_url
        get_fragment(url)

        expect(url).to match(/[?&]u=\h{32}\z/)
        expect(response.headers["Cache-Control"]).to eq("max-age=600, private")
        expect(vary).not_to include("Cookie")
      end
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

    it "is no-store when the base controller redirects to sign-in before the endpoint runs" do
      cookies[:viewer] = "redirected"
      get_fragment

      expect_no_store(:found)
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

    # Two block params on purpose: a lone one would have to be `it`, which the examples below shadow.
    %w[single unquoted spaced upper meta].each_with_index do |spelling, _index|
      it "is not fooled by the #{spelling} spelling of the token" do
        get_fragment(panel_url({ "c" => "CachedProbeComponent", "s" => { "markup" => spelling } }))

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("t0ken")
        expect(response.headers["Cache-Control"]).to eq("no-store")
      end
    end

    # The fragment is a REAL render (Defer.with_real_render), so a nested
    # reactive_lazy child renders its template too — no shell, and so no
    # expiring defer token inside a cached copy.
    it "renders a nested reactive_lazy child for real: no shell, no defer token" do
      get_fragment(panel_url({ "c" => "CachedProbeComponent", "s" => { "markup" => "nested" } }))

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("stats:week")
      expect(response.body).not_to include("data-reactive-defer-token")
      expect(response.body).not_to include("reactive-defer-placeholder")
      expect(response.headers["Cache-Control"]).to eq("max-age=600, private")
    end

    it "still caches a render without one" do
      get_fragment(panel_url({ "c" => "CachedProbeComponent", "s" => { "markup" => nil } }))

      expect(response.headers["Cache-Control"]).to eq("max-age=600, private")
    end
  end
end
