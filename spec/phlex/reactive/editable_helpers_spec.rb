# frozen_string_literal: true

require "spec_helper"
require "phlex"

# Issue #351: reactive_editable — a contenteditable element as a first-class,
# plain-text field. The helper renders the attributes onto the app's own
# element; the client collects its text (line breaks kept), holds its text and
# caret through a morph while focused, pastes plain text, and handles Enter /
# Escape. Client-only: available on ClientBindings, no token.
RSpec.describe Phlex::Reactive::Component::Editable do
  let(:klass) do
    Class.new(Phlex::HTML) do
      include Phlex::Reactive::ClientBindings

      def self.name = "EditableThing"

      def view_template
        div(**reactive_root) do
          h3(**reactive_editable(:title, placeholder: "Untitled")) { "Hello" }
        end
      end
    end
  end

  let(:scoped_klass) do
    Class.new(klass) do
      reactive_scope :card
    end
  end

  let(:view) { klass.new }
  let(:js) { Phlex::Reactive::JS.new }

  describe "the default single-line field" do
    subject(:attrs) { view.reactive_editable(:title) }

    it "binds the param name, plain-text editing and a textbox role" do
      expect(attrs).to include(name: "title", contenteditable: "plaintext-only", role: "textbox")
    end

    it "is single-line and reverts on Escape by default" do
      expect(attrs[:aria]).to eq(multiline: "false")
      expect(attrs[:data]).to eq(reactive_editable: "single", reactive_editable_escape: "revert")
    end

    it "leaves spellcheck to the browser default" do
      expect(attrs).not_to have_key(:spellcheck)
    end
  end

  it "uses the scoped wire name under reactive_scope, like reactive_field" do
    expect(scoped_klass.new.reactive_editable(:title)[:name]).to eq("card[title]")
  end

  it "marks a multiline field for the client and for assistive tech" do
    attrs = view.reactive_editable(:summary, multiline: true)
    expect(attrs[:aria]).to eq(multiline: "true")
    expect(attrs[:data][:reactive_editable]).to eq("multi")
  end

  it "renders the placeholder for CSS and for assistive tech" do
    attrs = view.reactive_editable(:title, placeholder: "Untitled")
    expect(attrs[:aria]).to include(placeholder: "Untitled")
    expect(attrs[:data]).to include(reactive_placeholder: "Untitled")
  end

  it "serializes on_enter: ops as the on_client op list" do
    attrs = view.reactive_editable(:title, on_enter: js.focus("#next"))
    expect(JSON.parse(attrs[:data][:reactive_editable_enter])).to eq([["focus", { "to" => "#next" }]])
  end

  it "takes on_enter: :submit" do
    expect(view.reactive_editable(:title, on_enter: :submit)[:data][:reactive_editable_enter]).to eq("submit")
  end

  it "drops the Escape revert with on_escape: nil" do
    expect(view.reactive_editable(:title, on_escape: nil)[:data]).not_to have_key(:reactive_editable_escape)
  end

  it "renders spellcheck=false when asked" do
    expect(view.reactive_editable(:title, spellcheck: false)[:spellcheck]).to eq("false")
  end

  it "merges the caller's attributes (mix: data deep-merges, an explicit name wins)" do
    attrs = view.reactive_editable(:title, name: "raw", class: "h3", data: { testid: "t" })
    expect(attrs).to include(name: "raw", class: "h3")
    expect(attrs[:data]).to include(testid: "t", reactive_editable: "single")
  end

  it "composes with on() through mix without clobbering its data-action" do
    component = Class.new(Phlex::HTML) do
      include Phlex::Reactive::Component

      def self.name = "EditableActor"

      reactive_state :card
      action :rename, params: { title: :string }
      def initialize(card:) = @card = card
      def rename(title:) = @card = title
      def id = "actor"

      def view_template
        div(**reactive_root) do
          h3(**mix(reactive_editable(:title), on(:rename, event: "input", debounce: 300))) { "x" }
        end
      end
    end
    html = component.new(card: 1).call
    expect(html).to include('data-reactive-editable="single"')
    expect(html).to match(/data-action="[^"]*input->reactive#dispatch/)
  end

  it "carries its own trackDirty descriptor when reactive_dirty only: names it" do
    tracked = Class.new(klass) { reactive_dirty only: %i[title] }
    expect(tracked.new.reactive_editable(:title)[:data][:action]).to eq("input->reactive#trackDirty")
    expect(tracked.new.reactive_editable(:summary)[:data]).not_to have_key(:action)
  end

  describe "argument errors" do
    it "refuses an on_enter: that is not a JS chain or :submit" do
      expect { view.reactive_editable(:title, on_enter: "blur") }
        .to raise_error(ArgumentError, /on_enter: takes a Phlex::Reactive::JS chain .* or :submit/)
    end

    it "refuses an empty JS chain (a dead Enter)" do
      expect { view.reactive_editable(:title, on_enter: js) }.to raise_error(ArgumentError, /no ops/)
    end

    it "refuses an on_escape: other than :revert or nil" do
      expect { view.reactive_editable(:title, on_escape: :blur) }
        .to raise_error(ArgumentError, /on_escape: takes :revert or nil/)
    end

    it "refuses a blank name" do
      expect { view.reactive_editable("") }.to raise_error(ArgumentError, /needs a param name/)
    end
  end

  it "renders through a ClientBindings root (token-less)" do
    html = view.call
    expect(html).to include('contenteditable="plaintext-only"', 'name="title"', 'data-reactive-placeholder="Untitled"')
    expect(html).not_to include("data-reactive-token-value")
  end
end
