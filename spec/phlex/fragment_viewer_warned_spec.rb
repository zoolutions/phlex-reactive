# frozen_string_literal: true

require "rails_helper"

# The once-per-component reactive_cache_viewer warning (issue #277) keeps its
# behaviour without a Concurrent::Map constant (zoolutions/phlex-reactive#364):
# the warned names live in per-Ractor state (Phlex::Reactive::Store), so no
# constant holds a lock a non-main Ractor could not read.
RSpec.describe Phlex::Reactive::Fragment, "viewer warnings" do
  let(:logged) { [] }

  before do
    allow(Rails.logger).to receive(:warn) { logged << it }
    described_class.reset_viewer_warning!
  end

  after { described_class.reset_viewer_warning! }

  it "warns once per component, naming it and the reason" do
    owner = Class.new { def self.name = "BrokenViewerComponent" }

    3.times { described_class.warn_unusable_viewer(owner, "a Range") }

    expect(logged.size).to eq(1)
    expect(logged.first).to include("BrokenViewerComponent").and include("a Range")
  end

  it "warns again for another component, and again after a reset" do
    first = Class.new { def self.name = "FirstViewerComponent" }
    second = Class.new { def self.name = "SecondViewerComponent" }

    described_class.warn_unusable_viewer(first, "x")
    described_class.warn_unusable_viewer(second, "x")
    described_class.reset_viewer_warning!
    described_class.warn_unusable_viewer(first, "x")

    expect(logged.map do
      it[/\w+ViewerComponent/]
    end).to eq(%w[FirstViewerComponent SecondViewerComponent FirstViewerComponent])
  end

  it "warns once when threads race on the first warning" do
    owner = Class.new { def self.name = "RacedViewerComponent" }

    Array.new(8) { Thread.new { 10.times { described_class.warn_unusable_viewer(owner, "x") } } }.each(&:join)

    expect(logged.size).to eq(1)
  end

  it "keeps the warned names out of constants" do
    expect(described_class.const_defined?(:VIEWER_WARNED, false)).to be(false)
  end

  it "leaves no Concurrent:: reference in lib/ or app/ (concurrent-ruby is not a dependency)" do
    root = File.expand_path("../..", __dir__)
    offenders = Dir[File.join(root, "{lib,app}/**/*.rb")].select { File.read(it).match?(/\bConcurrent::/) }

    expect(offenders.map { it.delete_prefix("#{root}/") }).to eq([])
  end
end
