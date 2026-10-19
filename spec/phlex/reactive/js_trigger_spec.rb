# frozen_string_literal: true

require "rails_helper"

# Issue #442: client ops that read the element whose binding fired. `:trigger`
# is a target (the "@trigger" sentinel); `from:` + `attr:` read an op's value
# off an element (a data-* attribute or its text) instead of baking a literal;
# dispatch's `detail_from:` builds the event detail off the trigger the same
# way. Every record that does not ask for them stays byte-identical.
RSpec.describe Phlex::Reactive::JS do
  subject(:js) { described_class.new }

  def args_of(chain) = JSON.parse(chain.to_json).dig(0, 1)

  describe ":trigger as a target" do
    it "serializes to the @trigger sentinel" do
      expect(described_class::TRIGGER_SENTINEL).to eq("@trigger")
      expect(JSON.parse(js.add_class(:trigger, "picked").to_json))
        .to eq([["add_class", { "to" => "@trigger", "classes" => ["picked"] }]])
    end

    it "is taken wherever a client op takes a target" do
      chains = [
        js.show(:trigger), js.hide(:trigger), js.toggle(:trigger),
        js.add_class(:trigger, "a"), js.remove_class(:trigger, "a"), js.toggle_class(:trigger, "a"),
        js.set_attr(:trigger, "aria-selected", "true"), js.remove_attr(:trigger, "aria-selected"),
        js.toggle_attr(:trigger, "aria-pressed", "true", "false"),
        js.focus(:trigger), js.focus_first(:trigger), js.blur(:trigger),
        js.show_modal(:trigger), js.close_dialog(:trigger),
        js.text(:trigger, "x"), js.dispatch("app:picked", to: :trigger), js.submit(:trigger),
        js.copy_media(:trigger, from: "#logo")
      ]
      expect(chains.map { args_of(it)["to"] }).to all(eq("@trigger"))
    end

    it "is taken by expanded:, submit's submitter: and copy_media's from:" do
      expect(args_of(js.hide("#menu", expanded: :trigger))["expanded"]).to eq("@trigger")
      expect(args_of(js.submit("#form", submitter: :trigger))["submitter"]).to eq("@trigger")
      expect(args_of(js.copy_media("#logo", from: :trigger))["from"]).to eq("@trigger")
    end

    it "keeps every existing record byte-identical" do
      expect(js.hide("#menu", expanded: "#q").to_json).to eq('[["hide",{"to":"#menu","expanded":"#q"}]]')
      expect(js.set_attr("#x", "aria-selected", "true").to_json)
        .to eq('[["set_attr",{"to":"#x","name":"aria-selected","value":"true"}]]')
      expect(js.dispatch("app:x", detail: { "id" => 1 }).to_json)
        .to eq('[["dispatch",{"name":"app:x","to":"@root","detail":{"id":1}}]]')
      expect(js.text("#l", nil).to_json).to eq('[["text",{"to":"#l","value":""}]]')
      expect(js.set_value("#f", nil).to_json).to eq('[["set_value",{"to":"#f","value":""}]]')
    end

    it "is refused as the field of the field-writing ops (they write a field, not the trigger)" do
      expect { js.set_value(:trigger, "x") }.to raise_error(ArgumentError, /set_value targets a field, not the trigger/)
      expect { js.set_value("@trigger", "x") }.to raise_error(ArgumentError, /set_value targets a field/)
      expect { js.paste_into(:trigger) }.to raise_error(ArgumentError, /paste_into targets a field, not the trigger/)
      expect { js.preview_file(:trigger, into: "#img") }
        .to raise_error(ArgumentError, /preview_file reads a file input, not the trigger/)
    end

    it "is refused, as a Symbol or its sentinel string, as preview_file's into:, name: and wrap:" do
      triggers = [:trigger, "@trigger"]
      %i[into name wrap].product(triggers).each do |key, value|
        others = key == :into ? {} : { into: "#img" }
        expect { js.preview_file("#f", **others, key => value) }
          .to raise_error(ArgumentError, /preview_file #{key}: must be a CSS selector string/)
      end
    end

    it "still raises for any other Symbol, naming the accepted forms" do
      expect { js.show(:menu) }.to raise_error(ArgumentError, /:trigger, :root or a CSS selector/)
    end

    it "leaves JS.normalize_target refusing :trigger (pending hints and css vars have no trigger)" do
      expect { described_class.normalize_target(:trigger) }.to raise_error(ArgumentError, /:root or a CSS selector/)
      expect(described_class.normalize_client_target(:trigger)).to eq("@trigger")
      expect(described_class.normalize_client_target(:root)).to eq("@root")
      expect(described_class.normalize_client_target("#x")).to eq("#x")
    end
  end

  describe "from: + attr: (a value read off an element)" do
    it "writes from/attr in place of value on set_value" do
      expect(js.set_value("#item-value", from: :trigger, attr: "data-value").to_json)
        .to eq('[["set_value",{"to":"#item-value","from":"@trigger","attr":"data-value"}]]')
    end

    it "reads textContent with attr: :text (the @text wire value)" do
      expect(args_of(js.text("#item-label", from: :trigger, attr: :text)))
        .to eq("to" => "#item-label", "from" => "@trigger", "attr" => "@text")
    end

    it "reads into set_attr, keeping keep: and global: after it" do
      expect(args_of(js.set_attr("#preview", "data-state", from: "#source", attr: "data-state",
        global: true, keep: true)))
        .to eq("to" => "#preview", "name" => "data-state", "from" => "#source", "attr" => "data-state",
          "global" => true, "keep" => true)
    end

    it "takes :root and a selector as from:" do
      expect(args_of(js.text("#l", from: :root, attr: "data-label"))["from"]).to eq("@root")
      expect(args_of(js.text("#l", from: "[data-current]", attr: "data-label"))["from"]).to eq("[data-current]")
    end

    it "keeps nil meaning clear for the positional value" do
      expect(args_of(js.set_attr("#x", "data-state", nil))).to eq("to" => "#x", "name" => "data-state", "value" => "")
    end

    it "raises with both a value and from:" do
      expect { js.set_value("#f", "x", from: :trigger, attr: "data-value") }
        .to raise_error(ArgumentError, /set_value takes a value or from:, not both/)
      expect { js.text("#l", "x", from: :trigger, attr: :text) }.to raise_error(ArgumentError, /not both/)
      expect { js.set_attr("#x", "data-a", "1", from: :trigger, attr: "data-a") }.to raise_error(ArgumentError, /not both/)
    end

    it "raises with neither a value nor from:" do
      expect { js.set_value("#f") }.to raise_error(ArgumentError, /set_value needs a value or from:/)
      expect { js.text("#l") }.to raise_error(ArgumentError, /text needs a value or from:/)
      expect { js.set_attr("#x", "data-a") }.to raise_error(ArgumentError, /set_attr needs a value or from:/)
    end

    it "requires attr: with from:, and from: with attr:" do
      expect { js.set_value("#f", from: :trigger) }.to raise_error(ArgumentError, /from: needs attr:/)
      expect { js.set_value("#f", "x", attr: "data-value") }.to raise_error(ArgumentError, /attr: needs from:/)
    end

    it "reads only a data-* attribute or :text" do
      %w[value href aria-label class data- data-1x onclick].each do |bad|
        expect { js.set_value("#f", from: :trigger, attr: bad) }
          .to raise_error(ArgumentError, /attr: reads a data-\* attribute or :text/)
      end
      expect { js.text("#l", from: :trigger, attr: :value) }.to raise_error(ArgumentError, /data-\* attribute or :text/)
      expect(args_of(js.text("#l", from: :trigger, attr: "DATA-Label"))["attr"]).to eq("DATA-Label")
    end

    it "raises on a from: that is no target" do
      expect { js.text("#l", from: :row, attr: :text) }.to raise_error(ArgumentError, /target must be/)
      expect { js.text("#l", from: "", attr: :text) }.to raise_error(ArgumentError, /from: needs a CSS selector/)
    end

    it "keeps the write-side allowlist on set_attr's name" do
      expect { js.set_attr("#a", "href", from: :trigger, attr: "data-url") }.to raise_error(ArgumentError, /URL-bearing/)
    end
  end

  describe "dispatch(detail_from:)" do
    it "writes detail_from beside detail, mapping detail keys to attributes read off the trigger" do
      chain = js.dispatch("app:item-picked", detail_from: { id: "data-id", value: "data-value", text: :text })
      expect(chain.to_json).to eq(
        '[["dispatch",{"name":"app:item-picked","to":"@root","detail":{},' \
        '"detail_from":{"id":"data-id","value":"data-value","text":"@text"}}]]'
      )
    end

    it "keeps a literal detail with a from key unambiguous" do
      args = args_of(js.dispatch("app:x", detail: { "from" => "menu" }, detail_from: { id: "data-id" }))
      expect(args["detail"]).to eq("from" => "menu")
      expect(args["detail_from"]).to eq("id" => "data-id")
    end

    it "omits detail_from when not asked for" do
      expect(args_of(js.dispatch("app:x"))).not_to have_key("detail_from")
      expect(args_of(js.dispatch("app:x", detail_from: {}))).not_to have_key("detail_from")
    end

    it "refuses a non-data-* read and a key also in detail:" do
      expect { js.dispatch("app:x", detail_from: { id: "id" }) }.to raise_error(ArgumentError, /data-\* attribute or :text/)
      expect { js.dispatch("app:x", detail: { id: 1 }, detail_from: { "id" => "data-id" }) }
        .to raise_error(ArgumentError, /detail_from: key "id" is also in detail:/)
      expect { js.dispatch("app:x", detail_from: "data-id") }.to raise_error(ArgumentError, /detail_from: takes a Hash/)
    end

    it "refuses a detail: that is no Hash (the reads merge over it as an object)" do
      expect { js.dispatch("app:x", detail: "picked", detail_from: { id: "data-id" }) }
        .to raise_error(ArgumentError, /detail_from: merges over a Hash detail:, got "picked"/)
      expect { js.dispatch("app:x", detail: [1, 2], detail_from: { id: "data-id" }) }
        .to raise_error(ArgumentError, /detail_from: merges over a Hash detail:/)
      expect(args_of(js.dispatch("app:x", detail: nil, detail_from: { id: "data-id" }))["detail_from"])
        .to eq("id" => "data-id")
      expect(args_of(js.dispatch("app:x", detail: "picked"))["detail"]).to eq("picked")
    end
  end

  describe ".assert_ops_allowed! (the raw-list escape hatch)" do
    it "refuses @trigger in to, from, expanded and submitter — a raw list is server-pushed" do
      [
        ["show", { "to" => "@trigger" }],
        ["text", { "to" => "#l", "from" => "@trigger", "attr" => "@text" }],
        ["hide", { "to" => "#menu", "expanded" => "@trigger" }],
        ["submit", { "to" => "@root", "submitter" => "@trigger" }]
      ].each do |op|
        expect { described_class.assert_ops_allowed!([op]) }
          .to raise_error(ArgumentError, /#{op[0]} names @trigger/)
      end
    end

    it "refuses detail_from (it reads off the trigger)" do
      raw = [["dispatch", { "name" => "x", "to" => "@root", "detail" => {}, "detail_from" => { "id" => "data-id" } }]]
      expect { described_class.assert_ops_allowed!(raw) }.to raise_error(ArgumentError, /dispatch names @trigger/)
    end

    it "refuses @trigger as preview_file's into, name or wrap" do
      %w[into name wrap].each do
        raw = [["preview_file", { "to" => "#f", "into" => "#img", it => "@trigger" }]]
        expect { described_class.assert_ops_allowed!(raw) }.to raise_error(ArgumentError, /preview_file names @trigger/)
      end
    end

    it "reads nothing off an empty detail_from, so it names no trigger" do
      raw = [["dispatch", { "name" => "x", "to" => "@root", "detail" => {}, "detail_from" => {} }]]
      expect { described_class.assert_ops_allowed!(raw) }.not_to raise_error
    end

    it "keeps a name that spells the sentinel on ops whose name is not an element" do
      raw = [["dispatch", { "name" => "@trigger", "to" => "@root", "detail" => {} }]]
      expect { described_class.assert_ops_allowed!(raw) }.not_to raise_error
    end

    it "refuses a non-data-* read attr" do
      raw = [["set_value", { "to" => "#f", "from" => "#src", "attr" => "value" }]]
      expect { described_class.assert_ops_allowed!(raw) }.to raise_error(ArgumentError, /data-\* attribute or :text/)
    end

    it "checks attr only where it is a read (set_value, text, set_attr with from)" do
      raw = [["show", { "to" => "#x", "attr" => "anything" }], ["text", { "to" => "#l", "value" => "x", "attr" => "id" }]]
      expect { described_class.assert_ops_allowed!(raw) }.not_to raise_error
      expect { described_class.assert_ops_allowed!([["text", { "to" => "#l", "from" => "#s" }]]) }
        .to raise_error(ArgumentError, /text attr: reads a data-\* attribute or :text \(textContent\), got nil/)
    end

    it "passes a data-* read off a selector" do
      raw = [["text", { "to" => "#l", "from" => "#src", "attr" => "data-label" }],
             ["set_attr", { "to" => "#l", "name" => "data-x", "from" => "#src", "attr" => "@text" }]]
      expect { described_class.assert_ops_allowed!(raw) }.not_to raise_error
    end
  end

  describe "server-pushed ops refuse @trigger (they have no trigger)" do
    let(:counter) { CounterComponent.new(count: 1) }

    it "refuses a :trigger op in reply.js, as a chain and as a raw list" do
      expect { counter.reply.with.js(js.set_attr(:trigger, "aria-selected", "true")) }
        .to raise_error(ArgumentError, /set_attr names @trigger.*no trigger/)
      expect { counter.reply.with.js(js.text("#l", from: :trigger, attr: :text)) }
        .to raise_error(ArgumentError, /text names @trigger/)
      expect { counter.reply.with.js([["show", { "to" => "@trigger" }]]) }.to raise_error(ArgumentError, /@trigger/)
    end

    it "refuses detail_from in reply.js" do
      expect { counter.reply.with.js(js.dispatch("app:x", detail_from: { id: "data-id" })) }
        .to raise_error(ArgumentError, /dispatch names @trigger/)
    end

    it "refuses a :trigger op in broadcast_to(js:)" do
      expect { TodoItemComponent.broadcast_to("alerts", js: js.add_class(:trigger, "x")) }
        .to raise_error(ArgumentError, /add_class names @trigger/)
    end

    it "refuses a hand-built JS chain with Symbol keys and ignores a malformed op (no args Hash)" do
      expect { counter.reply.with.js(described_class.new([["show", { to: "@trigger" }]])) }
        .to raise_error(ArgumentError, /show names @trigger/)
      expect { counter.reply.with.js(described_class.new([["show"]])) }.not_to raise_error
      expect do
        Class.new do
          include Phlex::Reactive::Component

          def self.name = "SymbolTriggerRun"
          reactive_on_complete if: { a: "1" }, run: Phlex::Reactive::JS.new([["show", { to: "@trigger" }]])
        end
      end.to raise_error(ArgumentError, /show names @trigger/)
    end

    it "still lets reply.js read off a selector" do
      stream = counter.reply.with.js(js.text("#l", from: "#src", attr: "data-label")).streams.first
      expect(stream).to include("&quot;from&quot;:&quot;#src&quot;")
    end
  end
end
