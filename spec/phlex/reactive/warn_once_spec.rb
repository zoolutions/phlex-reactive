# frozen_string_literal: true

require "rails_helper"

# The once-per-process config warnings (issues #165, #248) are written on the
# request path, so they live in per-Ractor state (Phlex::Reactive::Store), not
# in a module instance variable a non-main Ractor could never write
# (zoolutions/phlex-reactive#364).
RSpec.describe Phlex::Reactive::Store, "config warnings" do
  let(:logged) { [] }

  before do
    allow(Rails.logger).to receive(:warn) { logged << it }
    described_class.table(Phlex::Reactive::Store::WARNINGS_KEY).clear
  end

  after { described_class.table(Phlex::Reactive::Store::WARNINGS_KEY).clear }

  describe "a forced :stream defer transport without the push lane" do
    around do
      original = Phlex::Reactive.defer_transport
      Phlex::Reactive.defer_transport = :stream
      it.run
    ensure
      Phlex::Reactive.defer_transport = original
    end

    before { allow(Phlex::Reactive).to receive(:defer_push_capable?).and_return(false) }

    it "degrades to :fetch and warns once" do
      expect(Array.new(3) { Phlex::Reactive::Defer.resolve_via }).to eq(%i[fetch fetch fetch])
      expect(logged.grep(/defer_transport is :stream/).size).to eq(1)
    end

    it "writes no module instance variable" do
      Phlex::Reactive::Defer.resolve_via

      expect(Phlex::Reactive::Defer.instance_variable_defined?(:@stream_degraded_warned)).to be(false)
    end
  end

  describe "reply.pending without a settle lane" do
    it "warns once and writes no module instance variable" do
      3.times { Phlex::Reactive::Pending.send(:warn_no_lane) }

      expect(logged.grep(/reply\.pending needs the defer PUSH lane/).size).to eq(1)
      expect(Phlex::Reactive::Pending.instance_variable_defined?(:@no_lane_warned)).to be(false)
    end
  end
end
