# frozen_string_literal: true

require "spec_helper"
require "phlex"

# Issue #357: shortcut: on on() / on_client() — a page-level keyboard shortcut.
# `mod` expands into a meta twin and a ctrl twin (the client runs the one for
# its platform), the binding is on the window, and the client prevents the
# chord and skips editable targets. Validation is loud, at render.
RSpec.describe Phlex::Reactive::Shortcut do
  let(:klass) do
    Class.new do
      include Phlex::Reactive::Component

      def self.name = "ShortcutThing"

      reactive_state :count
      %i[undo redo save close].each { action(it) }

      def initialize(count: 0) = @count = count
      attr_reader :count
    end
  end

  let(:instance) { klass.new }
  let(:js) { Phlex::Reactive::JS.new }

  describe "on(..., shortcut:)" do
    it "renders the meta and ctrl twins on the window for a mod chord" do
      data = instance.send(:on, :undo, shortcut: "mod+z")[:data]

      expect(data[:action]).to eq(
        "keydown.meta+z@window->reactive#dispatch keydown.ctrl+z@window->reactive#dispatch"
      )
      expect(data[:reactive_window_param]).to eq("true")
      expect(data[:reactive_shortcut_param]).to eq("mod+z")
      expect(data[:reactive_action_param]).to eq("undo")
    end

    it "renders one descriptor for a chord without mod" do
      data = instance.send(:on, :close, shortcut: "esc")[:data]

      expect(data[:action]).to eq("keydown.esc@window->reactive#dispatch")
      expect(data[:reactive_shortcut_param]).to eq("esc")
    end

    it "keeps every modifier in each twin, in a canonical order" do
      data = instance.send(:on, :redo, shortcut: "Shift+Mod+Z")[:data]

      expect(data[:action]).to eq(
        "keydown.meta+shift+z@window->reactive#dispatch keydown.ctrl+shift+z@window->reactive#dispatch"
      )
      expect(data[:reactive_shortcut_param]).to eq("mod+shift+z")
    end

    it "composes once: on each twin" do
      data = instance.send(:on, :save, shortcut: "mod+s", once: true)[:data]

      expect(data[:action]).to eq(
        "keydown.meta+s@window->reactive#dispatch:once keydown.ctrl+s@window->reactive#dispatch:once"
      )
    end

    it "does not force type=button (it is a window binding)" do
      expect(instance.send(:on, :undo, shortcut: "mod+z")).not_to have_key(:type)
    end

    it "is not an action param" do
      data = instance.send(:on, :undo, shortcut: "mod+z")[:data]

      expect(JSON.parse(data[:reactive_params_param])).to eq({})
    end

    it "serialises the Hash form with in_editable: true" do
      data = instance.send(:on, :close, shortcut: { keys: "esc", in_editable: true })[:data]

      expect(JSON.parse(data[:reactive_shortcut_param])).to eq("keys" => "esc", "inEditable" => true)
      expect(data[:action]).to eq("keydown.esc@window->reactive#dispatch")
    end

    it "renders the Hash form with in_editable: false as the plain String" do
      data = instance.send(:on, :close, shortcut: { keys: "esc", in_editable: false })[:data]

      expect(data[:reactive_shortcut_param]).to eq("esc")
    end

    it "accepts every key in Stimulus's default key map" do
      keys = %w[a z 0 9 enter tab esc space up down left right home end page_up page_down]

      expect { keys.each { instance.send(:on, :save, shortcut: "alt+#{it}") } }.not_to raise_error
    end

    {
      "event:" => { event: "keydown.k" },
      "window:" => { window: true },
      "outside:" => { outside: true }
    }.each do |name, extra|
      it "raises with #{name} (the shortcut decides it)" do
        expect { instance.send(:on, :undo, shortcut: "mod+z", **extra) }
          .to raise_error(ArgumentError, /shortcut:.*#{name}/m)
      end
    end

    it "raises on a key outside Stimulus's default key map" do
      expect { instance.send(:on, :save, shortcut: "mod+/") }
        .to raise_error(ArgumentError, %r{unknown key "/".*keyMappings}m)
    end

    it "raises on a chord without a key" do
      expect { instance.send(:on, :save, shortcut: "mod+shift") }
        .to raise_error(ArgumentError, /exactly one key/)
    end

    it "raises on a chord with two keys" do
      expect { instance.send(:on, :save, shortcut: "a+b") }
        .to raise_error(ArgumentError, /exactly one key/)
    end

    it "raises on mod combined with meta or ctrl" do
      expect { instance.send(:on, :save, shortcut: "mod+ctrl+s") }
        .to raise_error(ArgumentError, /mod.*meta.*ctrl/m)
    end

    it "raises on a repeated modifier" do
      expect { instance.send(:on, :save, shortcut: "shift+shift+s") }
        .to raise_error(ArgumentError, /repeat/)
    end

    it "raises on a malformed Hash" do
      expect { instance.send(:on, :close, shortcut: { key: "esc" }) }
        .to raise_error(ArgumentError, /keys:.*in_editable:/m)
      expect { instance.send(:on, :close, shortcut: { keys: "esc", in_editable: "yes" }) }
        .to raise_error(ArgumentError, /in_editable:/)
    end

    it "raises on a shortcut that is neither a String nor a Hash" do
      expect { instance.send(:on, :close, shortcut: :esc) }
        .to raise_error(ArgumentError, /String.*Hash/m)
    end
  end

  describe "on_client(:keydown, ops, shortcut:)" do
    it "renders the twins and a record carrying the bare keydown and the shortcut" do
      data = instance.send(:on_client, :keydown, js.toggle("#palette"), shortcut: "mod+k")[:data]

      expect(data[:action]).to eq(
        "keydown.meta+k@window->reactive#runOps keydown.ctrl+k@window->reactive#runOps"
      )
      record = JSON.parse(data[:reactive_ops_param])
      expect(record).to include("on" => "keydown", "window" => true, "shortcut" => "mod+k")
    end

    it "carries the Hash form in the record" do
      data = instance.send(:on_client, "keydown", js.hide("#dialog"),
        shortcut: { keys: "esc", in_editable: true })[:data]

      expect(JSON.parse(data[:reactive_ops_param])["shortcut"]).to eq("keys" => "esc", "inEditable" => true)
    end

    it "raises for an event other than a bare keydown" do
      expect { instance.send(:on_client, :click, js.toggle("#p"), shortcut: "mod+k") }
        .to raise_error(ArgumentError, /keydown/)
      expect { instance.send(:on_client, "keydown.k", js.toggle("#p"), shortcut: "mod+k") }
        .to raise_error(ArgumentError, /keydown/)
    end

    it "raises with window: or outside:" do
      expect { instance.send(:on_client, :keydown, js.toggle("#p"), shortcut: "mod+k", window: true) }
        .to raise_error(ArgumentError, /window:/)
      expect { instance.send(:on_client, :keydown, js.toggle("#p"), shortcut: "mod+k", outside: true) }
        .to raise_error(ArgumentError, /outside:/)
    end

    it "raises on an unknown key" do
      expect { instance.send(:on_client, :keydown, js.toggle("#p"), shortcut: "mod+?") }
        .to raise_error(ArgumentError, /unknown key/)
    end
  end
end
