# frozen_string_literal: true

require "spec_helper"

# Issue #373: copy_media copies src, srcset and alt from an <img> the server
# already rendered onto a preview <img>. The op names two ELEMENTS, never a
# URL: the client reads the URL off the live source element. set_attr of
# `src` stays refused (issue #96).
RSpec.describe Phlex::Reactive::JS do
  subject(:js) { described_class.new }

  describe "#copy_media" do
    it "serializes the target and the source selector" do
      expect(JSON.parse(js.copy_media("#logo", from: "#logo-007").to_json))
        .to eq([["copy_media", { "to" => "#logo", "from" => "#logo-007" }]])
    end

    it "carries no URL: the args are exactly the two selectors" do
      args = js.copy_media("#logo", from: "#logo-007").ops.dig(0, 1)
      expect(args.keys).to eq(%w[to from])
    end

    it "accepts :root on either side and global:" do
      args = JSON.parse(js.copy_media(:root, from: "#a", global: true).to_json).dig(0, 1)
      expect(args).to eq("to" => "@root", "from" => "#a", "global" => true)
      expect(JSON.parse(js.copy_media("#p", from: :root).to_json).dig(0, 1, "from")).to eq("@root")
    end

    it "raises without from:" do
      expect { js.copy_media("#nope") }.to raise_error(ArgumentError, /from/)
    end

    it "raises on a from: that is not :root or a selector string" do
      expect { js.copy_media("#logo", from: nil) }.to raise_error(ArgumentError, /target must be/)
      expect { js.copy_media("#logo", from: :logo) }.to raise_error(ArgumentError, /target must be/)
    end

    it "raises on an empty from:" do
      expect { js.copy_media("#logo", from: "") }.to raise_error(ArgumentError, /copy_media/)
    end

    it "chains like every other op" do
      ops = JSON.parse(js.copy_media("#logo", from: "#a").text("#caption", "A").to_json)
      expect(ops.map(&:first)).to eq(%w[copy_media text])
    end

    it "passes the ops allowlist" do
      expect { described_class.assert_ops_allowed!(js.copy_media("#logo", from: "#a").ops) }.not_to raise_error
    end
  end

  describe "the src refusal (issue #96) stays" do
    it "still raises on set_attr of src" do
      expect { js.set_attr("#logo", "src", "/logos/007.svg") }.to raise_error(ArgumentError, /URL-bearing/)
    end

    it "still raises on a raw ops list that sets src" do
      raw = [["set_attr", { "to" => "#logo", "name" => "src", "value" => "/x.svg" }]]
      expect { described_class.assert_ops_allowed!(raw) }.to raise_error(ArgumentError, /URL-bearing/)
    end
  end
end
