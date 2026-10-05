# frozen_string_literal: true

require "rails_helper"

# The engine auto-wires the client runtime for a host app: it adds the minified
# build to the asset precompile list (so Propshaft/Sprockets fingerprint and
# serve the .min.js AND its .map) and, for importmap apps, pins each module's
# bare specifier to the minified twin. Production ships minified — these guards
# assert the wiring points at the .min.js files, not the commented source.
#
# The dummy app doesn't use importmap-rails (it hand-writes the map in the
# layout), so we exercise the engine initializers directly against faithful
# doubles rather than a booted app — testing what they DO, not their source text.
RSpec.describe Phlex::Reactive::Engine do
  # Runs the named initializer's block, passing `app` as its argument. Rails runs
  # each initializer block with the (app or engine) instance as the block arg —
  # the engine's blocks refer to it as the implicit `it` parameter.
  def run_initializer(name, app)
    init = described_class.initializers.find { it.name == name }
    raise "initializer #{name.inspect} not found" unless init

    init.block.call(app)
  end

  describe "phlex_reactive.assets (precompile)" do
    # A double exposing the `config.assets.{paths,precompile}` surface the
    # initializer touches, plus `root` for the asset path.
    let(:assets) { Struct.new(:paths, :precompile).new([], []) }
    let(:config) { double_config(assets) }
    let(:app) do
      cfg = config
      Class.new do
        define_method(:config) { cfg }
        def root = Pathname.new(File.expand_path("../../..", __dir__))
      end.new
    end

    def double_config(assets)
      Class.new do
        define_method(:assets) { assets }
        def respond_to?(name, *) = name == :assets || super
      end.new
    end

    before { run_initializer("phlex_reactive.assets", app) }

    it "precompiles the minified client modules (not the source)" do
      expect(assets.precompile).to include(
        "phlex/reactive/reactive_controller.min.js",
        "phlex/reactive/confirm.min.js",
        "phlex/reactive/compute.min.js"
      )
    end

    it "precompiles the sourcemaps so devtools can resolve them" do
      expect(assets.precompile).to include(
        "phlex/reactive/reactive_controller.min.js.map",
        "phlex/reactive/confirm.min.js.map",
        "phlex/reactive/compute.min.js.map"
      )
    end

    it "does not precompile the unminified source (it is not served)" do
      expect(assets.precompile).not_to include("phlex/reactive/reactive_controller.js")
    end

    it "precompiles the early-event capture module and its sourcemap (issue #273)" do
      expect(assets.precompile).to include("phlex/reactive/early.min.js", "phlex/reactive/early.min.js.map")
    end

    it "precompiles every feature module and its sourcemap (issue #275)" do
      expect(described_class::CLIENT_FEATURES).to include("persist")
      described_class::CLIENT_FEATURES.each do
        expect(assets.precompile).to include(
          "phlex/reactive/features/#{it}.min.js",
          "phlex/reactive/features/#{it}.min.js.map"
        )
      end
    end

    it "precompiles the opt-in core and its sourcemap (issue #275)" do
      expect(assets.precompile).to include("phlex/reactive/core.min.js", "phlex/reactive/core.min.js.map")
    end

    it "precompiles the effects stylesheet (issue #215)" do
      expect(assets.precompile).to include("phlex/reactive/effects.css")
    end

    it "adds the gem's stylesheets dir to the asset paths" do
      # The initializer resolves paths off the ENGINE root (the gem), not the
      # host app's root — assert against the same base.
      expect(assets.paths).to include(described_class.root.join("app/assets/stylesheets").to_s)
    end
  end

  describe "phlex_reactive.importmap (pins)" do
    # Records pin(name, to:, preload:) calls; stands in for Importmap::Map.
    let(:importmap) do
      Class.new do
        attr_reader :pins

        def initialize = @pins = {}
        def pin(name, to:, preload: false) = @pins[name] = { to:, preload: }
      end.new
    end

    let(:app) do
      map = importmap
      Class.new do
        define_method(:importmap) { map }
        def respond_to?(name, *) = name == :importmap || super
      end.new
    end

    before do
      # The initializer guards on `defined?(::Importmap::Map)`; define a stub so
      # the block runs without depending on importmap-rails being installed.
      stub_const("Importmap::Map", Class.new) unless defined?(Importmap::Map)
      run_initializer("phlex_reactive.importmap", app)
    end

    it "pins the controller's bare specifier to the minified build" do
      expect(importmap.pins["phlex/reactive/reactive_controller"])
        .to eq(to: "phlex/reactive/reactive_controller.min.js", preload: true)
    end

    it "pins phlex/reactive/early to its minified build, preloaded (issue #273)" do
      # Preloaded: it must be running before a lazily loaded controller is, or
      # the triggers it exists to capture are already lost.
      expect(importmap.pins["phlex/reactive/early"]).to eq(to: "phlex/reactive/early.min.js", preload: true)
    end

    it "pins every feature module to its minified build, never preloaded (issue #275)" do
      # Not preloaded: a feature is fetched only by a page whose markup asks
      # for it. A preload would put it back on every page.
      described_class::CLIENT_FEATURES.each do
        expect(importmap.pins["phlex/reactive/features/#{it}"])
          .to eq(to: "phlex/reactive/features/#{it}.min.js", preload: false)
      end
    end

    it "pins the opt-in core to its minified build, not preloaded (issue #275)" do
      # An app that stays on the default client must never fetch it.
      expect(importmap.pins["phlex/reactive/core"]).to eq(to: "phlex/reactive/core.min.js", preload: false)
    end

    it "pins the confirm and compute seams to their minified builds" do
      expect(importmap.pins["phlex/reactive/confirm"][:to]).to eq("phlex/reactive/confirm.min.js")
      expect(importmap.pins["phlex/reactive/compute"][:to]).to eq("phlex/reactive/compute.min.js")
    end
  end

  # The feature list lives in three places that cannot share code: the build
  # script (JS), the engine (pins + precompile) and the controller's table
  # (literal import() calls a bundler must be able to see). They must agree.
  describe "CLIENT_FEATURES (issue #275)" do
    let(:root) { File.expand_path("../..", __dir__) }

    it "matches the feature entries the build script emits" do
      entries = File.read(File.join(root, "scripts/build_client.js"))[/const ENTRIES = \[([^\]]*)\]/, 1]
      built = entries.scan(%r{"features/([^"]+)"}).flatten

      expect(described_class::CLIENT_FEATURES).to match_array(built)
    end

    it "matches the features the controller can import" do
      source = File.read(File.join(root, "app/javascript/phlex/reactive/core.js"))
      imported = source.scan(%r{import\("phlex/reactive/features/([\w-]+)"\)}).flatten

      expect(described_class::CLIENT_FEATURES).to match_array(imported.uniq)
    end

    it "matches the features the default bundle registers" do
      # reactive_controller.js imports every feature statically and hands it to
      # the core. One missing here would be fetched on demand by the default
      # client — the one thing that client must never do.
      source = File.read(File.join(root, "app/javascript/phlex/reactive/reactive_controller.js"))
      imported = source.scan(%r{^import \* as \w+ from "phlex/reactive/features/([\w-]+)"$}).flatten
      registered = source.scan(/^registerReactiveFeature\("([\w-]+)", \w+\)$/).flatten

      expect(imported).to match_array(described_class::CLIENT_FEATURES)
      expect(registered).to eq(imported)
    end

    it "is pinned in each of the dummy app's hand-written import maps" do
      # The dummy has no importmap-rails; a feature missing from a layout's map
      # fails to import in the browser suite only, far from its cause.
      layouts = Dir[File.join(root, "spec/dummy/app/views/layouts/*.html.erb")]

      expect(layouts.size).to be >= 2
      layouts.product(described_class::CLIENT_FEATURES).each do |layout, feature|
        expect(File.read(layout)).to include(%("phlex/reactive/features/#{feature}":)), "#{layout} has no pin for #{feature}"
      end
    end

    it "has a source file for every feature" do
      described_class::CLIENT_FEATURES.each do
        expect(File).to exist(File.join(root, "app/javascript/phlex/reactive/features/#{it}.js"))
      end
    end
  end
end
