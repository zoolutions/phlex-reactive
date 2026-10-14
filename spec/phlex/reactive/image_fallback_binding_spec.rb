# frozen_string_literal: true

require "spec_helper"
require "phlex"

# Issue #383: reactive_image_fallback — mark an <img> that fails to load (and
# hide it, or show its alt in a node), and recover when its src changes.
# The wire carries flags and a selector only, never a URL.
RSpec.describe Phlex::Reactive::Component::ImageFallbackBinding do
  let(:klass) do
    Class.new(Phlex::HTML) do
      include Phlex::Reactive::ClientBindings

      def self.name = "BankLogo"

      def view_template
        div(**reactive_root) do
          input(name: "rib")
          img(id: "logo", alt: "", **reactive_media(from: :rib, take: 3, pool: { "007" => "#bank-007" },
            **reactive_image_fallback(hide: true)))
          img(id: "bank-007", src: "/banks/007.svg", alt: "Attijariwafa", hidden: true)
        end
      end
    end
  end

  let(:view) { klass.new }

  def wire(attrs) = JSON.parse(attrs[:data][:reactive_image_fallback])

  it "hides on error by default" do
    expect(wire(view.reactive_image_fallback)).to eq("hide" => true)
  end

  it "carries hide: false (the state attribute only, for CSS)" do
    expect(wire(view.reactive_image_fallback(hide: false))).to eq("hide" => false)
  end

  it "carries show_alt: as the alt node's selector" do
    expect(wire(view.reactive_image_fallback(show_alt: "#bank-name"))).to eq("hide" => true, "alt" => "#bank-name")
  end

  # Issue #392: wrap: names the box around the img; it rides last, only when given.
  it "carries wrap: as the wrapper's selector" do
    expect(wire(view.reactive_image_fallback(hide: false, wrap: "#badge"))).to eq("hide" => false, "wrap" => "#badge")
    expect(view.reactive_image_fallback(show_alt: "#n", wrap: "#badge")[:data][:reactive_image_fallback])
      .to eq('{"hide":true,"alt":"#n","wrap":"#badge"}')
  end

  it "deep-merges extra attrs (mix), keeping the binding" do
    attrs = view.reactive_image_fallback(class: "logo", data: { testid: "logo" })
    expect(attrs[:class]).to eq("logo")
    expect(attrs[:data]).to include(testid: "logo")
    expect(attrs[:data]).to have_key(:reactive_image_fallback)
  end

  it "composes with reactive_media on one img: both data attributes survive" do
    attrs = view.reactive_media(from: :rib, pool: { "007" => "#bank-007" }, **view.reactive_image_fallback(hide: true))
    expect(attrs[:data].keys).to contain_exactly(:reactive_media, :reactive_image_fallback)
  end

  it "renders onto an img alongside reactive_media" do
    html = view.call
    expect(html).to include("data-reactive-media=")
    expect(html).to include("data-reactive-image-fallback=\"{&quot;hide&quot;:true}\"")
  end

  describe "validation (loud, at render)" do
    it "raises unless hide: is true or false" do
      [nil, "yes", 1, "true"].each do
        hide = it
        expect { view.reactive_image_fallback(hide:) }
          .to raise_error(ArgumentError, /hide: must be true or false/), "expected #{hide.inspect} to raise"
      end
    end

    it "raises on a show_alt: that is not a non-empty selector String" do
      expect { view.reactive_image_fallback(show_alt: :name) }.to raise_error(ArgumentError, /show_alt:/)
      expect { view.reactive_image_fallback(show_alt: " ") }.to raise_error(ArgumentError, /show_alt:/)
    end

    it "raises on the @root sentinel as show_alt: (it would rewrite the whole root's text)" do
      expect { view.reactive_image_fallback(show_alt: "@root") }.to raise_error(ArgumentError, /@root/)
    end

    it "raises on a wrap: that is not a non-empty selector String" do
      [:badge, "", " ", 1, true].each do
        wrap = it
        expect { view.reactive_image_fallback(wrap:) }
          .to raise_error(ArgumentError, /wrap:/), "expected #{wrap.inspect} to raise"
      end
    end

    it "raises on the @root sentinel as wrap: (hiding the whole root is not a fallback)" do
      expect { view.reactive_image_fallback(wrap: "@root") }.to raise_error(ArgumentError, /wrap: @root/)
    end
  end
end
