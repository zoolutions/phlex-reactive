# frozen_string_literal: true

require "spec_helper"
require "phlex"
require "active_support/core_ext/numeric/time"

# Issue #239: reactive_persist — a client-only localStorage draft over the
# fields a root OWNS. One root-level JSON wire attr (the reactive_show_targets
# shape), a per-control skip marker, no token, no POST, no expression surface.
RSpec.describe Phlex::Reactive::Component::Helpers, "#reactive_persist (issue #239)" do
  let(:klass) do
    Class.new(Phlex::HTML) do
      include Phlex::Reactive::ClientBindings

      def self.name = "PersistThing"

      reactive_scope :form

      def view_template = nil
    end
  end

  let(:component) { klass.new }

  def payload(**)
    JSON.parse(component.send(:reactive_persist, **)[:data][:reactive_persist])
  end

  it "emits ONE JSON wire attr with key, ttl in seconds and the default debounce" do
    expect(payload(key: "village-apply", ttl: 7.days))
      .to eq("key" => "village-apply", "ttl" => 604_800, "debounce" => 300)
  end

  it "defaults ttl to 7 days" do
    expect(payload(key: "k")["ttl"]).to eq(604_800)
  end

  it "accepts an Integer ttl (seconds)" do
    expect(payload(key: "k", ttl: 60)["ttl"]).to eq(60)
  end

  it "omits restore: by default (byte-stable wire) and emits it for :always" do
    expect(payload(key: "k")).not_to have_key("restore")
    expect(payload(key: "k", restore: :always)["restore"]).to eq("always")
    expect(payload(key: "k", restore: :blank)).not_to have_key("restore")
  end

  it "compiles fields: through the declared scope (the reactive_show field form)" do
    expect(payload(key: "k", fields: %i[name size])["fields"]).to eq(%w[form[name] form[size]])
  end

  it "omits fields: when not narrowed" do
    expect(payload(key: "k")).not_to have_key("fields")
  end

  it "honours a custom debounce" do
    expect(payload(key: "k", debounce: 50)["debounce"]).to eq(50)
  end

  # Issue #397: storage: picks the browser store. :local (the default) keeps
  # today's wire byte-identical; :session adds one key.
  describe "storage: (issue #397)" do
    it "omits storage for the default, :local and \"local\" (byte-stable wire)" do
      expect(payload(key: "k")).not_to have_key("storage")
      expect(payload(key: "k", storage: :local)).not_to have_key("storage")
      expect(payload(key: "k", storage: "local")).not_to have_key("storage")
      expect(component.send(:reactive_persist, key: "k", storage: :local))
        .to eq(component.send(:reactive_persist, key: "k"))
    end

    it "emits storage: session for :session and \"session\"" do
      expect(payload(key: "k", storage: :session)["storage"]).to eq("session")
      expect(payload(key: "k", storage: "session")["storage"]).to eq("session")
    end

    it "rejects any other store at render" do
      expect { payload(key: "k", storage: :cookie) }.to raise_error(ArgumentError, /storage/)
      expect { payload(key: "k", storage: "Session") }.to raise_error(ArgumentError, /storage/)
      expect { payload(key: "k", storage: nil) }.to raise_error(ArgumentError, /storage/)
    end
  end

  it "is a client-only binding: no token, no id, works from ClientBindings" do
    attrs = component.send(:reactive_persist, key: "k")
    expect(attrs.keys).to eq([:data])
    expect(attrs[:data].keys).to eq([:reactive_persist])
  end

  it "mixes over reactive_root without clobbering the controller data" do
    attrs = component.send(:mix, component.send(:reactive_root), component.send(:reactive_persist, key: "k"))
    expect(attrs[:data][:controller]).to eq("reactive")
    expect(attrs[:data][:reactive_scope]).to eq("form")
    expect(JSON.parse(attrs[:data][:reactive_persist])["key"]).to eq("k")
  end

  describe "render-time validation (a dead binding must fail loudly)" do
    it "rejects a blank or non-String key" do
      expect { payload(key: "") }.to raise_error(ArgumentError, /key/)
      expect { payload(key: nil) }.to raise_error(ArgumentError, /key/)
      expect { payload(key: :sym) }.to raise_error(ArgumentError, /key/)
    end

    it "rejects a non-positive or non-numeric ttl" do
      expect { payload(key: "k", ttl: 0) }.to raise_error(ArgumentError, /ttl/)
      expect { payload(key: "k", ttl: -1.day) }.to raise_error(ArgumentError, /ttl/)
      expect { payload(key: "k", ttl: "7") }.to raise_error(ArgumentError, /ttl/)
    end

    it "rejects an unknown restore: mode" do
      expect { payload(key: "k", restore: :server) }.to raise_error(ArgumentError, /restore/)
    end

    it "rejects an empty fields: list" do
      expect { payload(key: "k", fields: []) }.to raise_error(ArgumentError, /fields/)
    end

    it "rejects a negative debounce" do
      expect { payload(key: "k", debounce: -1) }.to raise_error(ArgumentError, /debounce/)
    end
  end

  describe "#reactive_persist_skip" do
    it "marks a control as never persisted" do
      expect(component.send(:reactive_persist_skip)).to eq(data: { reactive_persist: "off" })
    end
  end
end
