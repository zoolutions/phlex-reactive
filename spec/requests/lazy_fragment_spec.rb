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

  # A fragment id exactly as the release before #306 minted it.
  def legacy_fragment_id(payload)
    token = Phlex::Reactive.verifier.generate(payload.merge("v" => Phlex::Reactive::TOKEN_VERSION),
      purpose: Phlex::Reactive::Fragment::PURPOSE)
    Base64.urlsafe_encode64(token, padding: false)
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

  # Issue #306: a page or fragment URL minted before the id format changed may
  # still be cached in a browser — it keeps loading.
  describe "a URL minted in the previous id format" do
    it "renders, and stays privately cacheable" do
      get_fragment("#{Phlex::Reactive.fragment_path}/#{legacy_fragment_id(panel_payload)}")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("panel:mine")
      expect(response.headers["Cache-Control"]).to eq("max-age=600, private")
    end

    it "renders for the session, but is not stored, when it names a viewer with the old 32-hex u" do
      cookies[:viewer] = "alice"
      old_u = Digest::SHA256.hexdigest("anything")[0, 32]
      get_fragment("#{Phlex::Reactive.fragment_path}/#{legacy_fragment_id(menu_payload)}?u=#{old_u}")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("menu:")
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end
  end

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

    # The flash is committed by Rails AFTER the action returns, so the decision
    # commits it first: a flash this request wrote must reach the next request,
    # and one this request consumed must be swept — neither on a cached reply.
    describe "the flash" do
      def flash_seen
        cookies[:viewer] = "flash_reader"
        get_fragment
        JSON.parse(response.headers["X-Dummy-Flash"])
      end

      %w[flasher flasher_after].each_with_index do |writer, _index|
        it "keeps a flash a #{writer == "flasher" ? "before" : "after"} filter set, and is then not cacheable" do
          cookies[:viewer] = writer
          get_fragment

          expect(response).to have_http_status(:ok)
          expect(response.headers["Cache-Control"]).to eq("no-store")
          expect(response.headers["Set-Cookie"].to_s).to include("_dummy_session")
          expect(flash_seen).to eq("alert" => "x")
        end
      end

      it "sweeps a pending flash this request read — once — and is then not cacheable" do
        cookies[:viewer] = "flasher"
        get_fragment

        expect(flash_seen).to eq("alert" => "x")
        expect(response.headers["Cache-Control"]).to eq("no-store")
        expect(flash_seen).to eq({})
        expect(response.headers["Cache-Control"]).to eq("max-age=600, private")
      end

      # A flash set by an ordinary action is waiting for the next PAGE view. A
      # fragment GET in between, with nothing in the app reading the flash,
      # must leave it alone — the endpoint itself never loads it.
      def set_pending_flash
        cookies[:viewer] = "flasher"
        get_fragment
        cookies[:viewer] = "someone" # no longer the flasher: an ordinary viewer
      end

      it "leaves a pending flash nobody read: cacheable, no Set-Cookie, and the flash survives" do
        set_pending_flash

        get_fragment

        expect(response).to have_http_status(:ok)
        expect(response.headers["Cache-Control"]).to eq("max-age=600, private")
        expect(response.headers["Set-Cookie"]).to be_blank
        expect(flash_seen).to eq("alert" => "x")
      end

      it "leaves it through a 304 revalidation too" do
        get_fragment
        etag = response.headers["ETag"]
        set_pending_flash

        get_fragment(extra_headers: { "If-None-Match" => etag })

        expect(response).to have_http_status(:not_modified)
        expect(response.headers["Cache-Control"]).to eq("max-age=600, private")
        expect(response.headers["Set-Cookie"]).to be_blank
        expect(flash_seen).to eq("alert" => "x")
      end

      it "leaves it in the viewer mode" do
        set_pending_flash
        cookies[:viewer] = "alice"

        get_fragment(menu_url(viewer: "alice"))

        expect(response.headers["Cache-Control"]).to eq("max-age=600, private")
        expect(response.headers["Set-Cookie"]).to be_blank
        expect(flash_seen).to eq("alert" => "x")
      end

      it "stays cacheable, with no Set-Cookie, for flash.now" do
        get "/lazy_stats"
        cookies[:viewer] = "flash_now"
        get_fragment

        expect(response.headers["Cache-Control"]).to eq("max-age=600, private")
        expect(response.headers["Set-Cookie"]).to be_blank
      end
    end

    # Like the flash, a CSRF token minted in a callback is only stored when Rails
    # commits the session, AFTER the controller returns. It is committed before
    # the decision, so the token survives and the minting reply is not stored.
    describe "a CSRF token minted in a controller callback" do
      # The session's real token behind a masked one (Rails XORs it with a
      # one-time pad): equal across requests only if the token was persisted.
      def real_token(masked)
        raw = Base64.urlsafe_decode64(masked)
        pad = raw[0, raw.size / 2].bytes
        raw[(raw.size / 2)..].bytes.zip(pad).map { |a, b| a ^ b }.pack("C*")
      end

      %w[csrf_before csrf_after].each_with_index do |minter, _index|
        it "keeps the token a #{minter.delete_prefix("csrf_")} filter minted; only that reply is not cacheable" do
          cookies[:viewer] = minter
          get_fragment
          first = response.headers["X-CSRF-Token"]

          expect(response).to have_http_status(:ok)
          expect(response.headers["Cache-Control"]).to eq("no-store")
          expect(response.headers["Set-Cookie"].to_s).to include("_dummy_session")

          get_fragment

          expect(real_token(response.headers["X-CSRF-Token"])).to eq(real_token(first))
          expect(response.headers["Cache-Control"]).to eq("max-age=600, private")
          expect(response.headers["Set-Cookie"]).to be_blank
        end
      end

      [true, false].each_with_index do |protection, _index|
        it "mints nothing on a plain GET with forgery protection #{protection ? "on" : "off"}" do
          original = ActionController::Base.allow_forgery_protection
          ActionController::Base.allow_forgery_protection = protection
          get_fragment

          expect(response.headers["Cache-Control"]).to eq("max-age=600, private")
          expect(response.headers["Set-Cookie"]).to be_blank
        ensure
          ActionController::Base.allow_forgery_protection = original
        end
      end

      # The cookie storage strategy writes the token to the COOKIE JAR at commit.
      describe "with the cookie CSRF storage strategy" do
        around do
          original = ActionController::Base.csrf_token_storage_strategy
          ActionController::Base.csrf_token_storage_strategy =
            ActionController::RequestForgeryProtection::CookieStore.new
          it.run
        ensure
          ActionController::Base.csrf_token_storage_strategy = original
        end

        it "is not cacheable when a filter handed out a token, and the cookie is sent" do
          cookies[:viewer] = "csrf_after"
          get_fragment

          expect(response).to have_http_status(:ok)
          expect(response.headers["Cache-Control"]).to eq("no-store")
          expect(response.headers["Set-Cookie"].to_s).to include("csrf_token=")
        end

        it "stays cacheable on a plain GET" do
          get_fragment

          expect(response.headers["Cache-Control"]).to eq("max-age=600, private")
          expect(response.headers["Set-Cookie"]).to be_blank
        end
      end
    end

    # A token minted INSIDE the render comes from the gem's memoized view
    # context and its synthetic request, so it never touches THIS request's
    # session — on the fragment endpoint as on the defer endpoint.
    it "does not write the session for a token minted inside the render (same as the defer endpoint)" do
      todo = Todo.create!(title: "t", done: false)
      post Phlex::Reactive.defer_path,
        params: { token: Phlex::Reactive.sign_defer({ "c" => "CsrfFormComponent", "gid" => todo.to_gid.to_s }) }.to_json,
        headers: headers.merge("Content-Type" => "application/json")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('name="authenticity_token"')
      expect(response.headers["Set-Cookie"]).to be_blank

      get_fragment(panel_url({ "c" => "CachedFormComponent", "s" => { "label" => "go" } }))
      expect(response.body).to include('name="authenticity_token"')
      expect(response.headers["Set-Cookie"]).to be_blank
    end

    # The fragment's ETag is its body, nothing else: the controller's `etag {}`
    # blocks (and Rails' own flash etagger, which would load and sweep the
    # flash) are deliberately not applied.
    it "does not mix the base controller's etag {} blocks into the ETag" do
      original = ActionController::Base.etaggers
      ActionController::Base.etag { request.headers["X-Dummy-Etag"] }
      get_fragment(extra_headers: { "X-Dummy-Etag" => "one" })
      first = response.headers["ETag"]
      get_fragment(extra_headers: { "X-Dummy-Etag" => "two" })

      expect(first).to be_present
      expect(response.headers["ETag"]).to eq(first)
    ensure
      ActionController::Base.etaggers = original
    end

    # The app can TIGHTEN the policy from a before or an after filter — a
    # shorter max-age, must-revalidate, or no caching at all — and never loosen
    # it: public, s-maxage, stale-while-revalidate and a longer max-age are
    # overridden.
    {
      "expires_in_5" => "max-age=5, private",
      "must_revalidate" => "max-age=600, private, must-revalidate",
      "raw_short" => "max-age=30, private, must-revalidate",
      "raw_twice" => "max-age=5, private",
      "expires_in_0" => "no-store",
      "raw_zero" => "no-store",
      "negative" => "no-store",
      "raw_negative" => "no-store",
      "long_public" => "max-age=600, private",
      "shared" => "max-age=600, private"
    }.to_a.product(%w[Before After]).each do |(policy, expected), filter|
      it "answers #{expected.inspect} when a #{filter.downcase} filter sets #{policy}" do
        get_fragment(extra_headers: { "X-Dummy-#{filter}-Cache" => policy })

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("panel:mine")
        expect(response.headers["Cache-Control"]).to eq(expected)
      end
    end

    describe "with a fragment_cache_max_age_limit of zero (revalidate on every use)" do
      around do
        original = Phlex::Reactive.fragment_cache_max_age_limit
        Phlex::Reactive.fragment_cache_max_age_limit = 0
        it.run
      ensure
        Phlex::Reactive.fragment_cache_max_age_limit = original
      end

      it "answers max-age=0, private on its own" do
        get_fragment

        expect(response.headers["Cache-Control"]).to eq("max-age=0, private")
      end

      it "is still no-store when the app's filter asked for max-age=0 as well" do
        %w[Before After].each do
          get_fragment(extra_headers: { "X-Dummy-#{it}-Cache" => "expires_in_0" })

          expect(response.headers["Cache-Control"]).to eq("no-store")
        end
      end
    end

    # A filter that forbids caching wins.
    it "honours a before_action that forbids caching (no_store)" do
      cookies[:viewer] = "no_store"
      get_fragment

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("panel:mine")
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end

    it "honours an after_action that calls expires_now" do
      cookies[:viewer] = "expires_now_after"
      get_fragment

      expect(response).to have_http_status(:ok)
      expect(response.headers["Cache-Control"]).to eq("no-store")
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

      expect(alice).to match(/[?&]u=[\w-]{22}\z/)
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
    blank_to_param = Class.new { def to_param = "" }.new
    [
      nil, "", "   ", false, [], [nil, 5], ["", "en"],
      [[nil]], [1, [nil]], {}, { user: nil }, { user: 1, tenant: "" }, [{ user: nil }], blank_to_param,
      Set[nil, "en"], Struct.new(:id, :locale).new(nil, "en"), [nil, 1].each, { nil => 1 }
    ].each_with_index do |blank, _index|
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
      [0, "alice", [7, "en"], { user: 7 }, [1, [2]], Set[7, "en"], Struct.new(:id, :locale).new(7, "en")].each do
        CachedProbeComponent.viewer = it
        url = probe_shell_url
        get_fragment(url)

        expect(url).to match(/[?&]u=[\w-]{22}\z/)
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

    it "400s an id whose class was swapped (the MAC covers it)" do
      id = Phlex::Reactive.sign_fragment(panel_payload)
      data = Base64.urlsafe_decode64(id[0...-22]).sub("CachedPanelComponent", "CachedMenuComponent")
      get_fragment("#{Phlex::Reactive.fragment_path}/#{Base64.urlsafe_encode64(data, padding: false)}#{id[-22..]}")

      expect_no_store(:bad_request)
    end

    it "400s a previous-format id whose class was swapped (the signature covers it)" do
      token = Base64.urlsafe_decode64(legacy_fragment_id(panel_payload))
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

    # The previous id format wrapped the verifier's own token; it must not
    # resolve there either, wrapped or unwrapped.
    let(:legacy) do
      Phlex::Reactive.verifier.generate(panel_payload.merge("v" => Phlex::Reactive::TOKEN_VERSION),
        purpose: Phlex::Reactive::Fragment::PURPOSE)
    end

    it "400s as an action token, in either format" do
      [id, legacy, Base64.urlsafe_encode64(legacy, padding: false)].each do
        post Phlex::Reactive.action_path, params: { token: it, act: "__materialize", params: {} }.to_json,
          headers: json_headers
        expect(response).to have_http_status(:bad_request)
      end
    end

    it "400s as a defer token, in either format" do
      [id, legacy, Base64.urlsafe_encode64(legacy, padding: false)].each do
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

    it "detects a field named by a custom request_forgery_protection_token" do
      original = ActionController::Base.request_forgery_protection_token
      ActionController::Base.request_forgery_protection_token = :my_token
      get_fragment(panel_url({ "c" => "CachedProbeComponent", "s" => { "markup" => "custom" } }))

      expect(response.body).to include("t0ken")
      expect(response.headers["Cache-Control"]).to eq("no-store")
    ensure
      ActionController::Base.request_forgery_protection_token = original
    end

    it "does not treat that name as a token when it is not the configured one" do
      get_fragment(panel_url({ "c" => "CachedProbeComponent", "s" => { "markup" => "custom" } }))

      expect(response.headers["Cache-Control"]).to eq("max-age=600, private")
    end

    it "still caches a render without one" do
      get_fragment(panel_url({ "c" => "CachedProbeComponent", "s" => { "markup" => nil } }))

      expect(response.headers["Cache-Control"]).to eq("max-age=600, private")
    end
  end
end
