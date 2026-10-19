# frozen_string_literal: true

require "spec_helper"
require "phlex"

# Issue #180 Phase A: ClientBindings — the blessed CLIENT-ONLY include. A view
# that only shows/hides, filters, or computes client-side (no server actions, no
# token) includes this instead of the full Component. It does NOT pull in
# Streamable (so it never clobbers an app's own replace/to_stream_* concern) or
# the token machinery (a tokenless reactive_root, no #id requirement, invisible
# to phlex_reactive:doctor).
RSpec.describe Phlex::Reactive::ClientBindings do
  let(:client_klass) do
    Class.new(Phlex::HTML) do
      include Phlex::Reactive::ClientBindings

      def self.name = "ClientOnlyThing"

      reactive_scope :form

      def reactive_values = { director: true }

      def view_template
        div(**reactive_root) do
          div(**reactive_show(if: { director: true })) { "director fields" }
        end
      end
    end
  end

  it "emits a TOKEN-LESS reactive root (controller, but no token)" do
    attrs = client_klass.new.send(:reactive_root)
    expect(attrs[:data][:controller]).to eq("reactive")
    expect(attrs[:data]).not_to have_key(:reactive_token_value)
  end

  it "carries the declared scope on the root" do
    expect(client_klass.new.send(:reactive_root)[:data][:reactive_scope]).to eq("form")
  end

  it "does NOT require an #id (no Streamable default that raises)" do
    # A client-only root has no record and no #id; reactive_root must not raise.
    expect { client_klass.new.send(:reactive_root) }.not_to raise_error
  end

  it "provides the conditions-language show helper with first-paint hidden:" do
    attrs = client_klass.new.send(:reactive_show, if: { director: true })
    expect(attrs[:hidden]).to be(false) # reactive_values says director true → visible
    expect(attrs[:data]).to have_key(:reactive_show)
  end

  it "renders end to end without a token" do
    html = client_klass.new.call
    expect(html).to include('data-controller="reactive"')
    expect(html).to include("data-reactive-show=")
    expect(html).not_to include("reactive-token-value")
  end

  it "does NOT include Streamable (no replace/to_stream_* to clobber an app concern)" do
    expect(client_klass.include?(Phlex::Reactive::Streamable)).to be(false)
    expect(client_klass.new).not_to respond_to(:to_stream_replace)
  end

  it "does NOT enroll in the Streamable component registry (doctor never flags it)" do
    client_klass # force definition
    expect(Phlex::Reactive::Streamable.registered_classes).not_to include(client_klass)
  end

  it "still exposes on_client and js for zero-round-trip ops" do
    instance = client_klass.new
    expect(instance.send(:js)).to be_a(Phlex::Reactive::JS)
    attrs = instance.send(:on_client, :click, instance.send(:js).hide("#x"))
    expect(attrs[:data][:action]).to include("reactive#runOps")
  end

  it "is also mixed into a full Component (one implementation, via the Concern chain)" do
    full = Class.new(Phlex::HTML) do
      include Phlex::Reactive::Component

      def self.name = "FullComponentThing"
    end
    expect(full.ancestors).to include(described_class)
  end

  # A ClientBindings component has no Identity/Streamable, so a server-action
  # macro can never actually work — it would sign nothing and dispatch nowhere.
  # Declaring one must fail LOUDLY at class-definition time, not silently no-op.
  describe "server-action macros raise on a client-only class (default-deny)" do
    it "raises for action" do
      expect do
        Class.new(Phlex::HTML) do
          include Phlex::Reactive::ClientBindings

          def self.name = "ClientWithAction"
          action :save
        end
      end.to raise_error(ArgumentError, /action.*ClientBindings.*Phlex::Reactive::Component/m)
    end

    it "raises for reactive_record" do
      expect do
        Class.new(Phlex::HTML) do
          include Phlex::Reactive::ClientBindings

          def self.name = "ClientWithRecord"
          reactive_record :todo
        end
      end.to raise_error(ArgumentError, /reactive_record.*needs.*Component/m)
    end

    it "raises for reactive_state" do
      expect do
        Class.new(Phlex::HTML) do
          include Phlex::Reactive::ClientBindings

          def self.name = "ClientWithState"
          reactive_state :count
        end
      end.to raise_error(ArgumentError, /reactive_state.*needs.*Component/m)
    end

    it "still allows the client-only macros (reactive_scope, reactive_compute)" do
      expect do
        Class.new(Phlex::HTML) do
          include Phlex::Reactive::ClientBindings

          def self.name = "ClientWithComputes"
          reactive_scope :form
          reactive_compute :total, inputs: %i[a b], outputs: %i[total]
        end
      end.not_to raise_error
    end

    # Issue #226: a completion binding is client-only behavior (conditions +
    # local ops, no token, no action), so it belongs on ClientBindings too —
    # and its tokenless root still emits the wire attr.
    it "allows reactive_on_complete and emits its root attr tokenlessly" do
      klass = Class.new(Phlex::HTML) do
        include Phlex::Reactive::ClientBindings

        def self.name = "ClientWithOnComplete"
        reactive_on_complete if: { code: { length: 6 } }, run: js.dispatch("code:complete")
      end

      attrs = klass.new.send(:reactive_attrs)
      expect(attrs[:data]).not_to have_key(:reactive_token_value)
      expect(JSON.parse(attrs[:data][:reactive_on_complete]).first)
        .to include("any" => [[{ "field" => "code", "len_eq" => 6 }]])
    end

    it "does NOT raise for those macros on a full Component (Identity present)" do
      expect do
        Class.new(Phlex::HTML) do
          include Phlex::Reactive::Component

          def self.name = "FullWithMacros"
          reactive_record :todo
          reactive_state :editing
          action :save
        end
      end.not_to raise_error
    end
  end

  # Issue #442: on_client(..., within:) — one binding for a subtree. The record
  # carries "within" (written only when given); the client runs it for an
  # event from inside an element matching the selector under the bound
  # element, and that element is the op's @trigger.
  describe "on_client within: (issue #442)" do
    subject(:instance) { client_klass.new }

    let(:pick) { instance.send(:js).set_value("#item-value", from: :trigger, attr: "data-value") }

    def record(attrs) = JSON.parse(attrs[:data][:reactive_ops_param])

    def on_client(...) = instance.send(:on_client, ...)

    it "writes within on the record" do
      expect(record(on_client(:click, pick, within: "[role=option]")))
        .to eq("on" => "click", "within" => "[role=option]", "ops" => pick.ops.map { JSON.parse(JSON.generate(it)) })
    end

    it "keeps a record without within: byte-identical" do
      ops = instance.send(:js).toggle("#menu")
      expect(on_client(:click, ops)).to eq(
        data: { action: "click->reactive#runOps", reactive_ops_param: '{"on":"click","ops":[["toggle",{"to":"#menu"}]]}' },
        type: "button"
      )
    end

    it "does not force type=button: the bound element is a container" do
      expect(on_client(:click, pick, within: "[role=option]")).not_to have_key(:type)
    end

    it "keeps the descriptor a plain element binding" do
      expect(on_client(:click, pick, within: "[role=option]")[:data][:action]).to eq("click->reactive#runOps")
    end

    it "composes with confirm:, detail:, debounce: and prevent: false" do
      rec = record(on_client("app:pick", pick, within: "li", confirm: "Sure?", detail: { ok: true }, debounce: 50,
        prevent: false))
      expect(rec).to include("prevent" => false, "within" => "li", "detail" => { "ok" => true }, "confirm" => "Sure?",
        "debounce" => 50)
    end

    it "refuses window:, outside: and shortcut: (a delegated binding is element-bound)" do
      expect { on_client(:click, pick, within: "li", window: true) }
        .to raise_error(ArgumentError, /on_client\("click"\) within: delegates from the bound element.*window:/)
      expect { on_client(:click, pick, within: "li", outside: true) }.to raise_error(ArgumentError, /within:.*outside:/)
      expect { on_client(:keydown, pick, within: "li", shortcut: "mod+k") }
        .to raise_error(ArgumentError, /within:.*shortcut:/)
    end

    it "refuses once: (Stimulus would drop the listener on a miss)" do
      expect { on_client(:click, pick, within: "li", once: true) }
        .to raise_error(ArgumentError, /on_client\("click"\) within: cannot combine with once:/)
    end

    it "refuses an empty or non-String selector" do
      ["", "  ", :li, 1].each do |bad|
        expect { on_client(:click, pick, within: bad) }
          .to raise_error(ArgumentError, /within: takes a non-empty CSS selector String/)
      end
    end

    it "refuses an event that does not bubble (the bound element never hears it from a row)" do
      %i[focus blur mouseenter mouseleave pointerenter pointerleave load error scroll toggle invalid].each do |name|
        expect { on_client(name, pick, within: "li") }
          .to raise_error(ArgumentError, /on_client\("#{name}"\) within: #{name} does not bubble.*focusin/)
      end
      %i[focusin focusout mouseover mouseout input change].each do |name|
        expect { on_client(name, pick, within: "li") }.not_to raise_error
      end
    end
  end

  # Issue #442's byte budget: a pickable list binds ONCE. The rows carry only
  # their data-*; the delegated record lives on the list.
  describe "a 248-row pickable list" do
    let(:picker_klass) do
      Class.new(Phlex::HTML) do
        include Phlex::Reactive::ClientBindings

        def self.name = "PickerBudget"

        def view_template
          div(**reactive_root) do
            input(id: "item-value", type: "hidden", name: "item")
            span(id: "item-label")
            ul(id: "menu", role: "listbox", **on_client(:click, pick_ops, within: "[role=option]")) do
              248.times do |i|
                li { button(role: "option", data: { id: i, value: "v#{i}", label: "Item #{i}" }) { "Item #{i}" } }
              end
            end
          end
        end

        private

        def pick_ops
          js.set_value("#item-value", from: :trigger, attr: "data-value")
            .text("#item-label", from: :trigger, attr: "data-label")
            .remove_attr("[role=option]", "aria-selected")
            .set_attr(:trigger, "aria-selected", "true")
            .dispatch("app:item-picked", detail_from: { id: "data-id", value: "data-value", text: "data-label" })
        end
      end
    end

    it "renders exactly one data-reactive-ops-param, on the list, and none on a row" do
      html = picker_klass.new.call
      expect(html.scan("data-reactive-ops-param").size).to eq(1)
      expect(html).to include('<ul id="menu" role="listbox" data-action="click->reactive#runOps" data-reactive-ops-param=')
      expect(html.scan(/<button role="option"[^>]*>/)).to all(satisfy { !it.include?("reactive") })
      expect(html.scan('<button role="option"').size).to eq(248)
    end
  end
end
