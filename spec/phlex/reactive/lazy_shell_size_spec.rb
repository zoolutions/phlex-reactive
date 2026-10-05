# frozen_string_literal: true

require "rails_helper"
require "zlib"

# What a cacheable lazy shell costs the page (issue #306). Deferring pays off
# only for a fragment bigger than the shell left in its place, so the shell
# must stay small: a record-less reactive_lazy(on:, cache:) shell that names
# its viewer and version gzips to at most 300 B (672 B before #306).
#
# Measured the way the issue did: SHA256 verifier (the Rails default digest),
# production settings (no verbose stamp), the shell element gzipped alone.
RSpec.describe "the reactive_lazy(on:, cache:) shell's size" do # rubocop:disable RSpec/DescribeClass
  let(:links_panel) do
    Class.new(ApplicationComponent) do
      include Phlex::Reactive::Streamable
      include Phlex::Reactive::Component

      define_singleton_method(:name) { "LinksPanel" }
      reactive_dormant
      reactive_lazy on: "panel:opened", cache: { max_age: 3600 }

      def id = "links-panel"
      def view_template = div(id:) { "links" }
      def deferred_placeholder = "…"
      def reactive_cache_viewer = 1234
      def reactive_cache_version = "links/query-0f1e2d3c4b5a69788796a5b4c3d2e1f0-20261005120000000000"
    end
  end
  let(:html) { links_panel.new.call }

  around do
    verifier = Phlex::Reactive.verifier
    verbose = Phlex::Reactive.verbose_errors
    Phlex::Reactive.verifier = ActiveSupport::MessageVerifier.new("x" * 64, digest: "SHA256")
    Phlex::Reactive.verbose_errors = false
    it.run
  ensure
    Phlex::Reactive.verifier = verifier
    Phlex::Reactive.verbose_errors = verbose
  end

  it "gzips to at most 300 bytes" do
    expect(Zlib.gzip(html).bytesize).to be <= 300
  end

  it "keeps the fragment URL at most 140 bytes" do
    src = CGI.unescapeHTML(html[/data-reactive-defer-src="([^"]+)"/, 1])

    expect(src).to include("?v=").and include("&u=")
    expect(src.bytesize).to be <= 140
  end

  it "carries no identity token" do
    expect(html).not_to include("data-reactive-token-value")
  end
end
