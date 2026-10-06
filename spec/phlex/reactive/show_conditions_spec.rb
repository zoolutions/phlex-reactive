# frozen_string_literal: true

require "spec_helper"
require "phlex/reactive/show_conditions"

# Issue #180 Phase A: the ONE conditions language behind reactive_show /
# reactive_show_targets. `normalize(if:, if_any:, unless:)` compiles Ruby-native
# values (Hash = AND, Array = membership, Range = threshold; unless: = negation)
# into a DNF wire shape — an array of GROUPS, terms ANDed within a group, groups
# ORed. `match?(groups, values)` evaluates it in Ruby with semantics identical to
# the client (the shared fixture proves the parity). No expression surface: every
# term is a declared literal predicate, exactly the pre-#180 posture.
RSpec.describe Phlex::Reactive::ShowConditions do
  # Helpers under test are module functions.
  def normalize(**) = described_class.normalize(**)
  def match?(groups, values) = described_class.match?(groups, values)

  describe ".normalize — the value language" do
    it "compiles an if: Hash to ONE group of ANDed equals terms" do
      expect(normalize(if: { type: "individual" }))
        .to eq([[{ "field" => "type", "equals" => "individual" }]])
    end

    it "ANDs multiple keys within one if: group" do
      expect(normalize(if: { type: "individual", role: "director" }))
        .to eq([[
          { "field" => "type", "equals" => "individual" },
          { "field" => "role", "equals" => "director" }
        ]])
    end

    it "maps true/false to the checkbox checked-state string" do
      expect(normalize(if: { gift: true })).to eq([[{ "field" => "gift", "equals" => "true" }]])
      expect(normalize(if: { gift: false })).to eq([[{ "field" => "gift", "equals" => "false" }]])
    end

    it "maps nil to the empty string (visible while blank)" do
      expect(normalize(if: { note: nil })).to eq([[{ "field" => "note", "equals" => "" }]])
    end

    it "stringifies symbols and numbers in equals position" do
      expect(normalize(if: { kind: :premium })).to eq([[{ "field" => "kind", "equals" => "premium" }]])
      expect(normalize(if: { qty: 3 })).to eq([[{ "field" => "qty", "equals" => "3" }]])
    end

    it "maps an Array to a membership (in) term of stringified values" do
      expect(normalize(if: { size: [:l, "xl", 2] }))
        .to eq([[{ "field" => "size", "in" => %w[l xl 2] }]])
    end

    it "maps an endless Range to gte" do
      expect(normalize(if: { quantity: 10.. })).to eq([[{ "field" => "quantity", "gte" => 10 }]])
    end

    it "maps a beginless inclusive Range to lte" do
      expect(normalize(if: { amount: ..5000 })).to eq([[{ "field" => "amount", "lte" => 5000 }]])
    end

    it "maps a beginless exclusive Range to lt" do
      expect(normalize(if: { amount: ...5000 })).to eq([[{ "field" => "amount", "lt" => 5000 }]])
    end

    it "maps a bounded inclusive Range to TWO terms (gte + lte) in one group" do
      expect(normalize(if: { score: 10..20 }))
        .to eq([[
          { "field" => "score", "gte" => 10 },
          { "field" => "score", "lte" => 20 }
        ]])
    end

    it "maps a bounded exclusive-end Range to gte + lt" do
      expect(normalize(if: { score: 10...20 }))
        .to eq([[
          { "field" => "score", "gte" => 10 },
          { "field" => "score", "lt" => 20 }
        ]])
    end
  end

  describe ".normalize — if_any: (DNF)" do
    it "compiles an array of AND-hashes to one group each (OR of ANDs)" do
      expect(normalize(if_any: [{ director: true }, { shareholder: true, role: "individual" }]))
        .to eq([
          [{ "field" => "director", "equals" => "true" }],
          [{ "field" => "shareholder", "equals" => "true" }, { "field" => "role", "equals" => "individual" }]
        ])
    end
  end

  describe ".normalize — unless: (negation, composes with if:/if_any:)" do
    it "ANDs a negated scalar (not) into the single if: group" do
      expect(normalize(if: { shareholder: true }, unless: { director: true }))
        .to eq([[
          { "field" => "shareholder", "equals" => "true" },
          { "field" => "director", "not" => "true" }
        ]])
    end

    it "distributes unless: into EVERY if_any: group" do
      expect(normalize(if_any: [{ a: "1" }, { b: "2" }], unless: { c: "3" }))
        .to eq([
          [{ "field" => "a", "equals" => "1" }, { "field" => "c", "not" => "3" }],
          [{ "field" => "b", "equals" => "2" }, { "field" => "c", "not" => "3" }]
        ])
    end

    it "works standalone (unless: only, no if:) — negated terms over an implicit all-true group" do
      expect(normalize(unless: { mode: "off" }))
        .to eq([[{ "field" => "mode", "not" => "off" }]])
    end

    it "expands an unless: Array to N not-terms (∉ = AND of nots) in each group" do
      expect(normalize(unless: { role: %w[a b] }))
        .to eq([[{ "field" => "role", "not" => "a" }, { "field" => "role", "not" => "b" }]])
    end

    it "complements an unless: endless Range (¬gte → lt)" do
      expect(normalize(unless: { qty: 10.. })).to eq([[{ "field" => "qty", "lt" => 10 }]])
    end

    it "complements an unless: beginless inclusive Range (¬lte → gt)" do
      expect(normalize(unless: { qty: ..10 })).to eq([[{ "field" => "qty", "gt" => 10 }]])
    end

    it "complements an unless: beginless exclusive Range (¬lt → gte)" do
      expect(normalize(unless: { qty: ...10 })).to eq([[{ "field" => "qty", "gte" => 10 }]])
    end

    it "splits an unless: bounded Range into TWO groups (¬(a≤x≤b) = x<a ∨ x>b)" do
      # De Morgan across a single all-true base group → two groups.
      expect(normalize(unless: { score: 10..20 }))
        .to eq([
          [{ "field" => "score", "lt" => 10 }],
          [{ "field" => "score", "gt" => 20 }]
        ])
    end

    it "multiplies groups when a bounded-range unless: distributes over an if: group" do
      # (a) ∧ ¬(10≤x≤20) = (a ∧ x<10) ∨ (a ∧ x>20)
      expect(normalize(if: { a: "1" }, unless: { score: 10..20 }))
        .to eq([
          [{ "field" => "a", "equals" => "1" }, { "field" => "score", "lt" => 10 }],
          [{ "field" => "a", "equals" => "1" }, { "field" => "score", "gt" => 20 }]
        ])
    end

    it "obeys De Morgan for a MULTI-FIELD unless: — ¬(a ∧ b) = ¬a ∨ ¬b (two groups)" do
      # A multi-key unless: hash negates an AND, so it must expand to a
      # DISJUNCTION, not a conjunction of the two nots.
      expect(normalize(unless: { a: 1, b: 2 }))
        .to eq([
          [{ "field" => "a", "not" => "1" }],
          [{ "field" => "b", "not" => "2" }]
        ])
    end

    it "distributes a multi-field unless: over an if: group as (P ∧ ¬a) ∨ (P ∧ ¬b)" do
      expect(normalize(if: { p: "1" }, unless: { a: 2, b: 3 }))
        .to eq([
          [{ "field" => "p", "equals" => "1" }, { "field" => "a", "not" => "2" }],
          [{ "field" => "p", "equals" => "1" }, { "field" => "b", "not" => "3" }]
        ])
    end

    it "raises on an empty Array value under unless: (same rule as if:)" do
      expect { normalize(unless: { role: [] }) }
        .to raise_error(ArgumentError, /needs at least one value/)
    end
  end

  # Issue #226: the length: value form — a Hash value names a structural
  # predicate over the field's CODEPOINT count. { length: 6 } is exact;
  # Integer Ranges reuse the threshold vocabulary with len_* wire keys.
  describe ".normalize — the length: value form (issue #226)" do
    it "compiles { length: N } to a len_eq term" do
      expect(normalize(if: { code: { length: 6 } }))
        .to eq([[{ "field" => "code", "len_eq" => 6 }]])
    end

    it "compiles an endless length range to len_gte" do
      expect(normalize(if: { code: { length: 6.. } }))
        .to eq([[{ "field" => "code", "len_gte" => 6 }]])
    end

    it "compiles a beginless exclusive length range to len_lt" do
      expect(normalize(if: { code: { length: ...6 } }))
        .to eq([[{ "field" => "code", "len_lt" => 6 }]])
    end

    it "compiles a bounded length range to gte+lte terms in ONE group" do
      expect(normalize(if: { code: { length: 4..8 } }))
        .to eq([[{ "field" => "code", "len_gte" => 4 }, { "field" => "code", "len_lte" => 8 }]])
    end

    it "ANDs a length term with its sibling fields in the same group" do
      expect(normalize(if: { code: { length: 6 }, kind: "sms" }))
        .to eq([[{ "field" => "code", "len_eq" => 6 }, { "field" => "kind", "equals" => "sms" }]])
    end

    it "negates { length: N } under unless: to the len_lt OR len_gt disjunction" do
      expect(normalize(unless: { code: { length: 6 } }))
        .to eq([[{ "field" => "code", "len_lt" => 6 }], [{ "field" => "code", "len_gt" => 6 }]])
    end

    it "negates a bounded length range under unless: to the outside disjunction" do
      expect(normalize(unless: { code: { length: 4..8 } }))
        .to eq([[{ "field" => "code", "len_lt" => 4 }], [{ "field" => "code", "len_gt" => 8 }]])
    end

    it "negates an endless length range under unless: to the single complement" do
      expect(normalize(unless: { code: { length: 6.. } }))
        .to eq([[{ "field" => "code", "len_lt" => 6 }]])
    end

    it "rejects a non-Integer length literal" do
      expect { normalize(if: { code: { length: "6" } }) }.to raise_error(ArgumentError, /length/)
      expect { normalize(if: { code: { length: 6.5 } }) }.to raise_error(ArgumentError, /length/)
    end

    it "rejects a negative length" do
      expect { normalize(if: { code: { length: -1 } }) }.to raise_error(ArgumentError, /length/)
    end

    it "rejects a non-Integer length Range endpoint" do
      expect { normalize(if: { code: { length: 1.5..8 } }) }.to raise_error(ArgumentError, /length/)
    end

    it "rejects a Hash value with keys other than length: (loud, never silent)" do
      expect { normalize(if: { code: { min: 6 } }) }.to raise_error(ArgumentError, /length/)
      expect { normalize(unless: { code: { min: 6 } }) }.to raise_error(ArgumentError, /length/)
    end

    it "rejects an empty Hash value" do
      expect { normalize(if: { code: {} }) }.to raise_error(ArgumentError, /length/)
    end

    it "evaluates length by CODEPOINTS (multibyte-safe, mirrors the client)" do
      groups = normalize(if: { note: { length: 2 } })
      expect(match?(groups, { "note" => "😀🎈" })).to be(true)
      expect(match?(groups, { "note" => "ab" })).to be(true)
      expect(match?(groups, { "note" => "abc" })).to be(false)
    end

    it "treats a blank/absent field as length 0" do
      groups = normalize(if: { code: { length: 0 } })
      expect(match?(groups, {})).to be(true)
      expect(match?(groups, { "code" => "x" })).to be(false)
    end
  end

  # Issue #319: the checked: value form — counts the TICKED boxes of a checkbox
  # group. The same Integer / Integer-Range shapes as length:, on checked_* keys.
  describe ".normalize — the checked: value form (issue #319)" do
    it "compiles { checked: N } to a checked_eq term" do
      expect(normalize(if: { "ids[]" => { checked: 2 } }))
        .to eq([[{ "field" => "ids[]", "checked_eq" => 2 }]])
    end

    it "compiles an endless checked range to checked_gte" do
      expect(normalize(if: { "ids[]" => { checked: 1.. } }))
        .to eq([[{ "field" => "ids[]", "checked_gte" => 1 }]])
    end

    it "compiles a bounded checked range to gte+lte terms in ONE group" do
      expect(normalize(if: { "ids[]" => { checked: 1..3 } }))
        .to eq([[{ "field" => "ids[]", "checked_gte" => 1 }, { "field" => "ids[]", "checked_lte" => 3 }]])
    end

    it "compiles a beginless exclusive checked range to checked_lt" do
      expect(normalize(if: { "ids[]" => { checked: ...3 } }))
        .to eq([[{ "field" => "ids[]", "checked_lt" => 3 }]])
    end

    it "negates { checked: N } under unless: to the checked_lt OR checked_gt disjunction" do
      expect(normalize(unless: { "ids[]" => { checked: 0 } }))
        .to eq([[{ "field" => "ids[]", "checked_lt" => 0 }], [{ "field" => "ids[]", "checked_gt" => 0 }]])
    end

    it "negates an endless checked range under unless: to the single complement" do
      expect(normalize(unless: { "ids[]" => { checked: 1.. } }))
        .to eq([[{ "field" => "ids[]", "checked_lt" => 1 }]])
    end

    it "negates a bounded checked range under unless: to the outside disjunction" do
      expect(normalize(unless: { "ids[]" => { checked: 1...3 } }))
        .to eq([[{ "field" => "ids[]", "checked_lt" => 1 }], [{ "field" => "ids[]", "checked_gte" => 3 }]])
    end

    it "rejects a non-Integer or negative checked literal" do
      expect { normalize(if: { "ids[]" => { checked: "1" } }) }.to raise_error(ArgumentError, /checked/)
      expect { normalize(if: { "ids[]" => { checked: -1 } }) }.to raise_error(ArgumentError, /checked/)
      expect { normalize(if: { "ids[]" => { checked: 1.5.. } }) }.to raise_error(ArgumentError, /checked/)
    end

    it "rejects a Hash naming both length: and checked:" do
      expect { normalize(if: { "ids[]" => { checked: 1, length: 2 } }) }
        .to raise_error(ArgumentError, /length: or checked:/)
    end

    it "counts an Array value (the checked values reactive_values provides)" do
      groups = normalize(if: { "ids[]" => { checked: 1.. } })
      expect(match?(groups, { "ids[]" => %w[3 7] })).to be(true)
      expect(match?(groups, { "ids[]" => [] })).to be(false)
    end

    it "counts an Integer value (a count reactive_values provides) and true/false" do
      groups = normalize(if: { "ids[]" => { checked: 2 } })
      expect(match?(groups, { "ids[]" => "2" })).to be(true)
      expect(match?(groups, { "ids[]" => 2 })).to be(true)
      expect(match?(normalize(if: { gift: { checked: 1 } }), { "gift" => "true" })).to be(true)
      expect(match?(normalize(if: { gift: { checked: 0 } }), { "gift" => "false" })).to be(true)
    end

    it "treats an absent group as zero ticked" do
      groups = normalize(if: { "ids[]" => { checked: 0 } })
      expect(match?(groups, {})).to be(true)
    end
  end

  describe ".normalize — loud validation" do
    it "raises on an empty if: hash" do
      expect { normalize(if: {}) }.to raise_error(ArgumentError, /if: needs at least one field/)
    end

    it "raises on an empty if_any: array" do
      expect { normalize(if_any: []) }.to raise_error(ArgumentError, /if_any: needs at least one/)
    end

    it "raises on an empty group inside if_any:" do
      expect { normalize(if_any: [{ a: 1 }, {}]) }.to raise_error(ArgumentError, /each if_any: group needs/)
    end

    it "raises on an empty Array value (matches nothing)" do
      expect { normalize(if: { size: [] }) }.to raise_error(ArgumentError, /needs at least one value/)
    end

    it "raises on a non-Numeric Range endpoint" do
      expect { normalize(if: { d: "a".."z" }) }.to raise_error(ArgumentError, /Range endpoints must be numbers/)
    end

    it "raises when if: and if_any: are given together" do
      expect { normalize(if: { a: 1 }, if_any: [{ b: 2 }]) }
        .to raise_error(ArgumentError, %r{exactly one of if:/if_any:})
    end

    it "raises when no condition at all is given" do
      expect { normalize }.to raise_error(ArgumentError, /needs if:, if_any:, or unless:/)
    end
  end

  describe ".match? — Ruby evaluation mirrors the client" do
    let(:groups) do
      normalize(if_any: [{ director: true }, { shareholder: true, role: "individual" }])
    end

    it "is true when any group's every term matches" do
      expect(match?(groups, { "director" => "true" })).to be(true)
      expect(match?(groups, { "shareholder" => "true", "role" => "individual" })).to be(true)
    end

    it "is false when no group fully matches" do
      expect(match?(groups, { "director" => "false", "shareholder" => "true", "role" => "company" })).to be(false)
    end

    it "evaluates in: membership, numeric thresholds, and not" do
      g = normalize(if: { size: %w[l xl], quantity: 10.. }, unless: { mode: "off" })
      expect(match?(g, { "size" => "l", "quantity" => "12", "mode" => "on" })).to be(true)
      expect(match?(g, { "size" => "m", "quantity" => "12", "mode" => "on" })).to be(false)
      expect(match?(g, { "size" => "l", "quantity" => "3",  "mode" => "on" })).to be(false)
      expect(match?(g, { "size" => "l", "quantity" => "12", "mode" => "off" })).to be(false)
    end

    it "treats a blank/non-numeric value as NOT matching a numeric term (fail-closed)" do
      g = normalize(if: { quantity: 10.. })
      expect(match?(g, { "quantity" => "" })).to be(false)
      expect(match?(g, { "quantity" => "abc" })).to be(false)
    end

    it "fail-closes an unless: numeric complement on a blank value (stays hidden)" do
      # unless: { qty: 10.. } → lt: 10. A blank qty is NaN → the lt term is
      # false → group false → hidden. The complement must NOT flip a blank to
      # visible.
      g = normalize(unless: { qty: 10.. })
      expect(match?(g, { "qty" => "" })).to be(false)
    end

    it "returns false when a referenced field is absent from values" do
      g = normalize(if: { director: true })
      expect(match?(g, {})).to be(false)
    end

    it "evaluates a multi-field unless: as the negation of an AND (De Morgan)" do
      # unless: { a: 1, b: 2 } — hide ONLY when a==1 AND b==2; show otherwise.
      g = normalize(unless: { a: 1, b: 2 })
      expect(match?(g, { "a" => "1", "b" => "2" })).to be(false) # both match → hidden
      expect(match?(g, { "a" => "1", "b" => "9" })).to be(true)  # only a → shown
      expect(match?(g, { "a" => "9", "b" => "2" })).to be(true)  # only b → shown
      expect(match?(g, { "a" => "9", "b" => "9" })).to be(true)  # neither → shown
    end
  end

  describe ".fields — the referenced field set (drives reactive_values coverage)" do
    it "collects every field named across all groups and terms" do
      g = normalize(if_any: [{ director: true }, { shareholder: true, role: "individual" }], unless: { blocked: true })
      expect(described_class.fields(g)).to contain_exactly("director", "shareholder", "role", "blocked")
    end
  end
end
