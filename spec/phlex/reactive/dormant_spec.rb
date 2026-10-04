# frozen_string_literal: true

require "rails_helper"

# Dormant roots (issue #274): a root that only matters after a user gesture
# renders data-reactive-dormant="reactive" INSTEAD of data-controller="reactive",
# so the reactive controller is neither mounted nor (when it loads lazily)
# fetched until one of the root's triggers fires. phlex/reactive/early wakes the
# root on that first trigger. A render made for the ACTOR's own reply is awake:
# the client is loaded by then, so there is nothing left to save.
RSpec.describe Phlex::Reactive::Dormant do
  def component_class(name = "DormantProbeComponent", &body)
    Class.new(ApplicationComponent) do
      include Phlex::Reactive::Streamable
      include Phlex::Reactive::Component

      define_singleton_method(:name) { name }
      reactive_state :n
      action :load

      attr_reader :n

      def initialize(n: 0) = @n = n
      def id = "dormant-probe"
      def load = @n += 1

      class_eval(&body) if body
    end
  end

  let(:plain_class) do
    component_class { def view_template = div(**reactive_root) { "n:#{n}" } }
  end

  let(:kwarg_class) do
    component_class { def view_template = div(**reactive_root(dormant: true)) { "n:#{n}" } }
  end

  let(:dsl_class) do
    component_class do
      reactive_dormant
      def view_template = div(**mix(reactive_root, on(:load, event: "panel:opened", once: true))) { "n:#{n}" }
    end
  end

  describe "reactive_root(dormant: true)" do
    it "renders data-reactive-dormant in place of data-controller" do
      html = kwarg_class.new.call

      expect(html).to include('data-reactive-dormant="reactive"')
      expect(html).not_to include("data-controller")
    end

    it "keeps the id and the signed identity token" do
      html = kwarg_class.new(n: 3).call
      token = CGI.unescapeHTML(html[/data-reactive-token-value="([^"]+)"/, 1])

      expect(html).to include('id="dormant-probe"')
      expect(Phlex::Reactive.verify(token)).to include("s" => { "n" => 3 })
    end

    it "differs from the awake root in that one attribute only" do
      awake = plain_class.new(n: 3).call
      dormant = kwarg_class.new(n: 3).call

      expect(dormant.sub('data-reactive-dormant="reactive"', 'data-controller="reactive"')).to eq(awake)
    end

    it "is overridden by an explicit dormant: false on a class that declares reactive_dormant" do
      klass = component_class do
        reactive_dormant
        def view_template = div(**reactive_root(dormant: false))
      end

      expect(klass.new.call).to include('data-controller="reactive"')
    end

    it "keeps another controller mixed onto the root" do
      klass = component_class do
        def view_template = div(**mix(reactive_root(dormant: true), data: { controller: "dropdown" }))
      end
      html = klass.new.call

      expect(html).to include('data-controller="dropdown"')
      expect(html).to include('data-reactive-dormant="reactive"')
    end
  end

  describe "reactive_attrs(dormant: true)" do
    it "renders data-reactive-dormant in place of data-controller" do
      klass = component_class { def view_template = div(id:, **reactive_attrs(dormant: true)) }
      html = klass.new.call

      expect(html).to include('data-reactive-dormant="reactive"')
      expect(html).not_to include("data-controller")
    end
  end

  describe "a non-dormant root" do
    # The exact bytes main renders today: nothing about an awake root moves.
    it "is byte-for-byte unchanged" do
      previous = Phlex::Reactive.verbose_errors
      Phlex::Reactive.verbose_errors = false
      html = plain_class.new(n: 1).call
      token = html[/data-reactive-token-value="([^"]+)"/, 1]

      expect(html).to eq(
        %(<div data-controller="reactive" data-reactive-token-value="#{token}" id="dormant-probe">n:1</div>)
      )
    ensure
      Phlex::Reactive.verbose_errors = previous
    end

    it "leaves the trigger descriptors of a dormant root unchanged too" do
      html = dsl_class.new.call

      expect(html).to match(/data-action="panel:opened-(>|&gt;)reactive#dispatch:once"/)
    end
  end

  describe "reactive_dormant (class-level)" do
    it "makes every root of the component dormant" do
      expect(dsl_class.reactive_dormant?).to be(true)
      expect(dsl_class.new.call).to include('data-reactive-dormant="reactive"')
    end

    it "is false when undeclared" do
      expect(plain_class.reactive_dormant?).to be(false)
    end

    it "is inherited by a subclass" do
      subclass = Class.new(dsl_class)

      expect(subclass.reactive_dormant?).to be(true)
      expect(subclass.new.call).to include('data-reactive-dormant="reactive"')
    end

    it "can be turned off again in a subclass without touching the parent" do
      subclass = Class.new(dsl_class) { reactive_dormant false }

      expect(subclass.reactive_dormant?).to be(false)
      expect(subclass.new.call).to include('data-controller="reactive"')
      expect(dsl_class.reactive_dormant?).to be(true)
    end

    it "rejects anything but true or false" do
      expect { component_class { reactive_dormant :yes } }
        .to raise_error(ArgumentError, /reactive_dormant takes true or false/)
    end
  end

  describe ".awake" do
    it "renders a dormant root awake inside the block, and dormant again after it" do
      inside = described_class.awake { dsl_class.new.call }

      expect(inside).to include('data-controller="reactive"')
      expect(inside).not_to include("data-reactive-dormant")
      expect(dsl_class.new.call).to include('data-reactive-dormant="reactive"')
    end

    it "restores the previous state when the block raises" do
      expect { described_class.awake { raise "boom" } }.to raise_error("boom")
      expect(described_class.awake?).to be(false)
    end

    it "nests" do
      described_class.awake do
        described_class.awake { nil }
        expect(described_class.awake?).to be(true)
      end
    end
  end

  describe ".asleep" do
    it "renders dormant inside an awake block, and restores awake after it" do
      described_class.awake do
        inside = described_class.asleep { dsl_class.new.call }

        expect(inside).to include('data-reactive-dormant="reactive"')
        expect(described_class.awake?).to be(true)
      end
    end

    it "restores awake when the block raises" do
      described_class.awake do
        expect { described_class.asleep { raise "boom" } }.to raise_error("boom")
        expect(described_class.awake?).to be(true)
      end
    end

    it "is a plain yield when nothing is awake" do
      expect(described_class.asleep { :value }).to eq(:value)
      expect(described_class.awake?).to be(false)
    end
  end

  describe "renders outside a reactive request" do
    it "stay dormant in a stream the app builds itself" do
      expect(dsl_class.new.to_stream_replace.to_s).to include('data-reactive-dormant="reactive"')
    end
  end
end
