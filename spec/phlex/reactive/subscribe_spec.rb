# frozen_string_literal: true

require "rails_helper"
require_relative "../../support/fake_pgbus_presence"

# Issue #474: reactive_subscribe — a component that subscribes to its own
# broadcast stream. The root carries the signed src of the stream broadcast_to
# publishes to; broadcast_self broadcasts there without repeating the key. The
# default suite has no pgbus; FakePgbusPresence stubs its constants.
RSpec.describe Phlex::Reactive::Subscribe, "reactive_subscribe (issue #474)" do
  let(:todo) { Todo.create!(title: "Ship it") }

  def render_html(component) = Phlex::Reactive.render(component)

  def declare(name = "Watcher", &)
    Class.new(ApplicationComponent) do
      include Phlex::Reactive::Component

      define_singleton_method(:name) { name }
      reactive_record :todo

      attr_reader :room

      def initialize(todo: nil, room: "lobby")
        @todo = todo
        @room = room
      end

      def id = "watcher-#{@todo&.id || @room}"
      def view_template = div(**reactive_root) { "hi" }

      class_exec(&)
    end
  end

  def subscribe_src(html) = html[/data-reactive-subscribe="([^"]*)"/, 1]

  context "with streams-capable pgbus" do
    before { FakePgbusPresence.install!(self) }

    it "puts the signed src of [record, name] on the root" do
      html = render_html(TodoStatusComponent.new(todo:))

      expect(subscribe_src(html)).to eq("/pgbus/streams/signed-#{todo.to_gid_param}:status")
    end

    it "signs the SAME stream name broadcast_to(record, name) publishes to" do
      component = TodoStatusComponent.new(todo:)
      signed = subscribe_src(render_html(component)).delete_prefix("/pgbus/streams/signed-")

      expect(signed).to eq(Pgbus::Streams::Stream.name_from([todo, :status]))
      expect(component.reactive_subscribe_parts).to eq([todo, :status])
    end

    it "reads key: as the stream's parts, fixed or run on the component" do
      fixed = declare { reactive_subscribe key: %i[lobby feed] }
      dynamic = declare { reactive_subscribe key: -> { [:room, room] } }

      expect(subscribe_src(render_html(fixed.new))).to eq("/pgbus/streams/signed-lobby:feed")
      expect(subscribe_src(render_html(dynamic.new(room: "kitchen")))).to eq("/pgbus/streams/signed-room:kitchen")
      expect(dynamic.new(room: "kitchen").reactive_subscribe_parts).to eq([:room, "kitchen"])
    end

    it "refuses a stream name over pgbus's budget at render, naming it and the budget" do
      klass = declare("LongWatcher") { reactive_subscribe key: ["x" * 40, :status] }

      expect { render_html(klass.new) }
        .to raise_error(Phlex::Reactive::ConfigurationError, /LongWatcher.*47 chars.*budget of 41.*key:/m)
    end

    it "refuses a key: callable that gives a nil part or no parts" do
      nil_part = declare { reactive_subscribe key: -> { [todo_or_nil, :x] } }
      nil_part.define_method(:todo_or_nil) { nil }
      empty = declare { reactive_subscribe key: -> {} }

      expect { render_html(nil_part.new) }.to raise_error(ArgumentError, /gave \[nil, :x\].*none of them nil/)
      expect { render_html(empty.new) }.to raise_error(ArgumentError, /gave \[\]/)
    end

    it "refuses a missing record instead of subscribing to a shared stream" do
      component = declare { reactive_subscribe :status }.new(todo: nil)

      expect { render_html(component) }.to raise_error(ArgumentError, /@todo.*nil/)
    end

    it "needs reactive_record for the name form" do
      klass = Class.new(ApplicationComponent) do
        include Phlex::Reactive::Component

        def self.name = "Recordless"
        reactive_subscribe :status
        def id = "recordless"
        def view_template = div(**reactive_root)
      end

      expect { render_html(klass.new) }.to raise_error(ArgumentError, /Recordless.*needs reactive_record.*key:/m)
    end

    it "keeps every other root free of the attribute" do
      expect(render_html(CounterComponent.new(count: 0))).not_to include("data-reactive-subscribe")
    end

    describe ".broadcast_self" do
      before { allow(Phlex::Reactive::Streamable).to receive(:broadcast_component) }

      def broadcast_keys
        keys = nil
        expect(Phlex::Reactive::Streamable).to have_received(:broadcast_component) { |*args, **| keys = args[4] }
        keys
      end

      it "broadcasts to the declared stream, the key read from the payload" do
        TodoStatusComponent.broadcast_self(replace: todo, morph: true)

        expect(Phlex::Reactive::Streamable).to have_received(:broadcast_component)
          .with(TodoStatusComponent, :replace, an_instance_of(TodoStatusComponent), anything, [[todo, :status]],
            hash_including(morph: true))
      end

      it "reads a key: callable off the component it builds" do
        klass = declare { reactive_subscribe key: -> { [:room, room] } }
        klass.broadcast_self(update: { room: "kitchen" })

        expect(broadcast_keys).to eq([[:room, "kitchen"]])
      end

      it "reads the key from the subject when one is given (js: has no component)" do
        TodoStatusComponent.broadcast_self(todo, js: Phlex::Reactive::JS.new.add_class("#x", "y"))

        expect(broadcast_keys).to eq([[todo, :status]])
      end

      it "refuses js: without a subject" do
        expect { TodoStatusComponent.broadcast_self(js: Phlex::Reactive::JS.new.add_class("#x", "y")) }
          .to raise_error(ArgumentError, /broadcast_self\(record, js:/)
      end

      it "refuses a payload of another class without a subject" do
        other = declare { reactive_subscribe :other }.new(todo:)

        expect { TodoStatusComponent.broadcast_self(replace: other) }
          .to raise_error(ArgumentError, /reads the stream key from a TodoStatusComponent/)
      end

      it "builds the payload's component once and hands it on built" do
        allow(TodoStatusComponent).to receive(:new).and_call_original
        TodoStatusComponent.broadcast_self(replace: todo)

        expect(TodoStatusComponent).to have_received(:new).once
        expect(Phlex::Reactive::Streamable).to have_received(:broadcast_component)
          .with(TodoStatusComponent, :replace, an_instance_of(TodoStatusComponent), anything, [[todo, :status]], anything)
      end

      it "builds a state-backed default from a nil payload" do
        klass = declare { reactive_subscribe key: -> { [:room, room] } }
        klass.broadcast_self(update: nil)

        expect(broadcast_keys).to eq([[:room, "lobby"]])
      end

      it "refuses each: (the stream is the declared one)" do
        expect { TodoStatusComponent.broadcast_self(replace: todo, each: [[:other]]) }
          .to raise_error(ArgumentError, /takes no each:/)
      end

      it "refuses a class without the declaration" do
        expect { CounterComponent.broadcast_self(replace: CounterComponent.new(count: 0)) }
          .to raise_error(ArgumentError, /needs a reactive_subscribe declaration/)
      end
    end
  end

  context "without pgbus (Action Cable)" do
    it "loads the class, and raises at render naming turbo_stream_from" do
      expect(described_class.capable?).to be(false)
      expect { render_html(TodoStatusComponent.new(todo:)) }
        .to raise_error(Phlex::Reactive::ConfigurationError, /TodoStatusComponent.*turbo_stream_from/m)
    end
  end

  context "with a pgbus too old for reactive Streams" do
    it "is not capable (the broadcast has no exclude:)" do
      FakePgbusPresence.install!(self)
      old_stream = Class.new { def broadcast(payload) = payload }
      stub_const("Pgbus::Streams::Stream", old_stream)

      expect(described_class.capable?).to be(false)
    end
  end

  describe "the declaration" do
    it "takes a name or key:, exactly one" do
      expect { declare { reactive_subscribe } }.to raise_error(ArgumentError, /exactly one/)
      expect { declare { reactive_subscribe :a, key: [:b] } }.to raise_error(ArgumentError, /exactly one/)
    end

    it "validates the name and key:" do
      expect { declare { reactive_subscribe "bad:name" } }.to raise_error(ArgumentError, /lowercase identifier/)
      expect { declare { reactive_subscribe key: [] } }.to raise_error(ArgumentError, /non-empty Array/)
      expect { declare { reactive_subscribe key: "lobby" } }.to raise_error(ArgumentError, /non-empty Array/)
    end

    it "refuses a dormant root in either order" do
      expect { declare { reactive_dormant; reactive_subscribe :status } } # rubocop:disable Style/Semicolon
        .to raise_error(ArgumentError, /dormant/)
      expect { declare { reactive_subscribe :status; reactive_dormant } } # rubocop:disable Style/Semicolon
        .to raise_error(ArgumentError, /dormant/)
    end

    it "is inherited, and a subclass may declare its own" do
      parent = declare { reactive_subscribe :status }
      child = Class.new(parent) { reactive_subscribe :other }

      expect(Class.new(parent).reactive_subscribe_declaration.name).to eq(:status)
      expect(child.reactive_subscribe_declaration.name).to eq(:other)
      expect(parent.reactive_subscribe_declaration.name).to eq(:status)
    end

    it "is absent on a component that does not declare it" do
      expect(CounterComponent.reactive_subscribe_declaration).to be_nil
      expect(CounterComponent.new(count: 0)).not_to respond_to(:reactive_subscribe_data)
    end
  end
end
