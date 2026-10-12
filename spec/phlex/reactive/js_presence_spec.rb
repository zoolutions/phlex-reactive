# frozen_string_literal: true

require "rails_helper"

# Issue #358: js.presence(**state) writes this tab's presence state through
# the root's generated presence_set action. Actor-only: a broadcast that set
# every subscriber's selection would be hostile.
RSpec.describe Phlex::Reactive::JS do
  subject(:js) { described_class.new }

  it "serializes a root-targeted op carrying the state" do
    expect(JSON.parse(js.presence(selected: 7).to_json))
      .to eq([["presence", { "to" => "@root", "state" => { "selected" => 7 } }]])
  end

  it "takes scalar values only and at least one key" do
    expect { js.presence }.to raise_error(ArgumentError, /at least one/)
    expect { js.presence(selected: [1]) }.to raise_error(ArgumentError, /scalar/)
    expect(JSON.parse(js.presence(selected: nil).to_json).dig(0, 1, "state")).to eq("selected" => nil)
  end

  it "refuses NaN and infinities (no JSON form), keeps finite floats" do
    expect { js.presence(selected: Float::NAN) }.to raise_error(ArgumentError, /finite|scalar/)
    expect { js.presence(selected: Float::INFINITY) }.to raise_error(ArgumentError, /finite|scalar/)
    expect(JSON.parse(js.presence(selected: 1.5).to_json).dig(0, 1, "state")).to eq("selected" => 1.5)
  end

  it "is refused on a broadcast" do
    expect { TodoItemComponent.broadcast_to("alerts", js: js.presence(selected: 1)) }
      .to raise_error(ArgumentError, /presence/)
  end
end
