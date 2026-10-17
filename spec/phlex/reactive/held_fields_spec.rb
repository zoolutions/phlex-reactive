# frozen_string_literal: true

require "rails_helper"

# Issue #370: X-Reactive-Held carries the names of the root's fields a morph held
# over a changed server value. The header is untrusted input: names only, parsed
# as a JSON array of strings, capped, and filtered to the params the running
# action declares. Anything malformed reads as "nothing held" — never an error.
RSpec.describe Phlex::Reactive::HeldFields do
  let(:action_def) { HeldNoteComponent.reactive_actions[:save] }

  def parse(raw) = described_class.parse(raw, action_def)

  describe ".parse" do
    it "reads a JSON array of declared param names" do
      expect(parse('["title"]')).to eq(["title"])
    end

    it "is empty without the header, or with a blank one" do
      expect(parse(nil)).to eq([])
      expect(parse("")).to eq([])
    end

    it "drops names the action does not declare" do
      expect(parse('["title","is_admin","version"]')).to eq(%w[title version])
    end

    it "matches a bracketed field name on its base param" do
      nested = TodoItemComponent.reactive_actions[:rename]
      expect(described_class.parse('["title[]","title[en]","other[x]"]', nested)).to eq(%w[title[] title[en]])
    end

    it "reads nothing for an action without a param schema" do
      expect(described_class.parse('["title"]', TodoItemComponent.reactive_actions[:toggle])).to eq([])
    end

    it "is empty for malformed JSON, a non-array, or non-string entries" do
      expect(parse("[title")).to eq([])
      expect(parse('{"title":true}')).to eq([])
      expect(parse('"title"')).to eq([])
      expect(parse('[1, null, ["title"], {"a":1}, "title"]')).to eq(["title"])
    end

    it "dedupes" do
      expect(parse('["title","title"]')).to eq(["title"])
    end

    it "drops an over-long name and caps the count" do
      long = "title[#{"x" * 200}]"
      expect(parse([long].to_json)).to eq([])

      many = Array.new(described_class::MAX_NAMES + 10) { "title[#{it}]" }
      expect(described_class.parse(many.to_json, TodoItemComponent.reactive_actions[:rename]).size)
        .to eq(described_class::MAX_NAMES)
    end

    it "ignores a header over the byte cap without parsing it" do
      raw = %(["title"#{", \"x\"" * 2_000}])
      expect(raw.bytesize).to be > described_class::MAX_BYTES
      expect(JSON).not_to receive(:parse)
      expect(parse(raw)).to eq([])
    end

    it "reads a \\u-escaped non-ASCII name (how the client sends one)" do
      action = Data.define(:params).new(params: { "titel_ä" => :string })
      expect(described_class.parse('["titel_\u00e4"]', action)).to eq(["titel_ä"])
    end

    it "returns a frozen list" do
      expect(parse('["title"]')).to be_frozen
    end
  end

  # Issue #413: a reply that refused the posted values names what the client
  # keeps held, in the X-Reactive-Refused response header.
  describe ".refused_header" do
    it "is * when the reply refused every held field" do
      expect(described_class.refused_header(:all)).to eq("*")
    end

    it "is a JSON list of the refused names" do
      expect(described_class.refused_header(%w[title body])).to eq('["title","body"]')
    end

    it "widens a list past the byte cap to *, so the refusal still reaches the client" do
      many = Array.new(1_000) { "title[#{it}]" }
      expect(described_class.refused_header(many)).to eq("*")
    end

    it "escapes every non-ASCII character, as the client escapes X-Reactive-Held" do
      expect(described_class.refused_header(["titel_ä"])).to eq('["titel_\\u00e4"]')
    end
  end

  describe ".current / .with" do
    it "is an empty list outside a block" do
      expect(described_class.current).to eq([])
    end

    it "exposes the list inside the block and restores the previous one after" do
      described_class.with(["title"]) do
        expect(described_class.current).to eq(["title"])
        described_class.with(["version"]) { expect(described_class.current).to eq(["version"]) }
        expect(described_class.current).to eq(["title"])
      end
      expect(described_class.current).to eq([])
    end
  end

  describe "#reactive_held_fields (component helper)" do
    it "is [] without the header and the current list inside an action" do
      component = HeldNoteComponent.new(todo: Todo.new(title: "x"))
      expect(component.reactive_held_fields).to eq([])
      described_class.with(["title"]) { expect(component.reactive_held_fields).to eq(["title"]) }
    end
  end
end
