# frozen_string_literal: true

require "spec_helper"

# Issue #342: check_group ticks or unticks every owned box of a checkbox group
# ("clear selection") and lets the group bindings re-sync. The group name is
# resolved on the client like reactive_select_all's (a bare name takes
# reactive_scope, a bracketed one is used verbatim), so it ships verbatim.
RSpec.describe Phlex::Reactive::JS do
  subject(:js) { described_class.new }

  describe "#check_group" do
    it "serializes a root-targeted op that ticks the group by default" do
      expect(JSON.parse(js.check_group("ids[]").to_json))
        .to eq([["check_group", { "to" => "@root", "group" => "ids[]", "checked" => true }]])
    end

    it "unticks the group with false" do
      expect(JSON.parse(js.check_group("ids[]", false).to_json).dig(0, 1, "checked")).to be(false)
    end

    it "ships a bare (scope-resolved) name verbatim" do
      expect(JSON.parse(js.check_group(:tag_ids).to_json).dig(0, 1, "group")).to eq("tag_ids")
    end

    it "carries global: true for a trigger outside the root that owns the group" do
      expect(JSON.parse(js.check_group("ids[]", false, global: true).to_json).dig(0, 1, "global")).to be(true)
    end

    it "raises on a blank group, like reactive_select_all" do
      expect { js.check_group("") }.to raise_error(ArgumentError, /check_group needs a checkbox group name/)
      expect { js.check_group(" ") }.to raise_error(ArgumentError, /check_group/)
      expect { js.check_group(nil) }.to raise_error(ArgumentError, /check_group/)
    end

    it "raises on a non-boolean checked (a typo must not silently tick)" do
      expect { js.check_group("ids[]", "false") }.to raise_error(ArgumentError, /true or false/)
    end

    it "chains like any op" do
      ops = JSON.parse(js.check_group("ids[]", false).focus("#search").to_json)
      expect(ops.map(&:first)).to eq(%w[check_group focus])
    end
  end
end
