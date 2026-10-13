# frozen_string_literal: true

require "spec_helper"
require "phlex"

# Issue #373: reactive_media — a binding that watches a field, takes a prefix
# of its value, and copies the pool <img> whose key matches onto the preview.
# Every pool value is a SELECTOR for an <img> the server rendered, never a URL.
RSpec.describe Phlex::Reactive::Component::MediaBinding do
  let(:klass) do
    Class.new(Phlex::HTML) do
      include Phlex::Reactive::ClientBindings

      def self.name = "LogoPreview"

      def view_template
        div(**reactive_root) do
          input(name: "code")
          img(id: "logo", alt: "", **reactive_media(from: :code, take: 3, pool: { "007" => "#logo-007" }))
          img(id: "logo-007", src: "/logos/007.svg", alt: "North", hidden: true)
        end
      end
    end
  end

  let(:view) { klass.new }
  let(:pool) { { "007" => "#logo-007", "011" => "#logo-011" } }

  def wire(attrs) = JSON.parse(attrs[:data][:reactive_media])

  it "emits ONE JSON wire attr with the field, take and pool" do
    attrs = view.reactive_media(from: :code, take: 3, pool:)
    expect(wire(attrs)).to eq("field" => "code", "take" => 3, "pool" => pool)
  end

  it "omits take: when not given (the whole field value is the key)" do
    expect(wire(view.reactive_media(from: :code, pool:))).not_to have_key("take")
  end

  it "stringifies pool keys (an Integer or Symbol key is the same string key)" do
    expect(wire(view.reactive_media(from: :code, pool: { 7 => "#a", b: "#b" }))["pool"])
      .to eq("7" => "#a", "b" => "#b")
  end

  it "carries label: and blank_label: when given" do
    attrs = view.reactive_media(from: :code, pool:, label: "#caption", blank_label: "Unknown")
    expect(wire(attrs)).to include("label" => "#caption", "blank" => "Unknown")
  end

  it "omits the label keys when not given" do
    expect(wire(view.reactive_media(from: :code, pool:)).keys).to eq(%w[field pool])
  end

  it "deep-merges extra attrs (mix), keeping the binding" do
    attrs = view.reactive_media(from: :code, pool:, class: "preview", data: { testid: "logo" })
    expect(attrs[:class]).to eq("preview")
    expect(attrs[:data]).to include(testid: "logo")
    expect(attrs[:data]).to have_key(:reactive_media)
  end

  it "renders onto an img" do
    html = view.call
    expect(html).to include("data-reactive-media=")
    expect(html).to include("&quot;007&quot;:&quot;#logo-007&quot;")
  end

  describe "validation (loud, at render)" do
    it "raises without pool:" do
      expect { view.reactive_media(from: :code) }.to raise_error(ArgumentError, /reactive_media needs pool:/)
    end

    it "raises on an empty or non-Hash pool" do
      expect { view.reactive_media(from: :code, pool: {}) }.to raise_error(ArgumentError, /pool:/)
      expect { view.reactive_media(from: :code, pool: ["#a"]) }.to raise_error(ArgumentError, /pool:/)
    end

    it "raises on a pool value that is not a non-empty selector String" do
      expect { view.reactive_media(from: :code, pool: { "a" => :logo }) }.to raise_error(ArgumentError, /selector/)
      expect { view.reactive_media(from: :code, pool: { "a" => "" }) }.to raise_error(ArgumentError, /selector/)
      expect { view.reactive_media(from: :code, pool: { "a" => nil }) }.to raise_error(ArgumentError, /selector/)
    end

    it "raises unless take: is a positive Integer" do
      [0, -1, 1.5, "3", true, 3..4].each do
        expect { view.reactive_media(from: :code, take: it, pool:) }
          .to raise_error(ArgumentError, /take: must be a positive Integer/), "expected #{it.inspect} to raise"
      end
    end

    it "raises without a field name" do
      expect { view.reactive_media(from: nil, pool:) }.to raise_error(ArgumentError, /from:/)
      expect { view.reactive_media(from: "", pool:) }.to raise_error(ArgumentError, /from:/)
      expect { view.reactive_media(pool:) }.to raise_error(ArgumentError, /from/)
    end

    it "raises on a label: that is not a selector String" do
      expect { view.reactive_media(from: :code, pool:, label: :caption) }.to raise_error(ArgumentError, /label:/)
    end
  end
end
