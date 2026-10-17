# frozen_string_literal: true

require "rails_helper"

# Issue #413: a reply that answers the posted values without storing them says
# so, and the client keeps the root's held marks (issue #370) instead of
# releasing them as it does after every other reply. The Response only records
# the refusal; the endpoint sends it as the X-Reactive-Refused header.
RSpec.describe Phlex::Reactive::Response, "#refused" do
  let(:counter) { CounterComponent.new(count: 0) }
  let(:totals) { CounterComponent.new(count: 42) }

  it "is not refused by default" do
    response = counter.reply.morph

    expect(response).not_to be_refused
    expect(response.refused_fields).to be_nil
  end

  it "refuses every held field when given no names" do
    response = counter.reply.morph.refused

    expect(response).to be_refused
    expect(response.refused_fields).to eq(:all)
  end

  it "refuses only the named fields, as strings" do
    response = counter.reply.morph.refused("title", :body)

    expect(response).to be_refused
    expect(response.refused_fields).to eq(%w[title body])
    expect(response.refused_fields).to be_frozen
    expect(response.refused_fields).to all(be_frozen)
  end

  it "takes a list, so reactive_held_fields passes straight through" do
    expect(counter.reply.morph.refused(%w[title title body]).refused_fields).to eq(%w[title body])
  end

  it "returns a NEW frozen Response and leaves the reply's streams alone" do
    base = counter.reply.morph
    refused = base.refused

    expect(refused).not_to equal(base)
    expect(refused).to be_frozen
    expect(base).not_to be_refused
    expect(refused.streams).to eq(base.streams)
    expect(refused.subject_component).to equal(counter)
    expect(refused.render_self?).to be(true)
  end

  it "survives every chained modifier" do
    response = counter.reply.morph.refused("title")
      .flash(:error, "Someone else changed the title")
      .stream("<turbo-stream></turbo-stream>")
      .also(heading: "x")
      .defer(totals)

    expect(response.refused_fields).to eq(["title"])
    expect(response.streams.size).to eq(4)
    expect(response.deferred_segments.size).to eq(1)
  end

  it "can come last in the chain" do
    response = counter.reply.morph.flash(:error, "Someone else changed the title").refused

    expect(response.refused_fields).to eq(:all)
    expect(response.streams.size).to eq(2)
  end

  it "is dead on a redirect: the page navigates away and holds nothing" do
    expect { counter.reply.redirect("/x").refused }
      .to raise_error(Phlex::Reactive::Error, /redirect/)
  end
end
