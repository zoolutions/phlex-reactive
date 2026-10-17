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

  it "shares the render path's memos, so a non-main Ractor can read them" do
    registry.warm!([parent, child])

    [parent, child].each do |klass|
      memos = registry::MEMO_READERS.map { klass.public_send(it) }
      expect(memos).to all(satisfy("be Ractor-shareable") { Ractor.shareable?(it) })
    end
  end

  # A non-main Ractor can read a class instance variable only when its value
  # is Ractor-shareable, and a frozen Hash of mutable definitions is not:
  # every ivar the gem keeps on a warmed class must be shareable all the way
  # down. One class declaring every registry kind, and a subclass adding its own.
  describe "every class instance variable it leaves" do
    let(:row) { Class.new(ApplicationComponent) { include Phlex::Reactive::Streamable } }

    let(:declared) do
      item = row
      Class.new(ApplicationComponent) do
        include Phlex::Reactive::Component

        reactive_state :count, :title
        reactive_scope :draft
        reactive_dirty warn_unsaved: true, only: %i[title]
        reactive_effects enter: :fade, update: :highlight
        reactive_lazy cache: { max_age: 10.minutes }
        reactive_collection :rows, item:, container: "rows", count: "rows-count", size: -> { 3 }
        reactive_compute :total, inputs: { title: :string, qty: :number }, outputs: %i[total],
          mirror: { total: "#total" }
        reactive_on_complete if: { title: { length: 6 } }, run: js.dispatch("title:complete")
        reactive_presence :viewers, state: { selected: :integer }, key: %i[board]
        action :increment, params: { step: :integer, tags: [:string], address: { street: :string } }
        skip_verify_authorized :increment

        def initialize(count: 0, title: "")
          @count = count
          @title = title
        end

        def increment(step: 1, **) = @count += step
      end
    end

    let(:subclass) do
      Class.new(declared) do
        reactive_record :todo
        reactive_dormant false
        action :rename, params: { title: :string }
        skip_verify_authorized
      end
    end

    # Each unshareable class ivar, with the path to what makes it so.
    def unshareable_ivars(klass)
      klass.instance_variables.filter_map do
        culprit = ConformanceKit::Shareability.culprit(klass.instance_variable_get(it))
        "#{it}#{culprit.path} is #{culprit.reason}" if culprit
      end
    end

    it "is Ractor-shareable, so a non-main Ractor can read the class" do
      registry.warm!([declared, subclass])

      unshareable = [declared, subclass].flat_map { unshareable_ivars(it) }

      expect(unshareable).to be_empty, "unshareable after warm!:\n  #{unshareable.join("\n  ")}"
    end

    it "keeps every declaration readable" do
      registry.warm!([declared, subclass])

      expect(subclass.reactive_actions.keys).to eq(%i[presence_set increment rename])
      expect(subclass.reactive_actions[:increment].params).to eq(step: :integer, tags: [:string],
        address: { street: :string })
      expect(subclass.reactive_actions[:increment].schema.coerce({ "step" => "2", "junk" => "x" })).to eq(step: 2)
      expect(subclass.reactive_state_keys).to eq(%i[count title])
      expect(subclass.reactive_collections[:rows].size_for(subclass.new)).to eq(3)
      expect([subclass.reactive_skip_all_authorization?, declared.reactive_skip_all_authorization?])
        .to eq([true, false])
    end

    it "never freezes what the app declared with" do
      schema = { title: :string }
      klass = Class.new(declared) { action :retitle, params: schema }

      registry.warm!([klass])

      expect(schema).not_to be_frozen
      expect(klass.reactive_actions[:retitle].params).to eq(schema)
    end

    # A size: lambda that assigns what it captures can never be shared: the
    # class keeps working on the main Ractor, and boot must not raise.
    it "keeps a declaration no Ractor can share as it is" do
      item = row
      klass = Class.new(ApplicationComponent) do
        include Phlex::Reactive::Component

        reads = 0
        reactive_collection :rows, item:, container: "rows", size: -> { reads += 1 }
      end

      expect { registry.warm!([klass]) }.not_to raise_error
      expect(klass.reactive_collections[:rows].size_for(klass.new)).to eq(1)
    end

    it "still takes a declaration after it (a development reload)" do
      registry.warm!([declared, subclass])

      declared.action(:late, params: { at: :date })
      declared.reactive_state(:later)
      subclass.skip_verify_authorized(:late)

      expect(subclass.reactive_actions.keys).to include(:increment, :rename, :late)
      expect(subclass.reactive_state_keys).to eq(%i[count title later])
      expect(subclass.reactive_skip_authorization_actions).to include(:late)
    end
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

    # A ClientBindings view has no token and never registers with Streamable,
    # but its root attrs read the same memos.
    it "warms client-only components too, subclasses included" do
      client_only = Class.new(ApplicationComponent) do
        include Phlex::Reactive::ClientBindings

        reactive_effects enter: :fade
      end
      subclass = Class.new(client_only)

      Phlex::Reactive::Engine.finalize_boot!(eager_load: true)

      caches = [client_only, subclass].map { it.instance_variable_get(:@reactive_registry_cache) }
      expect(caches).to all(be_a(Hash).and(be_frozen))
      expect(Ractor.shareable?(subclass.reactive_effect_attrs)).to be(true)
    end
  end
end
