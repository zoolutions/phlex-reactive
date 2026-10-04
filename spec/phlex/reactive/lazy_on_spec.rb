# frozen_string_literal: true

require "rails_helper"

# reactive_lazy(on:) (issue #276): the shell waits for an event (or for
# visibility) before fetching the real render. It carries the IDENTITY token
# (no expiry — the defer token's TTL would 400 a page left open) and a
# framework-owned `__materialize` trigger bound once; the endpoint renders the
# real template, which never contains the trigger, so `once` can't re-arm.
RSpec.describe Phlex::Reactive::Component::Lazy do
  def lazy_class(on:, tag: :div)
    Class.new(ApplicationComponent) do
      include Phlex::Reactive::Streamable
      include Phlex::Reactive::Component

      def self.name = "LazyOnProbeComponent"
      reactive_state :n
      reactive_lazy(on:, tag:)

      def initialize(n: 0) = @n = n
      def id = "lazy-on-probe"
      def deferred_placeholder = "<span>shimmer</span>".html_safe
      def view_template = div(id:, **reactive_attrs) { span { "real:#{@n}" } }
    end
  end

  def attr_value(html, name)
    CGI.unescapeHTML(html[/ #{name}="([^"]*)"/, 1].to_s)
  end

  describe "an event-triggered shell" do
    subject(:html) { lazy_class(on: "panel:opened").new(n: 5).call }

    it "renders the placeholder, not the real content" do
      expect(html).to include('id="lazy-on-probe"')
      expect(html).to include('class="reactive-defer-placeholder"')
      expect(html).to include('aria-busy="true"')
      expect(html).to include("<span>shimmer</span>")
      expect(html).not_to include("real:5")
    end

    it "mounts the controller with the IDENTITY token, never a defer token" do
      expect(html).to include('data-controller="reactive"')
      expect(html).not_to include("data-reactive-defer-token")
      expect(html).not_to include("data-reactive-defer-pending")

      payload = Phlex::Reactive.verify(attr_value(html, "data-reactive-token-value"))
      expect(payload).to include("c" => "LazyOnProbeComponent", "s" => { "n" => 5 })
    end

    it "binds the framework-owned __materialize trigger to the event, once" do
      expect(attr_value(html, "data-action")).to eq("panel:opened->reactive#dispatch:once")
      expect(attr_value(html, "data-reactive-action-param")).to eq("__materialize")
      expect(attr_value(html, "data-reactive-params-param")).to eq("{}")
      expect(html).not_to include("data-reactive-lazy-visible")
    end

    it "keeps the configured shell tag" do
      expect(lazy_class(on: "x", tag: :section).new.call).to start_with("<section")
    end
  end

  describe "a visibility-triggered shell" do
    it "on: :visible observes with a 0px margin and binds the reactive:visible trigger" do
      html = lazy_class(on: :visible).new.call

      expect(attr_value(html, "data-reactive-lazy-visible")).to eq("0px")
      expect(attr_value(html, "data-action")).to eq("reactive:visible->reactive#dispatch:once")
      expect(attr_value(html, "data-reactive-action-param")).to eq("__materialize")
    end

    it "on: { visible: margin } carries the rootMargin" do
      html = lazy_class(on: { visible: "200px" }).new.call

      expect(attr_value(html, "data-reactive-lazy-visible")).to eq("200px")
    end
  end

  describe "the DSL" do
    it "exposes the normalized trigger (nil for plain reactive_lazy)" do
      expect(lazy_class(on: "panel:opened").reactive_lazy_trigger).to eq(event: "panel:opened")
      expect(lazy_class(on: :visible).reactive_lazy_trigger).to eq(visible: "0px")
      expect(lazy_class(on: { visible: "10% 0px" }).reactive_lazy_trigger).to eq(visible: "10% 0px")
      # Any CSS whitespace is accepted, normalized to single spaces.
      expect(lazy_class(on: { visible: " 10px \t 20px " }).reactive_lazy_trigger).to eq(visible: "10px 20px")
      expect(LazyStatsComponent.reactive_lazy_trigger).to be_nil
      expect(CounterComponent.reactive_lazy_trigger).to be_nil
    end

    it "is inherited by subclasses" do
      subclass = Class.new(lazy_class(on: "x")) { def self.name = "LazyOnSubComponent" }
      expect(subclass.reactive_lazy_trigger).to eq(event: "x")
      expect(subclass.reactive_lazy_tag).to eq(:div)
    end

    it "rejects an invalid trigger loudly at declaration" do
      bad_triggers = [:click, "", "a b", "x->reactive#boom", "keydown.enter", { visible: "lots" }, { other: 1 }, 42]
      bad_triggers.each do
        # Capture first: a bare `it` inside the nested expect block would bind
        # to THAT block's (nil) argument and test on: nil instead.
        bad = it
        expect { lazy_class(on: bad) }.to raise_error(ArgumentError, /reactive_lazy on:/)
      end
    end

    it "reserves __materialize: it cannot be declared as an action" do
      expect do
        Class.new(ApplicationComponent) do
          include Phlex::Reactive::Component

          action :__materialize
        end
      end.to raise_error(ArgumentError, /reserved/)
    end
  end

  describe "plain reactive_lazy is unchanged" do
    it "still renders the defer-token shell, byte-for-byte" do
      html = LazyStatsComponent.new(scope: "week").call
      token = html[/data-reactive-defer-token="([^"]*)"/, 1]
      expected = %(<div id="lazy-stats" class="reactive-defer-placeholder" aria-busy="true" ) +
                 %(data-controller="reactive" data-reactive-defer-pending="true" ) +
                 %(data-reactive-defer-token="#{token}"><span data-testid="stats-shimmer">…</span></div>)

      expect(html).to eq(expected)
    end
  end

  describe "reactive machinery renders are REAL" do
    it "to_stream_replace renders the real content without the trigger" do
      stream = lazy_class(on: "panel:opened").new(n: 7).to_stream_replace

      expect(stream).to include("real:7")
      expect(stream).not_to include("__materialize")
    end
  end
end
