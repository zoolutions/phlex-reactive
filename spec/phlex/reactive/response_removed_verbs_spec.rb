# frozen_string_literal: true

require "rails_helper"

# Issue #182: `reply` is the ONE documented door. The Response CLASS verbs
# (Response.replace/morph/update/remove/redirect/with/streams and the collection
# class methods) are removed as public entry points — each raises a guided
# ArgumentError naming the `reply.<verb>` rewrite. The immutable Response value
# object (Response.new + its instance chain .flash/.stream/.also/.js/.defer) is
# UNCHANGED; the endpoint still reads it. These specs lock the stubs.
RSpec.describe Phlex::Reactive::Response, "class verbs are removed (issue #182)" do
  let(:counter) { CounterComponent.new(count: 0) }

  # Each class verb → the reply.<verb> it points at.
  {
    replace: "reply.replace",
    morph: "reply.morph",
    update: "reply.update",
    remove: "reply.remove",
    redirect: "reply.redirect",
    with: "reply.with",
    streams: "reply.streams"
  }.each do |verb, rewrite|
    it "Response.#{verb} raises a guided error naming #{rewrite}" do
      expect { described_class.public_send(verb, counter) }
        .to raise_error(ArgumentError, /#{Regexp.escape(rewrite)}/)
    end
  end

  it "the guided error names the removal (issue #182 reference)" do
    expect { described_class.replace(counter) }
      .to raise_error(ArgumentError, /removed|reply\.replace/)
  end

  # The block param `verb` is referenced in the `it` description AND the call; `it` would shadow RSpec's own `it`.
  %i[collection_append collection_prepend collection_remove].each do |verb|
    it "Response.#{verb} raises a guided error naming reply" do
      expect { described_class.public_send(verb, counter, :items, nil) }
        .to raise_error(ArgumentError, /reply\./)
    end
  end

  it "keeps Response.new as the constructor (the value object is unchanged)" do
    response = described_class.new(streams: ["<turbo-stream></turbo-stream>"])
    expect(response).to be_a(described_class)
    expect(response).to be_frozen
    expect(response.streams).to eq(["<turbo-stream></turbo-stream>"])
  end

  it "keeps the instance chain (.flash/.stream) working on a reply-built Response" do
    response = counter.reply.replace.flash(:notice, "hi")
    expect(response.streams.size).to eq(2)
    expect(response.streams.last).to include("hi")
  end
end
