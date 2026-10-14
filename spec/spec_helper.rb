# frozen_string_literal: true

# Unit-level helper — no Rails. Loads the library and provides a deterministic
# verifier so identity tokens can be signed/verified without a Rails app.
require "active_support"
require "active_support/core_ext"
require "globalid"
require "phlex/reactive"
require "conformance_kit/rspec"

GlobalID.app = "phlex-reactive-test"

Phlex::Reactive.verifier = ActiveSupport::MessageVerifier.new("phlex-reactive-test-secret")

RSpec.configure do
  it.example_status_persistence_file_path = ".rspec_status"
  it.disable_monkey_patching!

  it.expect_with :rspec do
    it.syntax = :expect
  end

  it.order = :random
  Kernel.srand it.seed
end
