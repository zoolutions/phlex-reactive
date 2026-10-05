# frozen_string_literal: true

require "spec_helper"

# The system suite drives the REAL browser via vendored copies of the client
# modules under spec/dummy/public/vendor (importmap-pinned in the dummy layout).
# Production ships the MINIFIED build (the engine pins *.min.js), so the browser
# suite must exercise that same minified code — otherwise a minifier-induced bug
# (a mangled name that breaks a Stimulus lifecycle hook, a dropped export) ships
# untested. Each vendored copy is therefore byte-identical to the built .min.js
# under app/javascript, not the commented source. This guard makes drift a hard
# failure — re-sync after `rake build:js`.
RSpec.describe "vendored client modules" do
  root = File.expand_path("../..", __dir__)

  # Each client module the system suite serves from spec/dummy/public/vendor,
  # mapped to the minified build that production actually ships. The vendor
  # filename keeps its bare name (the dummy importmap pins `reactive_controller`
  # -> /vendor/reactive_controller.js); its CONTENT is the minified twin.
  vendored_modules = {
    "reactive_controller.js" => "reactive_controller.min.js",
    "early.js" => "early.min.js",
    "confirm.js" => "confirm.min.js",
    "confirm_predicate.js" => "confirm_predicate.min.js",
    "compute.js" => "compute.min.js",
    "inspect.js" => "inspect.min.js"
  }
  # Feature modules (issue #275) are vendored under features/, one per entry
  # in the engine's list — a new feature is covered without editing this spec.
  vendored_modules.merge!(
    Phlex::Reactive::Engine::CLIENT_FEATURES.to_h { ["features/#{it}.js", "features/#{it}.min.js"] }
  )

  # Explicit block param (not `it`): the block body defines RSpec `it` examples,
  # so naming the param `it` would shadow RSpec's example method.
  vendored_modules.each do |vendor_name, source_name|
    it "#{vendor_name} is byte-identical to the shipped minified build (no drift)" do
      source = File.join(root, "app/javascript/phlex/reactive", source_name)
      vendored = File.join(root, "spec/dummy/public/vendor", vendor_name)

      expect(File.read(vendored)).to eq(File.read(source)),
        "spec/dummy/public/vendor/#{vendor_name} has drifted from the shipped " \
        "minified build app/javascript/phlex/reactive/#{source_name}. Rebuild and " \
        "re-sync (the system suite runs the vendored minified copy):\n\n  " \
        "rake build:js && cp app/javascript/phlex/reactive/#{source_name} " \
        "spec/dummy/public/vendor/#{vendor_name}"
    end
  end
end
