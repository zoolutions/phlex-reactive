# frozen_string_literal: true

require "spec_helper"
require "phlex"
require "phlex/reactive/show_conditions"

# Issue #396: a closed format term — `{ digits: 10, starts_with: "9" }` — that
# accepts only ASCII digits, an exact count or an Integer Range, and an
# optional digit prefix. Not a pattern: starts_with: is digits only. Plus the
# after: gate on reactive_show (hidden until the field has blurred once).
RSpec.describe Phlex::Reactive::ShowConditions do
  def normalize(**) = described_class.normalize(**)
  def match?(groups, values) = described_class.match?(groups, values)

  describe ".normalize — digits: (issue #396)" do
    it "compiles an exact count and a prefix into one term" do
      expect(normalize(if: { code: { digits: 10, starts_with: "9" } }))
        .to eq([[{ "field" => "code", "digits_eq" => 10, "prefix" => "9" }]])
    end

    it "compiles an Integer Range into the range suffixes, in the same term" do
      expect(normalize(if: { code: { digits: 9..11 } }))
        .to eq([[{ "field" => "code", "digits_gte" => 9, "digits_lte" => 11 }]])
      expect(normalize(if: { code: { digits: 4... } })).to eq([[{ "field" => "code", "digits_gte" => 4 }]])
      expect(normalize(if: { code: { digits: ...8 } })).to eq([[{ "field" => "code", "digits_lt" => 8 }]])
    end

    it "negates the whole format under unless:" do
      expect(normalize(unless: { code: { digits: 10, starts_with: "9" } }))
        .to eq([[{ "field" => "code", "digits_eq" => 10, "prefix" => "9", "negate" => true }]])
    end

    it "raises on a starts_with: that is not a string of digits" do
      ["9a", "", " 9", 9, :nine, nil].each do
        bad = it # captured: inside the nested expect { } block, `it` would be that block's own (nil) parameter
        expect { normalize(if: { code: { digits: 10, starts_with: bad } }) }
          .to raise_error(ArgumentError, /starts_with: takes a String of digits/)
      end
    end

    it "raises ArgumentError (not NoMethodError) on a non-name option key" do
      expect { normalize(if: { code: { digits: 10, 1 => "x" } }) }.to raise_error(ArgumentError, /digits:/)
      expect { normalize(if: { code: { same: :email, 1 => "x" } }) }.to raise_error(ArgumentError, /same:/)
    end

    it "raises on a digits: that is not a non-negative Integer or Integer Range" do
      [-1, "10", 1.5, (1.5..2), (nil..nil)].each do
        bad = it
        expect { normalize(if: { code: { digits: bad } }) }.to raise_error(ArgumentError, /digits:/)
      end
    end

    it "raises on starts_with: without digits:, or an unknown key" do
      expect { normalize(if: { code: { starts_with: "9" } }) }.to raise_error(ArgumentError, /needs digits:/)
      expect { normalize(if: { code: { digits: 3, length: 3 } }) }.to raise_error(ArgumentError, /takes only/)
    end
  end

  describe ".match? — digits: (issue #396)" do
    let(:exact) { normalize(if: { code: { digits: 10, starts_with: "9" } }) }
    let(:ranged) { normalize(if: { code: { digits: 9..11 } }) }

    it "matches 10 digits starting with 9, and rejects the rest" do
      expect(match?(exact, { "code" => "9123456789" })).to be(true)
      %w[8123456789 912345678 912345678a].each do
        expect(match?(exact, { "code" => it })).to be(false)
      end
    end

    it "matches 9, 10 or 11 digits for a Range, and rejects letters" do
      expect(%w[123456789 1234567890 12345678901].map { match?(ranged, { "code" => it }) }).to all(be(true))
      expect(match?(ranged, { "code" => "12345678" })).to be(false)
      expect(match?(ranged, { "code" => "abcdefghij" })).to be(false)
    end

    it "counts non-ASCII digits as not digits" do
      expect(match?(normalize(if: { code: { digits: 1 } }), { "code" => "٣" })).to be(false)
    end
  end

  describe "reactive_show(after:) (issue #396)" do
    let(:klass) do
      Class.new(Phlex::HTML) do
        include Phlex::Reactive::ClientBindings

        def self.name = "AfterThing"

        def reactive_values = { code: "12", other: "" }
      end
    end

    let(:instance) { klass.new }

    it "names the condition's one field for after: :blur, and starts hidden" do
      attrs = instance.send(:reactive_show, unless: { code: { digits: 10 } }, after: :blur)
      expect(attrs[:data][:reactive_show_after]).to eq("code")
      expect(attrs[:hidden]).to be(true)
    end

    it "takes the field by name when the condition has several" do
      attrs = instance.send(:reactive_show, if: { code: "1", other: "" }, after: :code)
      expect(attrs[:data][:reactive_show_after]).to eq("code")
    end

    it "raises for after: :blur over several fields, or a field the condition does not name" do
      expect { instance.send(:reactive_show, if: { code: "1", other: "" }, after: :blur) }
        .to raise_error(ArgumentError, /after: :blur needs a condition over one field/)
      expect { instance.send(:reactive_show, if: { code: "1" }, after: :zip) }
        .to raise_error(ArgumentError, /after: :zip is not a field of this condition/)
      expect { instance.send(:reactive_show, if: { code: "1" }, after: 3) }
        .to raise_error(ArgumentError, /after:/)
    end

    it "reads a String after: as a field name, even one called blur" do
      attrs = instance.send(:reactive_show, if: { blur: "1", other: "" }, after: "blur")
      expect(attrs[:data][:reactive_show_after]).to eq("blur")
    end

    it "lets an explicit hidden: win" do
      attrs = instance.send(:reactive_show, if: { code: "1" }, after: :blur, hidden: false)
      expect(attrs[:hidden]).to be(false)
    end

    it "emits no after attr without after: (byte-stable wire)" do
      attrs = instance.send(:reactive_show, if: { code: "1" })
      expect(attrs[:data]).not_to have_key(:reactive_show_after)
    end
  end
end
