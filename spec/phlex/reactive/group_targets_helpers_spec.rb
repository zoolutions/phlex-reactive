# frozen_string_literal: true

require "spec_helper"
require "phlex"

# Issue #343: cross-root group targets — the root that OWNS a checkbox group
# declares outside, id-allowlisted elements it drives: a count (textContent)
# and an enable (`disabled`). reactive_group_target_attrs gives the outside
# markup its first paint from reactive_values, so it never flashes.
RSpec.describe Phlex::Reactive::Component::Selection do
  let(:klass) do
    Class.new(Phlex::HTML) do
      include Phlex::Reactive::ClientBindings

      def self.name = "GroupTargetsThing"

      attr_writer :values

      def reactive_values = @values

      def view_template
        div(**mix(reactive_root,
          reactive_show_targets("#bar" => { if: { "ids[]" => { checked: 1.. } } }),
          reactive_group_targets("ids[]", count: "#c", enable: { "#b" => 1.. }))) do
          input(type: "checkbox", name: "ids[]", value: "1")
        end
      end
    end
  end

  def view(values = nil)
    klass.new.tap { it.values = values }
  end

  def wire(attrs)
    JSON.parse(attrs[:data][:reactive_group_targets])
  end

  describe "#reactive_group_targets" do
    it "emits the count and enable targets as ONE wire attr keyed by group" do
      attrs = view.reactive_group_targets("ids[]", count: "#bulk-count", enable: { "#bulk-archive" => 1.. })
      expect(wire(attrs)).to eq(
        "ids[]" => {
          "count" => ["#bulk-count"],
          "enable" => { "#bulk-archive" => { "any" => [[{ "field" => "ids[]", "checked_gte" => 1 }]] } }
        }
      )
    end

    it "compiles an Integer enable to an exact count" do
      attrs = view.reactive_group_targets("ids[]", enable: { "#b" => 2 })
      expect(wire(attrs).dig("ids[]", "enable", "#b")).to eq("any" => [[{ "field" => "ids[]", "checked_eq" => 2 }]])
      expect(wire(attrs)["ids[]"]).not_to have_key("count")
    end

    it "takes a full conditions Hash as the enable escape hatch" do
      attrs = view.reactive_group_targets("ids[]", enable: { "#b" => { if: { "ids[]" => { checked: 1.. }, mode: "bulk" } } })
      expect(wire(attrs).dig("ids[]", "enable", "#b")).to eq(
        "any" => [[{ "field" => "ids[]", "checked_gte" => 1 }, { "field" => "mode", "equals" => "bulk" }]]
      )
    end

    it "takes several count targets" do
      attrs = view.reactive_group_targets("ids[]", count: ["#top-count", "#bottom-count"])
      expect(wire(attrs).dig("ids[]", "count")).to eq(["#top-count", "#bottom-count"])
    end

    it "declares several groups in ONE call through the hash form" do
      attrs = view.reactive_group_targets(
        "ids[]" => { count: "#c" },
        "tags[]" => { enable: { "#t" => 1.. } }
      )
      expect(wire(attrs).keys).to eq(["ids[]", "tags[]"])
      expect(wire(attrs).dig("tags[]", "enable", "#t", "any")).to eq([[{ "field" => "tags[]", "checked_gte" => 1 }]])
    end

    it "mixes alongside reactive_root and reactive_show_targets" do
      html = klass.new.call
      expect(html).to include("data-reactive-group-targets=", "data-reactive-show-targets=", 'data-controller="reactive"')
    end

    it "raises on a non-id count selector" do
      expect { view.reactive_group_targets("ids[]", count: ".bulk-count") }
        .to raise_error(ArgumentError, /single ID selector/)
    end

    it "raises on a non-id enable selector" do
      expect { view.reactive_group_targets("ids[]", enable: { "div > #b" => 1.. }) }
        .to raise_error(ArgumentError, /single ID selector/)
    end

    it "raises on a blank group" do
      expect { view.reactive_group_targets(" ", count: "#c") }.to raise_error(ArgumentError, /checkbox group name/)
    end

    it "raises a guided error when the group is left out" do
      expect { view.reactive_group_targets(count: "#c") }.to raise_error(ArgumentError, /needs the group first/)
    end

    it "raises when no target is given" do
      expect { view.reactive_group_targets("ids[]") }.to raise_error(ArgumentError, /count: or enable:/)
    end

    it "raises on an unknown option" do
      expect { view.reactive_group_targets("ids[]", count: "#c", show: "#x") }
        .to raise_error(ArgumentError, /unknown option.*:show/)
    end

    it "raises on an enable value that is not an Integer, Range or conditions Hash" do
      expect { view.reactive_group_targets("ids[]", enable: { "#b" => "two" }) }
        .to raise_error(ArgumentError, /Integer.*Range.*if:/)
    end

    it "raises on an enable conditions Hash with unknown keys" do
      expect { view.reactive_group_targets("ids[]", enable: { "#b" => { when: 1 } }) }
        .to raise_error(ArgumentError, /unknown conditions key.*:when/)
    end
  end

  describe "#reactive_group_target_attrs" do
    it "seeds the count from reactive_values (an Array of the checked values)" do
      expect(view({ "ids[]" => %w[3 7] }).reactive_group_target_attrs("ids[]", :count)).to eq(2)
    end

    it "seeds the count as 0 for an empty or absent group" do
      expect(view({ "ids[]" => [] }).reactive_group_target_attrs("ids[]", :count)).to eq(0)
      expect(view.reactive_group_target_attrs("ids[]", :count)).to eq(0)
    end

    it "computes disabled: for an enable range from reactive_values" do
      expect(view({ "ids[]" => [] }).reactive_group_target_attrs("ids[]", :enable, 1..)).to eq(disabled: true)
      expect(view({ "ids[]" => %w[1] }).reactive_group_target_attrs("ids[]", :enable, 1..)).to eq(disabled: false)
    end

    it "computes disabled: for an exact Integer count" do
      expect(view({ "ids[]" => %w[1 2] }).reactive_group_target_attrs("ids[]", :enable, 2)).to eq(disabled: false)
      expect(view({ "ids[]" => %w[1] }).reactive_group_target_attrs("ids[]", :enable, 2)).to eq(disabled: true)
    end

    it "returns {} for an enable when reactive_values does not cover the group (the client seeds it)" do
      expect(view.reactive_group_target_attrs("ids[]", :enable, 1..)).to eq({})
    end

    it "raises on an unknown kind" do
      expect { view.reactive_group_target_attrs("ids[]", :show) }.to raise_error(ArgumentError, /:count or :enable/)
    end
  end
end
