# frozen_string_literal: true

require "spec_helper"

# The gem ships a MINIFIED twin of each client module (rake build:js, via bun)
# and pins it in production. These guards assert the committed artifacts are the
# real, shippable thing — present, smaller than the source, valid ESM that keeps
# the consumer-facing exports and the externalized cross-module imports. The
# byte-for-byte "matches a fresh build" check is the CI `rake build:js_check`
# drift guard; here we assert the SHAPE the browser and the import map rely on.
RSpec.describe "minified client build" do # rubocop:disable RSpec/DescribeClass
  js_dir = File.expand_path("../../app/javascript/phlex/reactive", __dir__)

  # source => minified twin, with the exports a consumer/importmap depends on.
  modules = {
    # The DEFAULT client (issue #275): one file, the core and every feature
    # module bundled. Its own source is a few lines of imports, so its size is
    # measured against everything that is bundled into it.
    "reactive_controller.js" => {
      min: "reactive_controller.min.js",
      bundles: %w[runtime.js features/persist.js features/defer.js features/form.js features/bindings.js features/compute.js
                  features/effects.js features/hints.js features/devtools.js],
      # The default export (the Stimulus controller) plus representative named
      # exports an app registers/overrides — re-exported from the core.
      exports: %w[default registerReactiveActions enableLatencySim],
      # The override seams stay EXTERNAL even in the bundle — emitted as bare
      # specifiers that resolve through the import map, never inlined.
      externals: ["@hotwired/stimulus", "phlex/reactive/confirm", "phlex/reactive/confirm_predicate",
                  "phlex/reactive/compute"]
    },
    # The OPT-IN client: the runtime without the features, which it imports
    # on demand. Its own source is the table of those imports.
    "core.js" => {
      min: "core.min.js",
      bundles: %w[runtime.js],
      # (The latency simulator's exports live in features/devtools for this
      # entry.) The compute and confirm_predicate seams are imported by the
      # compute and bindings feature modules, not by the runtime, so this
      # entry reaches only Stimulus and the confirm seam.
      exports: %w[default registerReactiveActions registerReactiveFeature],
      externals: ["@hotwired/stimulus", "phlex/reactive/confirm"]
    },
    "features/compute.js" => {
      min: "features/compute.min.js",
      exports: %w[connect recompute],
      externals: ["phlex/reactive/compute"]
    },
    "features/bindings.js" => {
      min: "features/bindings.min.js",
      exports: %w[connect confirmMessage],
      externals: ["phlex/reactive/confirm_predicate"]
    },
    "confirm.js" => {
      min: "confirm.min.js",
      exports: %w[confirmResolver setConfirmResolver],
      externals: []
    },
    "compute.js" => {
      min: "compute.min.js",
      exports: %w[computeReducer setComputeReducer],
      externals: []
    }
  }

  # rubocop:disable-next Style/ItBlockParameter
  modules.each do |source_name, spec|
    describe spec[:min] do
      source_path = File.join(js_dir, source_name)
      min_path = File.join(js_dir, spec[:min])
      map_path = "#{min_path}.map"

      it "is committed alongside a linked sourcemap" do
        expect(File).to exist(min_path)
        expect(File).to exist(map_path)
        # (The link is relative to the file, so a features/ module links its basename.)
        expect(File.read(min_path)).to include("sourceMappingURL=#{File.basename(spec[:min])}.map")
      end

      it "is meaningfully smaller than the commented source" do
        sources = [source_name, *spec[:bundles]].sum { |name| File.size(File.join(js_dir, name)) }

        expect(File.size(min_path)).to be < sources / 2
      end

      it "strips the comment prose (the source's block-comment banner is gone)" do
        # Every source module carries a `// ...` banner (after its imports, in
        # the core); minification drops it.
        banner = File.readlines(source_path).find { |line| line.start_with?("// ") }.strip

        expect(banner.length).to be > 20
        expect(File.read(min_path)).not_to include(banner)
      end

      it "keeps the consumer-facing ESM exports" do
        exported = File.read(min_path)[/export\{([^}]*)\}/, 1].to_s
        # bun renames the local binding but preserves the public name: `x as name`.
        spec[:exports].each do |name|
          expect(exported).to match(/\bas #{Regexp.escape(name)}\b|[,{]#{Regexp.escape(name)}[,}]/),
            "expected #{spec[:min]} to export `#{name}`"
        end
      end

      it "keeps cross-module imports external (bare specifiers, not inlined)" do
        contents = File.read(min_path)
        spec[:externals].each do |specifier|
          expect(contents).to include(%(from"#{specifier}")),
            "expected #{spec[:min]} to import `#{specifier}` as an external bare specifier"
        end
      end

      it "embeds the original source in the sourcemap for devtools" do
        map = JSON.parse(File.read(map_path))
        expect(map["version"]).to eq(3)
        expect(map["sources"]).to include(source_name)
        expect(map["sourcesContent"].join).to include(File.readlines(source_path).first.strip)
      end
    end
  end
end
