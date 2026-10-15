# frozen_string_literal: true

require "rails_helper"

module ContentionSpec
  TOKEN = /data-reactive-token-value="[^"]*"/

  # A render carries a fresh signed token; compare the markup around it.
  def self.same_markup?(renders) = renders.map { it.to_s.gsub(TOKEN, "") }.uniq.one?
end

# Tiers 1 and 2 of conformance-kit (zoolutions/phlex-reactive#364): the hot
# paths under thread contention (Puma) and inside one Async reactor (Falcon).
# Tagged :concurrency so the conformance run (`ractor.test_command`, with pgbus
# present) runs them too: the broadcast examples then go over pgbus, and over
# Action Cable everywhere else.
RSpec.describe "phlex-reactive under contention", :concurrency do # rubocop:disable RSpec/DescribeClass
  same_markup = ContentionSpec.method(:same_markup?)

  context "when rendering a component" do
    let(:subject_call) { -> { CounterComponent.render_component(CounterComponent.new(count: 3)) } }

    it_behaves_like "thread-safe under contention", threads: 8, iterations: 20, consistent: same_markup
    it_behaves_like "fiber-safe under an Async reactor", fibers: 8, iterations: 20, consistent: same_markup
  end

  context "when building a replace stream" do
    let(:subject_call) { -> { CounterComponent.new(count: 5).to_stream_replace } }

    it_behaves_like "thread-safe under contention", threads: 8, iterations: 20, consistent: same_markup
    it_behaves_like "fiber-safe under an Async reactor", fibers: 8, iterations: 20, consistent: same_markup
  end

  context "when signing and verifying an identity token" do
    let(:subject_call) { -> { Phlex::Reactive.verify(Phlex::Reactive.sign({ "c" => "CounterComponent", "s" => { "count" => 1 } })) } }

    it_behaves_like "thread-safe under contention", threads: 8, iterations: 50, consistent: :equal
    it_behaves_like "fiber-safe under an Async reactor", fibers: 8, iterations: 50, consistent: :equal
  end

  context "when coercing params" do
    let(:subject_call) do
      schema = Phlex::Reactive::ParamSchema.compile(count: :integer, tags: [:string], done: :boolean)
      -> { schema.coerce({ "count" => "2", "tags" => %w[a b], "done" => "1" }) }
    end

    it_behaves_like "thread-safe under contention", threads: 8, iterations: 50, consistent: :equal
  end

  context "when resolving a component class's registries for the first time" do
    let(:component) do
      Class.new(ApplicationComponent) do
        include Phlex::Reactive::Component

        reactive_state :n
        action :bump, params: { by: :integer }
      end
    end

    let(:subject_call) do
      klass = component
      -> { [klass.reactive_actions.keys, klass.reactive_state_keys, klass.reactive_state_ivars] }
    end

    it_behaves_like "thread-safe under contention", threads: 8, iterations: 20, consistent: :equal
  end

  context "when broadcasting" do
    let(:subject_call) { -> { CounterComponent.broadcast_to("contention-room", replace: CounterComponent.new(count: 1)) } }

    it_behaves_like "thread-safe under contention", threads: 4, iterations: 10
    it_behaves_like "fiber-safe under an Async reactor", fibers: 4, iterations: 10
  end
end
