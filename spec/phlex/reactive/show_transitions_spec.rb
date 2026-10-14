# frozen_string_literal: true

require "spec_helper"
require "phlex"

# Issue #394: reactive_show(clear:, focus:, scroll:) — work the client does
# when the section CHANGES visibility (never on first paint). clear: names
# owned fields to empty when it hides; focus: a selector inside the root to
# focus when it shows; scroll: true scrolls the section into view then.
RSpec.describe Phlex::Reactive::Component::ShowOptions do
  def build(&template)
    Class.new(Phlex::HTML) do
      include Phlex::Reactive::ClientBindings

      def self.name = "TransitionThing"

      define_method(:view_template, &template)
    end
  end

  let(:instance) { build { div }.new }

  def show(**) = instance.send(:reactive_show, if: { kind: "other" }, **)

  it "emits clear: as a JSON list of field names" do
    expect(show(clear: :notes)[:data][:reactive_show_clear]).to eq('["notes"]')
    expect(show(clear: [:notes, "extra"])[:data][:reactive_show_clear]).to eq('["notes","extra"]')
  end

  it "emits focus: and scroll:" do
    data = show(focus: "#notes", scroll: true)[:data]
    expect(data[:reactive_show_focus]).to eq("#notes")
    expect(data[:reactive_show_scroll]).to eq("true")
  end

  it "emits none of them by default (byte-stable wire)" do
    data = show[:data]
    expect(data.keys).to contain_exactly(:reactive_show)
  end

  it "omits scroll: false" do
    expect(show(scroll: false)[:data]).not_to have_key(:reactive_show_scroll)
  end

  it "raises on a blank or malformed clear:" do
    [[], "", [""], 3, [nil]].each do
      bad = it # a nested block's `it` is its own (nil) parameter
      expect { show(clear: bad) }.to raise_error(ArgumentError, /clear:/)
    end
  end

  it "raises unless focus: is a non-empty CSS selector" do
    ["", "  ", :notes, 3, true].each do
      bad = it
      expect { show(focus: bad) }.to raise_error(ArgumentError, /focus: takes a non-empty CSS selector/)
    end
  end

  it "raises unless scroll: is true or false" do
    expect { show(scroll: "yes") }.to raise_error(ArgumentError, /scroll: takes true or false/)
  end

  describe "at render" do
    it "renders when clear: names a field the render produced" do
      klass = build do
        div(**reactive_root) do
          input(type: "radio", name: "kind", value: "other")
          div(**reactive_show(if: { kind: "other" }, clear: :notes, focus: "#notes")) do
            input(id: "notes", name: "notes")
          end
        end
      end

      expect(klass.new.call).to include("data-reactive-show-clear=")
    end

    it "raises when clear: names no rendered field" do
      klass = build do
        div(**reactive_root) { div(**reactive_show(if: { kind: "other" }, clear: :nots)) { input(name: "notes") } }
      end

      expect { klass.new.call }.to raise_error(ArgumentError, /clear: :nots names no field/)
    end

    it "raises when clear: names a file input" do
      klass = build do
        div(**reactive_root) do
          div(**reactive_show(if: { kind: "other" }, clear: :photo)) { input(type: "file", name: "photo") }
        end
      end

      expect { klass.new.call }.to raise_error(ArgumentError, /clear: :photo is a file input/)
    end
  end
end
