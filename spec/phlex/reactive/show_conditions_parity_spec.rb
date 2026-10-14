# frozen_string_literal: true

require "spec_helper"
require "json"
require "phlex/reactive/show_conditions"

# Issue #180 Phase A: the Ruby half of the Ruby<->JS parity contract. Every
# vector in spec/fixtures/show_predicate_vectors.json is evaluated through
# ShowConditions.match? here AND through the controller's DNF fold in
# spec/javascript/reactive_show_dnf.test.js. The two evaluators MUST agree on
# every vector — server first-paint `hidden:` and client live-toggle can never
# drift.
# rubocop:disable-next RSpec/DescribeClass -- a fixture-driven contract, not one class
RSpec.describe "ShowConditions parity fixture" do
  vectors = JSON.parse(
    File.read(File.expand_path("../../fixtures/show_predicate_vectors.json", __dir__))
  ).fetch("vectors")

  it "loads a non-trivial number of vectors (the contract is not empty)" do
    expect(vectors.size).to be >= 30
  end

  vectors.each do |vector|
    it "match? agrees with the fixture: #{vector.fetch("name")}" do
      result = Phlex::Reactive::ShowConditions.match?(vector.fetch("groups"), vector.fetch("values"))
      expect(result).to eq(vector.fetch("expect"))
    end
  end
end
