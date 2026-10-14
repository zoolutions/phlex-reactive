# frozen_string_literal: true

require "spec_helper"
require "phlex"
require "phlex/reactive/show_conditions"

# Issue #395: a term that compares one owned field to ANOTHER — `{ same: :email }`
# — with an optional ASCII-only case fold (`case: :fold`) Ruby and the client
# compute identically (an explicit A-Z replace on both sides).
RSpec.describe Phlex::Reactive::ShowConditions do
  def normalize(**) = described_class.normalize(**)
  def match?(groups, values) = described_class.match?(groups, values)

  describe ".normalize — same: (issue #395)" do
    it "compiles { same: :email } to a same term naming the other field" do
      expect(normalize(if: { confirm_email: { same: :email } }))
        .to eq([[{ "field" => "confirm_email", "same" => "email" }]])
    end

    it "adds fold: true for case: :fold" do
      expect(normalize(if: { confirm_email: { same: :email, case: :fold } }))
        .to eq([[{ "field" => "confirm_email", "same" => "email", "fold" => true }]])
    end

    it "negates the term under unless: (the way unless: negates equals)" do
      expect(normalize(unless: { confirm_email: { same: "email", case: :fold } }))
        .to eq([[{ "field" => "confirm_email", "same" => "email", "fold" => true, "negate" => true }]])
    end

    it "raises on a case: other than :fold" do
      expect { normalize(if: { a: { same: :b, case: :upper } }) }
        .to raise_error(ArgumentError, /case: takes only :fold/)
    end

    it "raises on a blank or non-name same:" do
      [nil, "", "  ", 3].each do
        bad = it # a nested block's `it` is its own (nil) parameter
        expect { normalize(if: { a: { same: bad } }) }
          .to raise_error(ArgumentError, /same: needs the other field's name/)
      end
    end

    it "raises when same: is mixed with another predicate key" do
      expect { normalize(if: { a: { same: :b, length: 3 } }) }
        .to raise_error(ArgumentError, /same: takes only case:/)
    end

    it "raises on case: without same:" do
      expect { normalize(if: { a: { case: :fold } }) }
        .to raise_error(ArgumentError, /Hash value supports/)
    end

    it "names both fields in .fields (first paint needs both values)" do
      expect(described_class.fields(normalize(if: { confirm_email: { same: :email } })))
        .to contain_exactly("confirm_email", "email")
    end

    it "leaves a term without same: unchanged" do
      expect(normalize(if: { a: "x" })).to eq([[{ "field" => "a", "equals" => "x" }]])
    end
  end

  describe ".match? — same: (issue #395)" do
    let(:exact) { normalize(if: { confirm: { same: :email } }) }
    let(:folded) { normalize(if: { confirm: { same: :email, case: :fold } }) }
    let(:differ) { normalize(unless: { confirm: { same: :email, case: :fold } }) }

    it "matches equal values, including an empty pair" do
      expect(match?(exact, { "confirm" => "a@x.test", "email" => "a@x.test" })).to be(true)
      expect(match?(exact, { "confirm" => "", "email" => "" })).to be(true)
      expect(match?(exact, {})).to be(true)
    end

    it "is case-sensitive without case:" do
      expect(match?(exact, { "confirm" => "A@x.test", "email" => "a@x.test" })).to be(false)
    end

    it "folds ASCII A-Z only under case: :fold" do
      expect(match?(folded, { "confirm" => "A@X.TEST", "email" => "a@x.test" })).to be(true)
      expect(match?(folded, { "confirm" => "Ä", "email" => "ä" })).to be(false)
    end

    it "shows the unless: hint while the folded values differ" do
      expect(match?(differ, { "confirm" => "b@x.test", "email" => "a@x.test" })).to be(true)
      expect(match?(differ, { "confirm" => "A@X.TEST", "email" => "a@x.test" })).to be(false)
    end
  end

  describe "first paint through reactive_show / reactive_enable" do
    let(:klass) do
      Class.new(Phlex::HTML) do
        include Phlex::Reactive::ClientBindings

        def self.name = "SameThing"

        def initialize(values) = @values = values
        def reactive_values = @values
      end
    end

    it "computes disabled: from both fields" do
      attrs = klass.new({ email: "a@x.test", confirm: "A@X.test" })
        .send(:reactive_enable, if: { confirm: { same: :email, case: :fold } })
      expect(attrs[:disabled]).to be(false)

      attrs = klass.new({ email: "a@x.test", confirm: "b@x.test" })
        .send(:reactive_enable, if: { confirm: { same: :email, case: :fold } })
      expect(attrs[:disabled]).to be(true)
    end

    it "leaves first paint to the client when reactive_values lacks the other field" do
      attrs = klass.new({ confirm: "x" }).send(:reactive_show, unless: { confirm: { same: :email } })
      expect(attrs).not_to have_key(:hidden)
    end
  end
end
