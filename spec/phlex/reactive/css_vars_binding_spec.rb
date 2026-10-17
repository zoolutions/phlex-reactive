# frozen_string_literal: true

require "spec_helper"
require "phlex"

# Issue #417: reactive_css_vars — fields feed CSS custom properties on an
# element, so a preview follows a control with no request. Only numbers ever
# reach CSS: the wire carries the property name, the field name and a unit from
# a fixed list, never a value.
RSpec.describe Phlex::Reactive::Component::CssVarsBinding do
  let(:klass) do
    Class.new(Phlex::HTML) do
      include Phlex::Reactive::ClientBindings

      def self.name = "LightPreview"

      def view_template
        div(**mix(reactive_root(id: "light"), reactive_css_vars(to: "#sample", vars: { "--light" => "light" }))) do
          input(type: "range", name: "light", value: "1")
          img(id: "sample", alt: "", style: "--light: 1; filter: brightness(var(--light, 1))")
        end
      end
    end
  end

  let(:view) { klass.new }

  def wire(attrs) = JSON.parse(attrs[:data][:reactive_css_vars])

  it "emits ONE JSON wire attr with the targets and each property's field" do
    attrs = view.reactive_css_vars(to: "#sample", vars: { "--light" => "light" })
    expect(wire(attrs)).to eq("to" => ["#sample"], "vars" => { "--light" => { "field" => "light" } })
  end

  it "carries a unit from the allowlist, and omits an empty one" do
    attrs = view.reactive_css_vars(to: "#sample", vars: {
      "--turn" => { field: "turn", unit: "deg" },
      "--gap" => { field: :gap, unit: :px },
      "--scale" => { field: "scale", unit: "" }
    })
    expect(wire(attrs)["vars"]).to eq(
      "--turn" => { "field" => "turn", "unit" => "deg" },
      "--gap" => { "field" => "gap", "unit" => "px" },
      "--scale" => { "field" => "scale" }
    )
  end

  it "accepts every unit on the allowlist" do
    %w[px % deg turn ms s em rem fr].each do
      attrs = view.reactive_css_vars(to: "#a", vars: { "--x" => { field: "x", unit: it } })
      expect(wire(attrs)["vars"]["--x"]["unit"]).to eq(it)
    end
  end

  it "takes Symbol field names and Symbol property names" do
    expect(wire(view.reactive_css_vars(to: "#a", vars: { "--light": :light }))["vars"])
      .to eq("--light" => { "field" => "light" })
  end

  it "maps to: :root to the root sentinel, and takes an Array of targets" do
    expect(wire(view.reactive_css_vars(to: :root, vars: { "--x" => "x" }))["to"]).to eq(["@root"])
    expect(wire(view.reactive_css_vars(to: ["#a", :root, ".b"], vars: { "--x" => "x" }))["to"])
      .to eq(["#a", "@root", ".b"])
  end

  it "carries global: true only when set" do
    expect(wire(view.reactive_css_vars(to: "#a", vars: { "--x" => "x" }, global: true))).to include("global" => true)
    expect(wire(view.reactive_css_vars(to: "#a", vars: { "--x" => "x" }))).not_to have_key("global")
  end

  it "deep-merges extra attrs (mix), keeping the binding" do
    attrs = view.reactive_css_vars(to: "#a", vars: { "--x" => "x" }, class: "preview", data: { testid: "p" })
    expect(attrs[:class]).to eq("preview")
    expect(attrs[:data]).to include(testid: "p")
    expect(attrs[:data]).to have_key(:reactive_css_vars)
  end

  it "renders onto the root next to its controller" do
    html = view.call
    expect(html).to include('data-controller="reactive"')
    expect(html).to include("data-reactive-css-vars=")
    expect(html).to include("&quot;--light&quot;")
  end

  describe "validation (loud, at render)" do
    def css_vars(**) = view.reactive_css_vars(**)

    it "raises on an empty or non-Hash vars:" do
      expect { css_vars(to: "#a", vars: {}) }.to raise_error(ArgumentError, /vars:/)
      expect { css_vars(to: "#a", vars: ["--x"]) }.to raise_error(ArgumentError, /vars:/)
      expect { css_vars(to: "#a", vars: nil) }.to raise_error(ArgumentError, /vars:/)
    end

    it "raises on a property name that is not a custom property" do
      ["light", "-light", "--", "--li ght", "--a;b", "--a:b", "--ünï", "--a_b", "", nil].each do
        name = it
        expect { css_vars(to: "#a", vars: { name => "x" }) }
          .to raise_error(ArgumentError, /vars: #{Regexp.escape(name.inspect)} is not a custom property/),
            "expected #{name.inspect} to raise"
      end
    end

    it "accepts a property name of letters, digits and dashes, in any case" do
      expect { css_vars(to: "#a", vars: { "--Light-2" => "x", "---x" => "y" }) }.not_to raise_error
    end

    it "raises on an unknown unit, naming the allowed ones" do
      ["vh", "PX", "px;", "url(", 5].each do
        unit = it
        expect { css_vars(to: "#a", vars: { "--x" => { field: "x", unit: } }) }
          .to raise_error(ArgumentError, /unit:.*px.*deg/), "expected #{unit.inspect} to raise"
      end
    end

    it "raises on a blank or missing field name" do
      [nil, "", "  ", 5].each do
        field = it
        expect { css_vars(to: "#a", vars: { "--x" => field }) }
          .to raise_error(ArgumentError, /field/), "expected #{field.inspect} to raise"
        expect { css_vars(to: "#a", vars: { "--x" => { field: } }) }
          .to raise_error(ArgumentError, /field/), "expected #{field.inspect} to raise"
      end
      expect { css_vars(to: "#a", vars: { "--x" => { unit: "px" } }) }.to raise_error(ArgumentError, /field:/)
    end

    it "raises on a field name the client could not put in a [name=\"…\"] selector" do
      ["a\"b", "a\\b", "a\nb"].each do
        field = it
        expect { css_vars(to: "#a", vars: { "--x" => field }) }
          .to raise_error(ArgumentError, /double quote, backslash, or control character/),
            "expected #{field.inspect} to raise"
      end
    end

    it "raises on an unknown key in a property's Hash" do
      expect { css_vars(to: "#a", vars: { "--x" => { field: "x", scale: 2 } }) }
        .to raise_error(ArgumentError, /scale/)
    end

    it "raises on the same property named twice (a String and a Symbol key)" do
      expect { css_vars(to: "#a", vars: { "--x" => "a", "--x": "b" }) }.to raise_error(ArgumentError, /--x.*twice/)
    end

    it "raises on a target that is not :root or a selector String" do
      [nil, "", "  ", :sample, 5, []].each do
        to = it
        expect { css_vars(to:, vars: { "--x" => "x" }) }
          .to raise_error(ArgumentError, /to:/), "expected #{to.inspect} to raise"
      end
      expect { css_vars(to: ["#a", nil], vars: { "--x" => "x" }) }.to raise_error(ArgumentError, /to:/)
    end
  end
end
