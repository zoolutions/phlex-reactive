# frozen_string_literal: true

require "spec_helper"
require "phlex"

# Issue #434: reactive_shared_field marks a control inside a nested reactive
# component so the host component's actions post it too. The helper only
# renders attributes: a verbatim name (the host's param, never re-scoped), the
# value, and the data-reactive-shared-field marker the client looks for.
RSpec.describe Phlex::Reactive::Component::SharedField do
  let(:klass) do
    Class.new(Phlex::HTML) do
      include Phlex::Reactive::Component

      reactive_scope :picker
      reactive_state :value

      def self.name = "SharedPicker"

      def initialize(value: nil)
        @value = value
        super()
      end

      def id = "picker"

      def view_template
        div(**reactive_root) do
          input(type: "hidden", **reactive_shared_field(name: "item[choice]", value: @value))
        end
      end
    end
  end

  let(:view) { klass.new(value: "b") }

  it "binds the name verbatim, the value and the marker" do
    expect(view.reactive_shared_field(name: "item[choice]", value: "b"))
      .to eq(name: "item[choice]", value: "b", data: { reactive_shared_field: true })
  end

  it "never re-scopes the name under the component's own reactive_scope" do
    expect(view.reactive_shared_field(name: "choice")[:name]).to eq("choice")
  end

  it "takes a Symbol name" do
    expect(view.reactive_shared_field(name: :choice)[:name]).to eq("choice")
  end

  it "leaves value out when it is nil" do
    expect(view.reactive_shared_field(name: "item[choice]")).not_to have_key(:value)
  end

  it "merges extra attrs, deep-merging data:" do
    attrs = view.reactive_shared_field(name: "item[choice]", value: "b", id: "choice", data: { testid: "choice" })
    expect(attrs).to eq(name: "item[choice]", value: "b", id: "choice",
      data: { reactive_shared_field: true, testid: "choice" })
  end

  it "renders a bare data-reactive-shared-field attribute" do
    html = klass.new(value: "b").call
    expect(html).to include('<input type="hidden" name="item[choice]" value="b" data-reactive-shared-field>')
  end

  it "renders no value attribute for a nil value" do
    html = klass.new.call
    expect(html).to include('<input type="hidden" name="item[choice]" data-reactive-shared-field>')
  end

  [nil, "", "  ", :"", false, true, 1].each do |bad|
    it "raises at render for a blank or non-String/Symbol name (#{bad.inspect})" do
      expect { view.reactive_shared_field(name: bad) }
        .to raise_error(ArgumentError, /reactive_shared_field needs a non-blank String or Symbol name:/)
    end
  end
end
