# frozen_string_literal: true

require "rails_helper"

# reactive_lazy(cache:) (issue #277): the shell carries a STABLE, signed GET
# URL instead of a per-render defer token, so the browser's private HTTP cache
# can reuse the fragment across page views.
RSpec.describe "reactive_lazy(cache:)" do # rubocop:disable RSpec/DescribeClass
  include ActiveSupport::Testing::TimeHelpers

  def cached_class(name: "LazyCacheProbeComponent", version: :none, **lazy)
    Class.new(ApplicationComponent) do
      include Phlex::Reactive::Streamable
      include Phlex::Reactive::Component

      define_singleton_method(:name) { name }
      reactive_state :n
      reactive_lazy(**lazy)
      define_method(:reactive_cache_version) { version } unless version == :none

      def initialize(n: 0) = @n = n
      def id = "lazy-cache-probe"
      def deferred_placeholder = "<span>shimmer</span>".html_safe
      def view_template = div(id:, **reactive_attrs) { span { "real:#{@n}" } }
    end
  end

  around do
    original = Phlex::Reactive.verbose_errors
    Phlex::Reactive.verbose_errors = true
    it.run
  ensure
    Phlex::Reactive.verbose_errors = original
  end

  def attr_value(html, name)
    CGI.unescapeHTML(html[/ #{name}="([^"]*)"/, 1].to_s)
  end

  def src(html) = attr_value(html, "data-reactive-defer-src")

  describe "the declaration" do
    it "stores max_age in seconds, from an Integer or a Duration" do
      expect(cached_class(cache: { max_age: 600 }).reactive_lazy_cache).to eq(max_age: 600)
      expect(cached_class(cache: { max_age: 10.minutes }).reactive_lazy_cache).to eq(max_age: 600)
    end

    it "is nil without cache:" do
      expect(cached_class(on: "x").reactive_lazy_cache).to be_nil
      expect(LazyStatsComponent.reactive_lazy_cache).to be_nil
      expect(CounterComponent.reactive_lazy_cache).to be_nil
    end

    it "is inherited, and cleared by a subclass that redeclares without it" do
      parent = cached_class(cache: { max_age: 60 })
      expect(Class.new(parent).reactive_lazy_cache).to eq(max_age: 60)
      expect(Class.new(parent) { reactive_lazy }.reactive_lazy_cache).to be_nil
    end

    # Two block params on purpose: a lone one would have to be `it`, which the examples below shadow.
    [nil, 0, -1, "600", 1.5].each_with_index do |bad, _index|
      it "rejects max_age: #{bad.inspect}" do
        expect { cached_class(cache: { max_age: bad }) }.to raise_error(ArgumentError, /max_age: must|max_age must/)
      end
    end

    it "rejects a Duration that is not a whole number of seconds (to_i would truncate it)" do
      expect { cached_class(cache: { max_age: 1.5.seconds }) }.to raise_error(ArgumentError, /max_age/)
      expect { cached_class(cache: { max_age: 0.4.seconds }) }.to raise_error(ArgumentError, /max_age/)
    end

    it "rejects anything but { max_age: }" do
      expect { cached_class(cache: true) }.to raise_error(ArgumentError, /cache:/)
      expect { cached_class(cache: { max_age: 60, public: true }) }.to raise_error(ArgumentError, /cache:/)
    end
  end

  describe "a cached shell (fetch on connect)" do
    subject(:html) { cached_class(cache: { max_age: 600 }).new(n: 5).call }

    it "renders the placeholder with the pending markers and the controller" do
      expect(html).to include('id="lazy-cache-probe"')
      expect(html).to include('class="reactive-defer-placeholder"')
      expect(html).to include('data-controller="reactive"')
      expect(html).to include('data-reactive-defer-pending="true"')
      expect(html).to include("<span>shimmer</span>")
      expect(html).not_to include("real:5")
    end

    it "carries the fragment URL instead of a defer token" do
      expect(html).not_to include("data-reactive-defer-token")
      expect(src(html)).to start_with("/reactive/fragment/")
      expect(src(html)).not_to include("?")
    end

    it "signs the identity payload under the fragment purpose" do
      id = src(html).delete_prefix("/reactive/fragment/")

      expect(id).to match(/\A[A-Za-z0-9_-]+\z/)
      expect(Phlex::Reactive.verify_fragment(id)).to include("c" => "LazyCacheProbeComponent", "s" => { "n" => 5 })
    end

    it "renders the SAME URL on every render, however much later" do
      klass = cached_class(cache: { max_age: 600 })
      first = src(klass.new(n: 5).call)

      travel(3.days) { expect(src(klass.new(n: 5).call)).to eq(first) }
    end

    it "renders a different URL for a different identity" do
      klass = cached_class(cache: { max_age: 600 })

      expect(src(klass.new(n: 5).call)).not_to eq(src(klass.new(n: 6).call))
    end

    it "honours Phlex::Reactive.fragment_path" do
      original = Phlex::Reactive.fragment_path
      Phlex::Reactive.fragment_path = "/_r/frag"
      expect(src(html)).to start_with("/_r/frag/")
    ensure
      Phlex::Reactive.fragment_path = original
    end
  end

  describe "reactive_cache_version" do
    it "adds an opaque v that changes with the version" do
      one = src(cached_class(cache: { max_age: 600 }, version: 1).new.call)
      two = src(cached_class(cache: { max_age: 600 }, version: 2).new.call)

      expect(one).to match(/\?v=\h{16}\z/)
      expect(one).not_to eq(two)
      expect(one.split("?").first).to eq(two.split("?").first)
    end

    it "keeps the same v for the same version" do
      klass = cached_class(cache: { max_age: 600 }, version: "abc")
      first = src(klass.new.call)

      expect(src(klass.new.call)).to eq(first)
    end

    it "tells two Times in the same second apart" do
      base = Time.utc(2026, 10, 4, 12, 0, 0)
      one = src(cached_class(cache: { max_age: 600 }, version: base).new.call)
      two = src(cached_class(cache: { max_age: 600 }, version: base + 0.5).new.call)

      expect(one).not_to eq(two)
    end

    it "omits v when the version is nil" do
      expect(src(cached_class(cache: { max_age: 600 }, version: nil).new.call)).not_to include("?")
    end
  end

  describe "reactive_cache_viewer" do
    def viewer_class(viewer)
      Class.new(cached_class(cache: { max_age: 600 }, version: 7)) do
        define_method(:reactive_cache_viewer) { viewer }
      end
    end

    it "adds an opaque u after v, different per viewer and stable for one" do
      alice = src(viewer_class("alice@example").new.call)

      expect(alice).to match(/\?v=\h{16}&u=\h{32}\z/)
      expect(alice).not_to include("alice@")
      expect(src(viewer_class("alice@example").new.call)).to eq(alice)
      expect(src(viewer_class("bob@example").new.call)).not_to eq(alice)
    end

    # Two block params on purpose: a lone one would have to be `it`, which the examples below shadow.
    [nil, "", " ", false, [], [nil, 1], [[nil]], [1, [nil]], {}, { user: nil }].each_with_index do |blank, _index|
      it "renders no u for a blank viewer (#{blank.inspect}): it names nobody" do
        expect(src(viewer_class(blank).new.call)).not_to include("u=")
      end
    end

    it "treats an endless Enumerator as unnamed instead of walking it" do
      expect(src(viewer_class((1..).each).new.call)).not_to include("u=")
      expect(src(viewer_class([1, 2].cycle).new.call)).not_to include("u=")
    end

    # A viewer is an identity, never a collection to enumerate: no value may
    # make the shell render slow, hang, or raise into the host page.
    describe "values that are not an identity" do
      def shell_for(viewer)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        url = src(viewer_class(viewer).new.call)
        [url, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
      end

      self_referential = [1].tap { it << it }
      returns_itself = Class.new { def to_a = self }.new
      raising = Class.new { def to_a = raise("boom") }.new
      {
        "an endless Range" => (1..),
        "a huge Range" => (1..(10**7)),
        "a huge Array" => Array.new(10_000, 1),
        "a huge Set" => Set.new(1..10_000),
        "a self-referential Array" => self_referential,
        "an object whose to_a returns itself" => returns_itself,
        "an object whose to_a raises" => raising,
        "unpermitted ActionController::Parameters" => ActionController::Parameters.new(user: 1)
      }.each do |label, value|
        it "renders the shell, promptly and with no u, for #{label}" do
          url, seconds = shell_for(value)

          expect(url).to start_with("/reactive/fragment/")
          expect(url).not_to include("u=")
          expect(seconds).to be < 0.5
        end
      end

      it "still names a viewer for a small collection of ids" do
        expect(shell_for((1..3).to_a).first).to include("u=")
        expect(shell_for(Array.new(32, 1)).first).to include("u=")
      end

      # Once per COMPONENT, naming it and the cause: a second broken component
      # must not lose its viewer-keyed caching silently.
      it "logs why once per component, naming the component and the error" do
        logged = []
        allow(Rails.logger).to receive(:warn) { logged << it }
        Phlex::Reactive::Fragment.reset_viewer_warning!
        params = ActionController::Parameters.new(user: 1)
        first = Class.new(viewer_class(params)) { def self.name = "FirstBrokenViewerComponent" }
        second = Class.new(viewer_class(1..)) { def self.name = "SecondBrokenViewerComponent" }

        2.times { first.new.call }
        2.times { second.new.call }

        warnings = logged.grep(/reactive_cache_viewer/)
        expect(warnings.size).to eq(2)
        expect(warnings.first).to include("FirstBrokenViewerComponent").and include("UnfilteredParameters")
        expect(warnings.last).to include("SecondBrokenViewerComponent").and include("Range")
      end
    end

    it "is keyed: not reproducible from the value with a plain digest" do
      u = src(viewer_class(42).new.call)[/u=(\h+)/, 1]
      guesses = ["42", "viewer:42", "phlex-reactive/fragment-viewer:42"].flat_map do
        [Digest::SHA256.hexdigest(it), Digest::SHA1.hexdigest(it), Digest::MD5.hexdigest(it)]
      end

      expect(guesses.map { it[0, 32] }).not_to include(u)
    end

    it "changes with the signing secret" do
      original = Phlex::Reactive.verifier
      one = src(viewer_class(42).new.call)[/u=(\h+)/, 1]
      Phlex::Reactive.verifier = ActiveSupport::MessageVerifier.new("another-secret-" * 4)

      expect(src(viewer_class(42).new.call)[/u=(\h+)/, 1]).not_to eq(one)
    ensure
      Phlex::Reactive.verifier = original
    end

    it "never collides with the version digest of the same value" do
      url = src(viewer_class(7).new.call)

      expect(url[/v=(\h+)/, 1]).not_to eq(url[/u=(\h+)/, 1])
    end

    it "is absent when the component does not declare a viewer" do
      expect(src(cached_class(cache: { max_age: 600 }).new.call)).not_to include("u=")
    end
  end

  describe "combined with on:" do
    it "keeps the event trigger shell and adds the fragment URL" do
      html = cached_class(on: "panel:opened", cache: { max_age: 600 }).new(n: 5).call

      expect(attr_value(html, "data-action")).to eq("panel:opened->reactive#dispatch:once")
      expect(attr_value(html, "data-reactive-lazy-on")).to eq("panel:opened")
      expect(html).to include("data-reactive-token-value")
      expect(html).not_to include("data-reactive-defer-pending")
      expect(src(html)).to start_with("/reactive/fragment/")
    end

    it "keeps the :visible shell and adds the fragment URL" do
      html = cached_class(on: :visible, cache: { max_age: 600 }).new(n: 5).call

      expect(attr_value(html, "data-reactive-lazy-visible")).to eq("0px")
      expect(src(html)).to start_with("/reactive/fragment/")
    end
  end

  # Dormant roots (#274): an event shell goes dormant like any on: shell; a
  # fetch-on-connect shell ignores dormancy, exactly like a plain reactive_lazy
  # shell — it has to mount to fetch.
  describe "combined with reactive_dormant" do
    it "renders a dormant on: + cache: shell that still carries the fragment URL" do
      html = DormantCachedPanelComponent.new(scope: "mine").call

      expect(html).to include('data-reactive-dormant="reactive"')
      expect(html).not_to include("data-controller")
      expect(attr_value(html, "data-action")).to eq("panel:opened->reactive#dispatch:once")
      expect(src(html)).to start_with("/reactive/fragment/")
    end

    it "keeps a fetch-on-connect cached shell mounted (dormancy does not apply to it)" do
      klass = Class.new(cached_class(cache: { max_age: 600 })) { reactive_dormant }
      html = klass.new(n: 1).call

      expect(html).to include('data-controller="reactive"')
      expect(html).not_to include("data-reactive-dormant")
      expect(src(html)).to start_with("/reactive/fragment/")
    end
  end

  describe "without cache: (unchanged, byte for byte)" do
    it "renders the plain shell with a defer token and no fragment URL" do
      html = LazyStatsComponent.new(scope: "week").call
      token = attr_value(html, "data-reactive-defer-token")

      expect(html).to eq(
        '<div id="lazy-stats" class="reactive-defer-placeholder" aria-busy="true" data-controller="reactive" ' \
        'data-reactive-defer-pending="true" data-reactive-verbose="true" ' \
        "data-reactive-defer-token=\"#{CGI.escapeHTML(token)}\">" \
        '<span data-testid="stats-shimmer">…</span></div>'
      )
    end

    it "renders the on: shell with no fragment URL" do
      expect(LazyPanelComponent.new(scope: "mine").call).not_to include("data-reactive-defer-src")
    end
  end

  describe "the fragment id" do
    let(:payload) { { "c" => "LazyStatsComponent", "s" => { "scope" => "week" } } }

    it "is rejected as an identity token and as a defer token" do
      id = Phlex::Reactive.sign_fragment(payload)

      expect(Phlex::Reactive.verify(id)).to be_nil
      expect(Phlex::Reactive.verify(Base64.urlsafe_decode64(id))).to be_nil
      expect(Phlex::Reactive.verify_defer(Base64.urlsafe_decode64(id))).to be_nil
    end

    it "does not accept an identity or defer token" do
      identity = Phlex::Reactive.sign(payload)
      defer = Phlex::Reactive.sign_defer(payload, unbound: true)

      [identity, defer].each do
        expect(Phlex::Reactive.verify_fragment(it)).to be_nil
        expect(Phlex::Reactive.verify_fragment(Base64.urlsafe_encode64(it, padding: false))).to be_nil
      end
    end

    it "is nil for garbage" do
      expect(Phlex::Reactive.verify_fragment("***")).to be_nil
      expect(Phlex::Reactive.verify_fragment(nil)).to be_nil
    end
  end

  describe "fragment_cache_max_age_limit=" do
    around do
      original = Phlex::Reactive.fragment_cache_max_age_limit
      it.run
    ensure
      Phlex::Reactive.fragment_cache_max_age_limit = original
    end

    it "accepts zero, an Integer and a Duration" do
      [0, 90, 2.minutes].each { Phlex::Reactive.fragment_cache_max_age_limit = it }

      expect(Phlex::Reactive.fragment_cache_max_age_limit).to eq(120)
    end

    # Two block params on purpose: a lone one would have to be `it`, which the examples below shadow.
    [-5, -1.second, "600", 1.5, :forever].each_with_index do |bad, _index|
      it "rejects #{bad.inspect}" do
        expect { Phlex::Reactive.fragment_cache_max_age_limit = bad }.to raise_error(ArgumentError, /max_age_limit/)
      end
    end

    it "resets to the default with nil" do
      Phlex::Reactive.fragment_cache_max_age_limit = nil

      expect(Phlex::Reactive.fragment_cache_max_age_limit).to eq(3600)
    end
  end

  describe "the max-age cap" do
    it "answers with the declared value under the limit, and the limit above it" do
      expect(Phlex::Reactive::Fragment.max_age_for(cached_class(cache: { max_age: 600 }))).to eq(600)
      expect(Phlex::Reactive::Fragment.max_age_for(cached_class(cache: { max_age: 1.day }))).to eq(3600)
    end
  end
end
