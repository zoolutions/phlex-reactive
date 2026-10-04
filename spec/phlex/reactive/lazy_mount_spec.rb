# frozen_string_literal: true

require "rails_helper"

# Lazy initial mount (issue #165): `reactive_lazy` makes a component's FIRST
# (page-embedded) render emit a placeholder shell — root id + controller +
# a defer token on the root — and the client fetches the real content through
# the same defer machinery on connect. Every render that goes through the
# reactive machinery (render_component: replies, broadcasts, the defer
# endpoint/job, class stream builders) is REAL — lazy applies ONLY to the
# initial mount, so an action's self-replace never costs two round trips.
RSpec.describe "Phlex::Reactive reactive_lazy" do
  let(:lazy_class) do
    Class.new(ApplicationComponent) do
      include Phlex::Reactive::Streamable
      include Phlex::Reactive::Component

      def self.name = "LazyProbeComponent"
      reactive_state :n
      reactive_lazy

      def initialize(n: 0) = @n = n
      def id = "lazy-probe"
      def deferred_placeholder = "<span>shimmer</span>".html_safe
      def view_template = div(id:, **reactive_attrs) { span { "real:#{@n}" } }
    end
  end

  describe "the initial (page) render" do
    it "emits the shell — id, controller, pending markers, placeholder — NOT the real content" do
      html = lazy_class.new(n: 5).call

      expect(html).to include('id="lazy-probe"')
      expect(html).to include('data-controller="reactive"')
      expect(html).to include('data-reactive-defer-pending="true"')
      expect(html).to include('aria-busy="true"')
      expect(html).to include('class="reactive-defer-placeholder"')
      expect(html).to include("<span>shimmer</span>")
      expect(html).not_to include("real:5")
    end

    # Issue #279: the shell is a reactive root like any other, so it carries the
    # verbose stamp — a page whose ONLY reactive element is a lazy shell still
    # opens the client's verbose gate (its mount fetch is counted).
    it "stamps data-reactive-verbose on the shell only when verbose_errors is on" do
      previous = Phlex::Reactive.verbose_errors
      Phlex::Reactive.verbose_errors = true
      expect(lazy_class.new(n: 5).call).to include('data-reactive-verbose="true"')

      Phlex::Reactive.verbose_errors = false
      expect(lazy_class.new(n: 5).call).not_to include("data-reactive-verbose")
    ensure
      Phlex::Reactive.verbose_errors = previous
    end

    it "carries a defer token on the ROOT that round-trips to the component's identity" do
      html = lazy_class.new(n: 5).call
      raw = html[/data-reactive-defer-token="([^"]+)"/, 1]
      payload = Phlex::Reactive.verify_defer(CGI.unescapeHTML(raw))

      expect(payload["c"]).to eq("LazyProbeComponent")
      expect(payload["s"]).to eq({ "n" => 5 })
    end

    it "renders the built-in empty shell when no deferred_placeholder is defined" do
      bare = Class.new(ApplicationComponent) do
        include Phlex::Reactive::Streamable
        include Phlex::Reactive::Component

        def self.name = "BareLazyComponent"
        reactive_state :n
        reactive_lazy
        def initialize(n: 0) = @n = n
        def id = "bare-lazy"
        def view_template = div(id:, **reactive_attrs) { "real" }
      end

      html = bare.new.call
      expect(html).to include('class="reactive-defer-placeholder"')
      expect(html).not_to include("real")
    end

    it "is inherited by subclasses (Registry ancestry semantics)" do
      subclass = Class.new(lazy_class) { def self.name = "LazySubComponent" }
      expect(subclass.reactive_lazy?).to be(true)
      expect(subclass.new(n: 1).call).not_to include("real:1")
    end

    it "a non-lazy component renders its real template (control)" do
      expect(CounterComponent.new(count: 3).call).to include(">3<")
    end

    it "renders the shell with a configurable tag (tr/li roots — issue #165 review)" do
      # A component whose real root is a <tr> can't ship a <div> shell (invalid
      # inside <tbody>, the parser drops or hoists it). reactive_lazy(tag: :tr)
      # emits the shell as that element.
      row = Class.new(ApplicationComponent) do
        include Phlex::Reactive::Streamable
        include Phlex::Reactive::Component

        def self.name = "LazyRowComponent"
        reactive_state :n
        reactive_lazy tag: :tr
        def initialize(n: 0) = @n = n
        def id = "lazy-row"
        def deferred_placeholder = "loading"
        def view_template = tr(id:, **reactive_attrs) { td { @n.to_s } }
      end

      html = row.new(n: 1).call
      expect(html).to start_with("<tr")
      expect(html).to include('id="lazy-row"')
      expect(html).to include('data-reactive-defer-pending="true"')
      expect(html).not_to include("<div")
    end

    it "defaults the shell tag to :div" do
      expect(lazy_class.new(n: 1).call).to start_with("<div")
    end
  end

  describe "reactive machinery renders are REAL" do
    it "the class stream builder renders the real content (an action's reply never double-fetches)" do
      stream = lazy_class.replace(n: 7)

      expect(stream).to include("real:7")
      expect(stream).not_to include("reactive-defer-placeholder")
    end

    it "to_stream_replace on an instance renders the real content" do
      stream = lazy_class.new(n: 7).to_stream_replace

      expect(stream).to include("real:7")
    end

    it "broadcast renders the real content" do
      captured = nil
      allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to) { |*, html:, **| captured = html }

      lazy_class.broadcast_to("somewhere", replace: { n: 9 })
      expect(captured).to include("real:9")
    end
  end
end
