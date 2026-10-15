# frozen_string_literal: true

require "spec_helper"

# The state phlex-reactive keeps on its own modules and classes is readable
# from a non-main Ractor (Ractor-shareable) and is never written on the
# request path (zoolutions/phlex-reactive#364).
RSpec.describe Phlex::Reactive::Shareable, "the gem's class-level state" do
  concerns = [
    Phlex::Reactive::Streamable, Phlex::Reactive::ClientBindings, Phlex::Reactive::Component,
    Phlex::Reactive::Component::DSL, Phlex::Reactive::Component::Helpers, Phlex::Reactive::Component::Identity,
    Phlex::Reactive::Component::Lazy, Phlex::Reactive::Component::PresenceDeclaration
  ]

  concern_state = %i[@_dependencies @_included_block].freeze

  concerns.each do |concern|
    it "seals ActiveSupport::Concern's bookkeeping on #{concern}" do
      state = concern_state.select { concern.instance_variable_defined?(it) }

      expect(state.reject { Ractor.shareable?(concern.instance_variable_get(it)) }).to eq([])
    end
  end

  it "starts a Streamable class's view-context generation when the class is defined" do
    klass = Class.new { include Phlex::Reactive::Streamable }
    subclass = Class.new(klass)

    generations = [klass, subclass].map { it.instance_variable_get(:@turbo_view_context_generation) }

    expect(generations).to eq([0, 0])
  end

  it "keeps the APM adapter memo out of module instance variables" do
    Phlex::Reactive::APM.detect(:nope)

    expect(Phlex::Reactive::APM.instance_variables).to eq([])
  end

  describe ".share" do
    it "copies plain data deep-frozen and leaves the original alone" do
      original = { "path" => +"/x", list: [+"a", :b] }
      shared = described_class.share(original)

      expect(Ractor.shareable?(shared)).to be(true)
      expect(shared).to eq(original)
      expect([original.frozen?, original["path"].frozen?, original[:list].frozen?]).to eq([false, false, false])
    end

    it "keeps an object it cannot share as it is" do
      verifier = ActiveSupport::MessageVerifier.new("secret")

      expect(described_class.share(verifier)).to be(verifier)
      expect(verifier).not_to be_frozen
    end
  end
end
