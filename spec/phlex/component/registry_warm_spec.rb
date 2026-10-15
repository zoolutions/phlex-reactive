# frozen_string_literal: true

require "rails_helper"

# Component::Registry.warm! (zoolutions/phlex-reactive#364): the engine resolves
# every registry and the render path's per-class memos at boot when the app
# eager-loads, so a request reads memos and never writes the component class
# (a non-main Ractor could not, and two request threads would race to).
RSpec.describe Phlex::Reactive::Component::Registry, ".warm!" do
  let(:registry) { described_class }

  let(:parent) do
    Class.new(ApplicationComponent) do
      include Phlex::Reactive::Component

      reactive_record :todo
      reactive_state :n
      reactive_effects enter: :fade
      action :save, params: { title: :string }

      def initialize(todo: nil, n: 0)
        @todo = todo
        @n = n
      end
    end
  end

  let(:child) { Class.new(parent) { action :ping } }

  # Everything a request reads off the class: every registry kind, through
  # its public reader, plus the token and root-attrs memos.
  def read_everything(klass)
    registry::READERS.each_value { klass.public_send(it) if klass.respond_to?(it) }
    %i[reactive_record_ivar reactive_state_ivars reactive_effect_attrs reactive_on_complete_attr].each do
      klass.public_send(it)
    end
  end

  # Each class instance variable and the identity of its value: a direct
  # `@x = ...` in a reader shows up here even though it bypasses the spy.
  def class_state(klass) = klass.instance_variables.to_h { [it, klass.instance_variable_get(it).object_id] }

  it "names a reader for every registry kind" do
    expect(registry::READERS.keys).to match_array(registry::OWN_IVARS.keys)
  end

  it "leaves nothing for a request to write on the class" do
    registry.warm!([parent, child])
    [parent, child].each { allow(it).to receive(:instance_variable_set).and_call_original }
    before = [parent, child].map { class_state(it) }

    [parent, child].each do
      read_everything(it)
      expect(it).not_to have_received(:instance_variable_set)
    end
    expect([parent, child].map { class_state(it) }).to eq(before)
  end

  it "freezes each warmed class's resolution cache" do
    registry.warm!([parent])

    expect(parent.instance_variable_get(:@reactive_registry_cache)).to be_frozen
  end

  it "answers a kind the cache was warmed without, without memoizing it" do
    stub_const("#{described_class}::READERS", registry::READERS.except(:computes))
    registry.warm!([parent])
    cache = parent.instance_variable_get(:@reactive_registry_cache)

    expect(parent.reactive_computes).to eq({})
    expect(parent.instance_variable_get(:@reactive_registry_cache)).to be(cache)
  end

  it "still sees a declaration made after it (a development reload)" do
    registry.warm!([parent, child])

    parent.action(:late)

    expect(child.reactive_actions.keys).to include(:save, :ping, :late)
  end

  it "skips classes that are not reactive components" do
    plain = Class.new(ApplicationComponent) { include Phlex::Reactive::Streamable }

    expect { registry.warm!([plain]) }.not_to raise_error
  end

  describe "at boot" do
    around do
      it.run
    ensure
      Phlex::Reactive::Engine.finalize_boot!(eager_load: false)
    end

    it "warms every registered class when the app eager-loads" do
      warmed = child

      Phlex::Reactive::Engine.finalize_boot!(eager_load: true)

      expect(warmed.instance_variable_get(:@reactive_registry_cache)).to be_frozen
    end
  end
end
