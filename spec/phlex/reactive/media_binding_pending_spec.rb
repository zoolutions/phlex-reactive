# frozen_string_literal: true

require "spec_helper"
require "phlex"

# Issue #380: reactive_media is PENDING (never blank_label) until the field
# has `take` characters, or while `match:` rejects the key. `match:` is a Ruby
# Regexp emitted as a JS source the client anchors as ^(?:…)$, so Ruby's own
# anchors are dropped and Ruby-only escapes (which JS reads as plain letters)
# are refused at render time. `pending: :keep` leaves the preview alone.
RSpec.describe Phlex::Reactive::Component::MediaBinding do
  let(:view) do
    Class.new(Phlex::HTML) do
      include Phlex::Reactive::ClientBindings

      def self.name = "RibPreview"
    end.new
  end

  let(:pool) { { "007" => "#bank-007" } }

  def wire(**) = JSON.parse(view.reactive_media(from: :rib, take: 3, pool:, **)[:data][:reactive_media])

  describe "match:" do
    it "emits the source without Ruby's \\A and \\z anchors (the client anchors it)" do
      expect(wire(match: /\A\d{3}\z/)["match"]).to eq("\\d{3}")
    end

    it "drops a trailing \\Z too" do
      expect(wire(match: /\A[0-9]{3}\Z/)["match"]).to eq("[0-9]{3}")
    end

    it "emits an unanchored source verbatim" do
      expect(wire(match: /\d+-?\d*/)["match"]).to eq("\\d+-?\\d*")
    end

    it "keeps an escaped backslash before a z (not an anchor)" do
      expect(wire(match: /a\\z/)["match"]).to eq("a\\\\z")
    end

    it "is absent when not given" do
      expect(wire).not_to have_key("match")
    end

    it "raises on a non-Regexp" do
      expect { wire(match: "\\d{3}") }.to raise_error(ArgumentError, /match: must be a Regexp/)
      expect { wire(match: :digits) }.to raise_error(ArgumentError, /match:/)
    end

    it "raises on Regexp options JS would read differently" do
      expect { wire(match: /\d{3}/i) }.to raise_error(ArgumentError, /options/)
      expect { wire(match: /\d{3}/x) }.to raise_error(ArgumentError, /options/)
      expect { wire(match: /\d{3}/m) }.to raise_error(ArgumentError, /options/)
    end

    it "accepts a non-ASCII literal (an encoding flag is not an option JS reads)" do
      expect(wire(match: /\A[àé]{3}\z/)["match"]).to eq("[àé]{3}")
    end

    it "raises on a Ruby-only escape JS would read as a plain letter" do
      %w[\h \H \p{L} \G \R \X \K].each do
        regexp = Regexp.new("#{it}+")
        expect { wire(match: regexp) }.to raise_error(ArgumentError, /#{Regexp.escape(it[0, 2])}/)
      end
    end

    it "raises on a POSIX bracket, a nested class or an intersection (JS reads [ and && literally in a class)" do
      expect { wire(match: /\A[[:digit:]]{3}\z/) }.to raise_error(ArgumentError, /character class/)
      expect { wire(match: /[a[bc]]/) }.to raise_error(ArgumentError, /character class/)
      expect { wire(match: /[a-z&&[^aeiou]]/) }.to raise_error(ArgumentError, /character class/)
    end

    it "accepts an escaped [ inside a class, and a [ or & outside one" do
      expect(wire(match: /[\[\]]&[a&b]/)["match"]).to eq("[\\[\\]]&[a&b]")
    end

    it "raises on a group syntax JS lacks (inline options, atomic groups)" do
      expect { wire(match: /(?i)abc/) }.to raise_error(ArgumentError, /\(\?/)
      expect { wire(match: /(?>ab)/) }.to raise_error(ArgumentError, /\(\?/)
      expect { wire(match: /(?i:ab)/) }.to raise_error(ArgumentError, /\(\?/)
    end

    it "accepts the groups both read alike" do
      expect(wire(match: /(?:a)(?=b)(?!c)(?<=d)(?<!e)(?<n>f)/)["match"]).to eq("(?:a)(?=b)(?!c)(?<=d)(?<!e)(?<n>f)")
    end

    it "raises on a character outside the BMP (the client pattern has no u flag)" do
      expect { wire(match: /\A😀{3}\z/) }.to raise_error(ArgumentError, /U\+FFFF/)
    end

    it "raises on \\A or \\z anywhere but the ends" do
      expect { wire(match: /a\Ab/) }.to raise_error(ArgumentError, /\\A/)
      expect { wire(match: /a\zb/) }.to raise_error(ArgumentError, /\\z/)
    end
  end

  describe "pending:" do
    it "emits keep" do
      expect(wire(pending: :keep)["pending"]).to eq("keep")
      expect(wire(pending: "keep")["pending"]).to eq("keep")
    end

    it "leaves the default (clear) off the wire" do
      expect(wire(pending: :clear)).not_to have_key("pending")
      expect(wire.keys).to eq(%w[field take pool])
    end

    it "raises on anything else" do
      expect { wire(pending: :hide) }.to raise_error(ArgumentError, /pending: must be :clear or :keep/)
      expect { wire(pending: nil) }.to raise_error(ArgumentError, /pending:/)
    end
  end
end
