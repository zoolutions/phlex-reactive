# frozen_string_literal: true

require "spec_helper"
require "phlex"

# Issue #390: reactive_media's when: is a Regexp the client tests against the
# WHOLE field value (before the pool lookup), while the pool key stays the
# take: prefix. It compiles with MediaPattern, the rules match: follows, and a
# refused regexp raises at render naming when:.
RSpec.describe Phlex::Reactive::Component::MediaBinding do
  let(:view) do
    Class.new(Phlex::HTML) do
      include Phlex::Reactive::ClientBindings

      def self.name = "RibPreview"
    end.new
  end

  let(:pool) { { "007" => "#bank-007" } }

  def wire(**) = JSON.parse(view.reactive_media(from: :rib, take: 3, pool:, **)[:data][:reactive_media])

  describe "when:" do
    it "emits the source without Ruby's \\A and \\z anchors (the client anchors it)" do
      expect(wire(when: /\A\d{3,24}\z/)["when"]).to eq("\\d{3,24}")
    end

    it "sits beside match: without changing it" do
      emitted = wire(match: /\A\d{3}\z/, when: /\A\d{3,24}\z/)
      expect(emitted).to include("match" => "\\d{3}", "when" => "\\d{3,24}")
    end

    it "is absent when not given" do
      expect(wire).not_to have_key("when")
      expect(wire.keys).to eq(%w[field take pool])
    end

    it "raises on a non-Regexp, naming when:" do
      expect { wire(when: "\\d+") }.to raise_error(ArgumentError, /reactive_media when: must be a Regexp/)
    end

    it "raises on what MediaPattern refuses, naming when:" do
      expect { wire(when: /\d{3}/i) }.to raise_error(ArgumentError, /reactive_media when: .*options/)
      expect { wire(when: /\h+/) }.to raise_error(ArgumentError, /reactive_media when: .*\\h/)
      expect { wire(when: /[[:digit:]]+/) }.to raise_error(ArgumentError, /reactive_media when: .*character class/)
    end

    it "still names match: when match: is the one refused" do
      expect { wire(match: /\h+/, when: /\d+/) }.to raise_error(ArgumentError, /reactive_media match: /)
    end
  end
end
