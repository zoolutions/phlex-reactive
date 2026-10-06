# frozen_string_literal: true

require "spec_helper"

# Issue #95: the client-side DOM-command builder behind on_client. Ops compile
# to a JSON array the generic controller's runOps action interprets —
# declarative DOM operations with ZERO round trip and no client state.
RSpec.describe Phlex::Reactive::JS do
  subject(:js) { described_class.new }

  describe "immutability" do
    it "returns a NEW frozen instance from every verb (chaining never mutates)" do
      chained = js.show("#a")

      expect(chained).not_to be(js)
      expect(js.ops).to be_empty # the original is untouched
      expect(chained).to be_frozen
      expect(chained.ops).to be_frozen
    end

    it "chains ops in call order" do
      ops = js.hide(".panel").show("#panel-2").ops
      expect(ops.map(&:first)).to eq(%w[hide show])
    end
  end

  describe "wire format (#to_json)" do
    it "serializes visibility ops with their selector" do
      expect(JSON.parse(js.toggle("#menu").to_json)).to eq([["toggle", { "to" => "#menu" }]])
    end

    it "serializes class ops with the class list (symbols coerced)" do
      expect(JSON.parse(js.add_class(".tab", "active", :current).to_json))
        .to eq([["add_class", { "to" => ".tab", "classes" => %w[active current] }]])
    end

    it "serializes remove_class and toggle_class the same way" do
      expect(JSON.parse(js.remove_class(".tab", "active").to_json).dig(0, 0)).to eq("remove_class")
      expect(JSON.parse(js.toggle_class(".tab", "active").to_json).dig(0, 0)).to eq("toggle_class")
    end

    it "serializes :root as the @root sentinel (the component's own root element)" do
      expect(JSON.parse(js.toggle_class(:root, "open").to_json))
        .to eq([["toggle_class", { "to" => "@root", "classes" => ["open"] }]])
    end

    it "carries global: true only when asked (root-scoped is the lean default)" do
      expect(JSON.parse(js.hide("#overlay", global: true).to_json))
        .to eq([["hide", { "to" => "#overlay", "global" => true }]])
      expect(JSON.parse(js.hide("#overlay").to_json).dig(0, 1)).not_to have_key("global")
    end
  end

  describe "argument validation (loud at render time, never silent on the client)" do
    it "rejects a target that is neither :root nor a CSS selector string" do
      expect { js.show(:menu) }.to raise_error(ArgumentError, /:root or a CSS selector/)
    end

    it "rejects a class op without at least one class" do
      expect { js.add_class(".tab") }.to raise_error(ArgumentError, /at least one class/)
    end
  end

  # --- Issue #96: attribute ops (the security-critical build-time allowlist) ---

  describe "attribute ops (#set_attr / #remove_attr / #toggle_attr)" do
    it "serializes set_attr with the name and stringified value" do
      expect(JSON.parse(js.set_attr("#x", "aria-expanded", true).to_json))
        .to eq([["set_attr", { "to" => "#x", "name" => "aria-expanded", "value" => "true" }]])
    end

    it "serializes remove_attr with just the name" do
      expect(JSON.parse(js.remove_attr(:root, "disabled").to_json))
        .to eq([["remove_attr", { "to" => "@root", "name" => "disabled" }]])
    end

    it "serializes toggle_attr with the name (no value needed)" do
      expect(JSON.parse(js.toggle_attr("#x", "aria-expanded").to_json))
        .to eq([["toggle_attr", { "to" => "#x", "name" => "aria-expanded" }]])
    end

    it "carries global: true through an attr op when asked" do
      expect(JSON.parse(js.set_attr("#x", "data-open", "1", global: true).to_json).dig(0, 1))
        .to include("global" => true)
    end

    it "coerces a symbol attribute name to a string" do
      expect(JSON.parse(js.toggle_attr("#x", :hidden).to_json).dig(0, 1, "name")).to eq("hidden")
    end
  end

  describe "the attribute-name allowlist (two-sided default-deny; build side raises)" do
    it "rejects event-handler attributes (/\\Aon/i) — XSS vector" do
      expect { js.set_attr("#x", "onclick", "alert(1)") }.to raise_error(ArgumentError, /onclick/)
      expect { js.toggle_attr("#x", "onmouseover") }.to raise_error(ArgumentError, /onmouseover/)
      expect { js.remove_attr("#x", "onload") }.to raise_error(ArgumentError, /onload/)
    end

    it "is case-insensitive about the on* prefix (OnClick, ONCLICK)" do
      expect { js.set_attr("#x", "OnClick", "x") }.to raise_error(ArgumentError)
      expect { js.set_attr("#x", "ONCLICK", "x") }.to raise_error(ArgumentError)
    end

    # Each block iterates attribute NAMES; the inner expect { } blocks reference
    # that outer `name`, so the ItBlockParameter cop's implicit-`it` rewrite would
    # shadow it (the same trap vendored_controller_sync_spec.rb documents).
    # rubocop:disable Style/ItBlockParameter
    it "rejects every URL-bearing attribute (javascript:-injection surface)" do
      %w[href src srcdoc action formaction xlink:href].each do |name|
        expect { js.set_attr("#x", name, "javascript:evil()") }
          .to raise_error(ArgumentError, /#{Regexp.escape(name)}/),
            "expected #{name} to be rejected"
      end
    end

    it "is case-insensitive about URL-bearing names (HREF, Src)" do
      expect { js.set_attr("#x", "HREF", "x") }.to raise_error(ArgumentError)
      expect { js.remove_attr("#x", "Src") }.to raise_error(ArgumentError)
    end

    it "rejects style (CSS injection — use classes)" do
      expect { js.set_attr("#x", "style", "color:red") }.to raise_error(ArgumentError, /style/)
      expect { js.set_attr("#x", "STYLE", "x") }.to raise_error(ArgumentError)
    end

    it "allows the intended surface: hidden, disabled, open, selected, aria-*, data-*" do
      %w[hidden disabled open selected aria-expanded aria-hidden data-state data-open].each do |name|
        expect { js.set_attr("#x", name, "true") }.not_to raise_error
        expect { js.toggle_attr("#x", name) }.not_to raise_error
        expect { js.remove_attr("#x", name) }.not_to raise_error
      end
    end
    # rubocop:enable Style/ItBlockParameter
  end

  # The raw [op, args] escape hatch (js([...]) / broadcast_js_to([...])) skips the
  # builder, so the allowlist is re-applied via .assert_ops_allowed! — full
  # server-side parity with the JS chain (defense in depth; the client also refuses).
  describe ".assert_ops_allowed! (raw-list escape hatch)" do
    it "rejects a raw set_attr op with an event-handler name" do
      list = [["set_attr", { "to" => "#x", "name" => "onclick", "value" => "alert(1)" }]]
      expect { described_class.assert_ops_allowed!(list) }.to raise_error(ArgumentError, /onclick/)
    end

    it "rejects a raw op with a URL-bearing name (case-insensitive)" do
      list = [["set_attr", { "to" => "#x", "name" => "HREF", "value" => "javascript:evil()" }]]
      expect { described_class.assert_ops_allowed!(list) }.to raise_error(ArgumentError, /href/i)
    end

    it "rejects a raw remove_attr/toggle_attr op with a style name" do
      expect { described_class.assert_ops_allowed!([["toggle_attr", { "name" => "style" }]]) }
        .to raise_error(ArgumentError, /style/)
    end

    it "accepts symbol-keyed args (name: ...) too" do
      expect { described_class.assert_ops_allowed!([["set_attr", { name: "onmouseover" }]]) }
        .to raise_error(ArgumentError, /onmouseover/)
    end

    it "leaves allowed attr ops and non-attr ops untouched" do
      expect do
        described_class.assert_ops_allowed!([
          ["set_attr", { "to" => "#x", "name" => "aria-expanded", "value" => "true" }],
          ["add_class", { "to" => "#x", "classes" => ["open"] }],
          ["show", { "to" => "#x" }]
        ])
      end.not_to raise_error
    end
  end

  # --- Issue #96: focus ops ---

  describe "focus ops (#focus / #focus_first)" do
    it "serializes focus with its target" do
      expect(JSON.parse(js.focus("#menu [role=menuitem]").to_json))
        .to eq([["focus", { "to" => "#menu [role=menuitem]" }]])
    end

    it "serializes focus_first with its target" do
      expect(JSON.parse(js.focus_first("#menu").to_json))
        .to eq([["focus_first", { "to" => "#menu" }]])
    end

    it "accepts :root and global: on focus ops" do
      expect(JSON.parse(js.focus(:root).to_json).dig(0, 1, "to")).to eq("@root")
      expect(JSON.parse(js.focus("#x", global: true).to_json).dig(0, 1)).to include("global" => true)
    end
  end

  # --- Issue #226: submit — commit the target's own form ---

  describe "submit op (#submit) — requestSubmit the target's own form" do
    it "defaults to the component root" do
      expect(JSON.parse(js.submit.to_json)).to eq([["submit", { "to" => "@root" }]])
    end

    it "accepts a selector target" do
      expect(JSON.parse(js.submit("#checkout").to_json))
        .to eq([["submit", { "to" => "#checkout" }]])
    end

    it "carries global: true only when asked (root-scoped is the lean default)" do
      expect(JSON.parse(js.submit("#checkout", global: true).to_json).dig(0, 1))
        .to include("global" => true)
      expect(JSON.parse(js.submit.to_json).dig(0, 1)).not_to have_key("global")
    end

    it "rejects a target that is neither :root nor a CSS selector string" do
      expect { js.submit(:form) }.to raise_error(ArgumentError, /:root or a CSS selector/)
    end

    # Issue #319: submit THROUGH a named submit control so its name=value posts.
    it "carries submitter: as a selector the client resolves with the op's scoping" do
      expect(JSON.parse(js.submit("#bulk", submitter: "#delete-submit").to_json))
        .to eq([["submit", { "to" => "#bulk", "submitter" => "#delete-submit" }]])
    end

    it "omits submitter when not given (byte-stable wire)" do
      expect(JSON.parse(js.submit("#bulk").to_json).dig(0, 1)).not_to have_key("submitter")
    end

    it "rejects a submitter that is not a CSS selector string (:root is never a submit control)" do
      expect { js.submit(submitter: :root) }.to raise_error(ArgumentError, /submitter/)
      expect { js.submit(submitter: "") }.to raise_error(ArgumentError, /submitter/)
      expect { js.submit(submitter: :delete) }.to raise_error(ArgumentError, /submitter/)
    end
  end

  # --- Issue #228: paste_into — clipboard-source trigger ---

  describe "paste_into op (#paste_into) — read the clipboard into a bound field" do
    it "serializes the field selector" do
      expect(JSON.parse(js.paste_into(".otp-input").to_json))
        .to eq([["paste_into", { "to" => ".otp-input" }]])
    end

    it "carries global: true only when asked (root-scoped is the lean default)" do
      expect(JSON.parse(js.paste_into("#code", global: true).to_json).dig(0, 1))
        .to include("global" => true)
      expect(JSON.parse(js.paste_into("#code").to_json).dig(0, 1)).not_to have_key("global")
    end

    it "requires an explicit field target (no :root default — the target is a field, not the root)" do
      expect { js.paste_into }.to raise_error(ArgumentError)
    end

    it "rejects :root LOUDLY (pasting into the root div is always a call-site bug)" do
      expect { js.paste_into(:root) }.to raise_error(ArgumentError, /field/)
    end

    it "rejects a target that is not a CSS selector string" do
      expect { js.paste_into(:code) }.to raise_error(ArgumentError, /:root or a CSS selector/)
    end
  end

  # --- Issue #96: dispatch a bubbling CustomEvent ---

  describe "dispatch (#dispatch) — a bubbling CustomEvent" do
    it "serializes name, detail, and a nil target as @root (dispatch on the root)" do
      expect(JSON.parse(js.dispatch("app:menu-toggled", detail: { open: true }).to_json))
        .to eq([["dispatch", { "name" => "app:menu-toggled", "to" => "@root", "detail" => { "open" => true } }]])
    end

    it "carries an explicit target when given" do
      expect(JSON.parse(js.dispatch("app:x", to: "#panel").to_json).dig(0, 1))
        .to include("name" => "app:x", "to" => "#panel")
    end

    it "defaults detail to an empty hash" do
      expect(JSON.parse(js.dispatch("app:x").to_json).dig(0, 1, "detail")).to eq({})
    end

    it "accepts :root and global: on a targeted dispatch" do
      expect(JSON.parse(js.dispatch("app:x", to: :root).to_json).dig(0, 1, "to")).to eq("@root")
      expect(JSON.parse(js.dispatch("app:x", to: "#x", global: true).to_json).dig(0, 1))
        .to include("global" => true)
    end
  end

  # --- Issue #96/#186: the transition: kwarg on show/hide/toggle ---
  # Issue #186: transition: takes NAMED legs ({ during:, from:, to: }); it compiles
  # to the same [during, from, to] wire array (zero client change). The old
  # positional Array form raises with the caller's own values in the named form.
  describe "transition: kwarg on show/hide/toggle" do
    it "compiles named legs to the [during, from, to] wire array" do
      ops = js.toggle("#menu",
        transition: { during: "transition-opacity", from: "opacity-0", to: "opacity-100" }).to_json
      expect(JSON.parse(ops).dig(0, 1, "transition"))
        .to eq(%w[transition-opacity opacity-0 opacity-100])
    end

    it "works on show and hide too" do
      legs = { during: "t", from: "f", to: "to" }
      expect(JSON.parse(js.show("#x", transition: legs).to_json).dig(0, 1, "transition"))
        .to eq(%w[t f to])
      expect(JSON.parse(js.hide("#x", transition: legs).to_json).dig(0, 1, "transition"))
        .to eq(%w[t f to])
    end

    it "omits the transition key when not asked (lean default)" do
      expect(JSON.parse(js.toggle("#x").to_json).dig(0, 1)).not_to have_key("transition")
    end

    it "raises for the removed Array form, slotting the caller's values into named legs" do
      expect { js.toggle("#x", transition: %w[fade fade-from fade-to]) }
        .to raise_error(ArgumentError, /during: "fade".*from: "fade-from".*to: "fade-to"/m)
    end

    it "raises for a Hash missing a leg" do
      expect { js.toggle("#x", transition: { during: "fade", from: "a" }) }
        .to raise_error(ArgumentError, /during.*from.*to/m)
    end
  end

  # --- Issue #271: two-value toggle_attr + expanded: on the visibility ops ---
  describe "toggle_attr with two values (flip between on/off, not presence)" do
    def args(chain) = JSON.parse(chain.to_json).dig(0, 1)

    it "serializes the pair as values (stringified)" do
      expect(args(js.toggle_attr("#t", "aria-expanded", true, false)))
        .to eq("to" => "#t", "name" => "aria-expanded", "values" => %w[true false])
    end

    it "keeps today's presence-toggle wire when no values are given" do
      expect(js.toggle_attr("#t", "aria-expanded").to_json)
        .to eq('[["toggle_attr",{"to":"#t","name":"aria-expanded"}]]')
    end

    it "raises for exactly one value or more than two (a half-specified flip)" do
      expect { js.toggle_attr("#t", "aria-expanded", "true") }.to raise_error(ArgumentError, /two values/)
      expect { js.toggle_attr("#t", "data-state", "a", "b", "c") }.to raise_error(ArgumentError, /two values/)
    end

    it "raises when both values are equal (a flip that never changes anything)" do
      expect { js.toggle_attr("#t", "aria-pressed", true, "true") }.to raise_error(ArgumentError, /differ/)
    end

    it "still carries global: and still gates the name" do
      expect(args(js.toggle_attr("#t", "data-state", "open", "closed", global: true))).to include("global" => true)
      expect { js.toggle_attr("#t", "onclick", "a", "b") }.to raise_error(ArgumentError, /onclick/)
    end

    it "is still gated on the raw-list escape hatch" do
      expect { described_class.assert_ops_allowed!([["toggle_attr", { "name" => "href", "values" => %w[a b] }]]) }
        .to raise_error(ArgumentError, /href/)
    end
  end

  describe "expanded: on show/hide/toggle (mirror the disclosure state into aria-expanded)" do
    def args(chain) = JSON.parse(chain.to_json).dig(0, 1)

    it "records the expanded target on each visibility op" do
      expect(args(js.toggle("#menu", expanded: "#trigger"))).to eq("to" => "#menu", "expanded" => "#trigger")
      expect(args(js.show("#menu", expanded: "#trigger"))["expanded"]).to eq("#trigger")
      expect(args(js.hide("#menu", expanded: "#trigger"))["expanded"]).to eq("#trigger")
    end

    it "translates expanded: :root to the root sentinel" do
      expect(args(js.hide("#menu", expanded: :root))["expanded"]).to eq("@root")
    end

    it "raises for a target that is neither :root nor a selector" do
      expect { js.toggle("#menu", expanded: 123) }.to raise_error(ArgumentError, /target/)
    end

    it "composes with transition: and global:" do
      legs = { during: "t", from: "f", to: "to" }
      expect(args(js.toggle("#menu", expanded: "#trigger", transition: legs, global: true)))
        .to include("expanded" => "#trigger", "global" => true, "transition" => %w[t f to])
    end

    it "keeps the wire byte-identical when omitted" do
      expect(js.toggle("#menu").to_json).to eq('[["toggle",{"to":"#menu"}]]')
    end
  end

  # --- Issue #159: the text op (set textContent — the cross-root text escape) ---

  describe "text op (#text) — textContent only, never innerHTML" do
    it "serializes the target and the stringified value" do
      expect(JSON.parse(js.text("#sum_total", 480).to_json))
        .to eq([["text", { "to" => "#sum_total", "value" => "480" }]])
    end

    it "stringifies nil to an empty string (clears the node, never crashes the client)" do
      expect(JSON.parse(js.text("#sum_total", nil).to_json).dig(0, 1, "value")).to eq("")
    end

    it "carries global: true only when asked (root-scoped is the lean default)" do
      expect(JSON.parse(js.text("#sum_total", 480, global: true).to_json))
        .to eq([["text", { "to" => "#sum_total", "value" => "480", "global" => true }]])
      expect(JSON.parse(js.text("#sum_total", 480).to_json).dig(0, 1)).not_to have_key("global")
    end

    it "accepts :root as the target" do
      expect(JSON.parse(js.text(:root, "done").to_json).dig(0, 1, "to")).to eq("@root")
    end

    it "rejects a target that is neither :root nor a CSS selector string" do
      expect { js.text(:sum_total, 480) }.to raise_error(ArgumentError, /:root or a CSS selector/)
    end
  end
end
