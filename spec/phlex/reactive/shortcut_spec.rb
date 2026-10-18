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

  it "exposes a frozen canonical keys String" do
    expect(described_class.parse("Shift+Mod+z").keys).to be_frozen
  end

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

    it "raises on shortcut: false instead of binding a global click" do
      expect { instance.send(:on, :save, shortcut: false) }.to raise_error(ArgumentError, /shortcut:/)
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
        .to raise_error(ArgumentError, /keys:.*in_editable:.*handled:/m)
      expect { instance.send(:on, :close, shortcut: { keys: "esc", in_editable: "yes" }) }
        .to raise_error(ArgumentError, /in_editable:/)
    end

    # Issue #429: a shortcut skips a key another handler already prevented;
    # handled: true runs it anyway. The wire Hash carries whichever flag is on.
    {
      { in_editable: false, handled: false } => "esc",
      { in_editable: true, handled: false } => { "keys" => "esc", "inEditable" => true },
      { in_editable: false, handled: true } => { "keys" => "esc", "handled" => true },
      { in_editable: true, handled: true } => { "keys" => "esc", "inEditable" => true, "handled" => true }
    }.each do |flags, wire|
      it "serialises #{flags} as #{wire.inspect}" do
        expect(described_class.parse({ keys: "esc", **flags }).param).to eq(wire)
      end
    end

    it "serialises handled: true on on() and on_client" do
      data = instance.send(:on, :close, shortcut: { keys: "esc", handled: true })[:data]
      expect(JSON.parse(data[:reactive_shortcut_param])).to eq("keys" => "esc", "handled" => true)

      ops = instance.send(:on_client, :keydown, js.hide("#dialog"), shortcut: { keys: "esc", handled: true })[:data]
      expect(JSON.parse(ops[:reactive_ops_param])["shortcut"]).to eq("keys" => "esc", "handled" => true)
    end

    it "raises on handled: that is not true or false" do
      expect { described_class.parse({ keys: "esc", handled: "yes" }) }
        .to raise_error(ArgumentError, /handled: is true or false, got "yes"/)
      expect { instance.send(:on, :close, shortcut: { keys: "esc", handled: nil }) }
        .to raise_error(ArgumentError, /handled:/)
    end

    it "raises on a shortcut that is neither a String nor a Hash" do
      expect { instance.send(:on, :close, shortcut: :esc) }
        .to raise_error(ArgumentError, /String.*Hash/m)
    end
  end

  # Issue #366: delete and backspace are keys Stimulus's default key map lacks,
  # so the descriptor is rendered WITHOUT a key filter (Stimulus would throw
  # "unknown key filter" at keypress) and the client matches the chord alone.
  describe "keys Stimulus does not know (delete, backspace)" do
    it "parses delete, backspace and mod+backspace" do
      expect(described_class.parse("delete").keys).to eq("delete")
      expect(described_class.parse("Backspace").keys).to eq("backspace")
      expect(described_class.parse("mod+backspace").keys).to eq("mod+backspace")
    end

    it "is not Stimulus-filterable for delete/backspace, and is for a Stimulus key" do
      expect(described_class.parse("delete")).not_to be_stimulus_filterable
      expect(described_class.parse("mod+backspace")).not_to be_stimulus_filterable
      expect(described_class.parse("mod+z")).to be_stimulus_filterable
      expect(described_class.parse("esc")).to be_stimulus_filterable
    end

    it "still raises on another unknown key, naming delete and backspace" do
      expect { described_class.parse("insert") }
        .to raise_error(ArgumentError, /unknown key "insert".*delete.*backspace/m)
    end

    it "renders on() as ONE bare window keydown, the chord in the param" do
      data = instance.send(:on, :close, shortcut: "delete")[:data]

      expect(data[:action]).to eq("keydown@window->reactive#dispatch")
      expect(data[:reactive_shortcut_param]).to eq("delete")
      expect(data[:reactive_window_param]).to eq("true")
    end

    it "renders a mod chord bare too, with no twin (the client picks the platform)" do
      data = instance.send(:on, :close, shortcut: "mod+backspace")[:data]

      expect(data[:action]).to eq("keydown@window->reactive#dispatch")
      expect(data[:reactive_shortcut_param]).to eq("mod+backspace")
    end

    it "keeps the Hash form on a bare descriptor" do
      data = instance.send(:on, :close, shortcut: { keys: "delete", in_editable: true })[:data]

      expect(data[:action]).to eq("keydown@window->reactive#dispatch")
      expect(JSON.parse(data[:reactive_shortcut_param])).to eq("keys" => "delete", "inEditable" => true)
    end

    it "renders on_client bare, the chord in the record" do
      data = instance.send(:on_client, :keydown, js.hide("#preview"), shortcut: "mod+backspace")[:data]

      expect(data[:action]).to eq("keydown@window->reactive#runOps")
      expect(JSON.parse(data[:reactive_ops_param])).to include("on" => "keydown", "shortcut" => "mod+backspace")
    end

    it "raises with once: (Stimulus would spend the bare listener on the first key of any kind)" do
      expect { instance.send(:on, :close, shortcut: "delete", once: true) }
        .to raise_error(ArgumentError, /"delete".*once:/m)
      expect { instance.send(:on_client, :keydown, js.hide("#p"), shortcut: "backspace", once: true) }
        .to raise_error(ArgumentError, /once:/)
    end

    it "leaves a Stimulus chord's rendering unchanged" do
      expect(instance.send(:on, :undo, shortcut: "mod+z")[:data][:action]).to eq(
        "keydown.meta+z@window->reactive#dispatch keydown.ctrl+z@window->reactive#dispatch"
      )
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
