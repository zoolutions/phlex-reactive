# frozen_string_literal: true

require "spec_helper"
require "phlex"

# Issue #319: the bulk-selection helpers — reactive_enable (the sibling of
# reactive_show that flips the element's own `disabled`), reactive_select_all
# (the header box of a checkbox group) and reactive_count (the ticked count as
# text). All client-only: available on ClientBindings, no token.
RSpec.describe Phlex::Reactive::Component::Selection do
  let(:klass) do
    Class.new(Phlex::HTML) do
      include Phlex::Reactive::ClientBindings

      def self.name = "BulkThing"

      attr_writer :values

      def reactive_values = @values

      def view_template
        form(**reactive_root) do
          input(type: "checkbox", **reactive_select_all("ids[]"))
          input(type: "checkbox", name: "ids[]", value: "1")
          span(**reactive_count("ids[]")) { "0" }
          button(**reactive_enable(if: { "ids[]" => { checked: 1.. } })) { "Delete" }
        end
      end
    end
  end

  def view(values = nil)
    klass.new.tap { it.values = values }
  end

  describe "#reactive_enable" do
    it "emits the conditions as ONE DNF wire attr (the reactive_show language)" do
      attrs = view.reactive_enable(if: { "ids[]" => { checked: 1.. } })
      expect(JSON.parse(attrs[:data][:reactive_enable]))
        .to eq("any" => [[{ "field" => "ids[]", "checked_gte" => 1 }]])
    end

    it "takes if_any: and unless: like reactive_show" do
      attrs = view.reactive_enable(if_any: [{ mode: "a" }, { mode: "b" }], unless: { locked: true })
      expect(JSON.parse(attrs[:data][:reactive_enable]))
        .to eq("any" => [
          [{ "field" => "mode", "equals" => "a" }, { "field" => "locked", "not" => "true" }],
          [{ "field" => "mode", "equals" => "b" }, { "field" => "locked", "not" => "true" }]
        ])
    end

    it "paints disabled: true at first paint when reactive_values says nothing is ticked" do
      attrs = view({ "ids[]" => [] }).reactive_enable(if: { "ids[]" => { checked: 1.. } })
      expect(attrs[:disabled]).to be(true)
    end

    it "paints disabled: false when reactive_values has ticked boxes (an Array of checked values)" do
      attrs = view({ "ids[]": %w[3 7] }).reactive_enable(if: { "ids[]" => { checked: 1.. } })
      expect(attrs[:disabled]).to be(false)
    end

    it "accepts an Integer count from reactive_values" do
      attrs = view({ "ids[]" => 2 }).reactive_enable(if: { "ids[]" => { checked: 2 } })
      expect(attrs[:disabled]).to be(false)
    end

    it "leaves disabled unset when reactive_values does not cover the field (the client seeds it)" do
      expect(view.reactive_enable(if: { "ids[]" => { checked: 1.. } })).not_to have_key(:disabled)
      expect(view({ other: 1 }).reactive_enable(if: { "ids[]" => { checked: 1.. } })).not_to have_key(:disabled)
    end

    it "lets an explicit disabled: win over first paint" do
      attrs = view({ "ids[]" => [] }).reactive_enable(if: { "ids[]" => { checked: 1.. } }, disabled: false)
      expect(attrs[:disabled]).to be(false)
    end

    it "merges a per-call values: override over reactive_values" do
      attrs = view({ "ids[]" => [] }).reactive_enable(if: { "ids[]" => { checked: 1.. } }, values: { "ids[]" => %w[1] })
      expect(attrs[:disabled]).to be(false)
    end

    it "mixes extra attrs over the binding" do
      attrs = view.reactive_enable(if: { mode: "x" }, class: "btn", data: { testid: "del" })
      expect(attrs[:class]).to eq("btn")
      expect(attrs[:data]).to include(testid: "del", reactive_enable: a_kind_of(String))
    end

    it "raises with no condition (a dead binding fails at render)" do
      expect { view.reactive_enable }.to raise_error(ArgumentError, /if:, if_any:, or unless:/)
    end
  end

  describe "#reactive_show with checked:" do
    it "paints hidden: from a checked count in reactive_values" do
      expect(view({ "ids[]" => [] }).reactive_show(if: { "ids[]" => { checked: 1.. } })[:hidden]).to be(true)
      expect(view({ "ids[]" => %w[1] }).reactive_show(if: { "ids[]" => { checked: 1.. } })[:hidden]).to be(false)
    end
  end

  describe "#reactive_select_all" do
    it "names the group the header box drives" do
      expect(view.reactive_select_all("ids[]")).to eq(data: { reactive_select_all: "ids[]" })
    end

    it "accepts a Symbol and mixes extra attrs" do
      attrs = view.reactive_select_all(:ids, data: { testid: "all" })
      expect(attrs[:data]).to eq(reactive_select_all: "ids", testid: "all")
    end

    it "raises on a blank group" do
      expect { view.reactive_select_all("") }.to raise_error(ArgumentError, /group/)
      expect { view.reactive_select_all(nil) }.to raise_error(ArgumentError, /group/)
    end

    context "with under: (nested groups, issue #398)" do
      it "adds the group path the header owns, next to the wire name" do
        expect(view.reactive_select_all("perms[]", under: "library.books"))
          .to eq(data: { reactive_select_all: "perms[]", reactive_select_all_under: "library.books" })
      end

      it "accepts a Symbol path and mixes extra attrs" do
        attrs = view.reactive_select_all("perms[]", under: :library, data: { testid: "lib" })
        expect(attrs[:data]).to eq(reactive_select_all: "perms[]", reactive_select_all_under: "library", testid: "lib")
      end

      it "leaves the flat header untouched when under: is nil" do
        expect(view.reactive_select_all("ids[]", under: nil)).to eq(data: { reactive_select_all: "ids[]" })
      end

      it "raises on an empty or blank path" do
        expect { view.reactive_select_all("perms[]", under: "") }.to raise_error(ArgumentError, /under:/)
        expect { view.reactive_select_all("perms[]", under: "  ") }.to raise_error(ArgumentError, /under:/)
      end

      it "raises on a path with an empty or space-padded segment" do
        [".library", "library.", "library..books", " library", "library .books"].each do
          path = it
          expect { view.reactive_select_all("perms[]", under: path) }.to raise_error(ArgumentError, /under:/)
        end
      end

      it "renders the header with no name, so it never posts" do
        nested = Class.new(Phlex::HTML) do
          include Phlex::Reactive::ClientBindings

          def self.name = "NestedThing"

          def view_template
            div(**reactive_root) do
              input(type: "checkbox", **reactive_select_all("perms[]", under: "library"))
              input(type: "checkbox", name: "perms[]", value: "books", data: { reactive_group: "library" })
            end
          end
        end
        html = nested.new.call
        expect(html).to include('<input type="checkbox" data-reactive-select-all="perms[]" ' \
                                'data-reactive-select-all-under="library">')
        expect(html).to include('data-reactive-group="library"')
      end

      it "raises at render for an empty path" do
        broken = Class.new(Phlex::HTML) do
          include Phlex::Reactive::ClientBindings

          def self.name = "BrokenThing"

          def view_template = input(type: "checkbox", **reactive_select_all("perms[]", under: ""))
        end
        expect { broken.new.call }.to raise_error(ArgumentError, /under:/)
      end
    end
  end

  describe "#reactive_count" do
    it "names the group whose ticked count it shows" do
      expect(view.reactive_count("ids[]")).to eq(data: { reactive_count: "ids[]" })
    end

    it "raises on a blank group" do
      expect { view.reactive_count(" ") }.to raise_error(ArgumentError, /group/)
    end
  end

  it "renders end to end with no token and no name on the header box" do
    html = view({ "ids[]" => [] }).call
    expect(html).to include('data-reactive-select-all="ids[]"')
    expect(html).to include('data-reactive-count="ids[]"')
    expect(html).to include("data-reactive-enable=")
    expect(html).to match(/<button[^>]*disabled/)
    expect(html).not_to include("reactive-token-value")
  end
end
