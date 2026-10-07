# frozen_string_literal: true

require "rails_helper"
require "turbo/broadcastable/test_helper"

# Issue #97: Streamable.broadcast_js_to pushes server-side client DOM ops to
# EVERY subscriber of a stream over the SAME transport as every other broadcast
# (Turbo::StreamsChannel → Action Cable here, pgbus in a real app). It rides a
# `reactive:js` custom stream action carrying the HTML-escaped ops.
#
# The builder REJECTS focus-class ops outright: broadcasting a focus steals
# focus in every viewer's tab. Focus is an actor-reply concern (Response#js).
RSpec.describe "broadcast_js_to (issue #97)", type: :request do
  include Turbo::Broadcastable::TestHelper

  let(:ops) { TodoItemComponent.new(todo: Todo.new).js.add_class("#bell", "has-unread") }

  it "broadcasts a reactive:js stream carrying the ops to the stream" do
    broadcasts = capture_turbo_stream_broadcasts("alerts") do
      TodoItemComponent.broadcast_to("alerts", js: ops)
    end

    html = broadcasts.map(&:to_s).join # rubocop:disable Style/MapJoin
    expect(html).to include('action="reactive:js"')
    expect(html).to include("data-reactive-ops=")
    expect(html).to include("add_class")
    expect(html).to include("has-unread")
  end

  # Issue #237: the broadcast op stream carries the verbose gate too, so a
  # subscriber's client can warn on zero-target resolution. verbose_errors
  # defaults ON here (dummy app, Rails.env.local?).
  it "stamps data-reactive-verbose on the broadcast op stream under verbose_errors" do
    broadcasts = capture_turbo_stream_broadcasts("alerts") do
      TodoItemComponent.broadcast_to("alerts", js: ops)
    end

    expect(broadcasts.map(&:to_s).join).to include('data-reactive-verbose="true"') # rubocop:disable Style/MapJoin
  end

  it "omits the verbose stamp when verbose_errors is off (production wire unchanged)" do
    Phlex::Reactive.verbose_errors = false
    broadcasts = capture_turbo_stream_broadcasts("alerts") do
      TodoItemComponent.broadcast_to("alerts", js: ops)
    end

    expect(broadcasts.map(&:to_s).join).not_to include("data-reactive-verbose") # rubocop:disable Style/MapJoin
  ensure
    if Phlex::Reactive.instance_variable_defined?(:@verbose_errors)
      Phlex::Reactive.remove_instance_variable(:@verbose_errors)
    end
  end

  it "accepts a target for root scoping" do
    broadcasts = capture_turbo_stream_broadcasts("alerts") do
      TodoItemComponent.broadcast_to("alerts", js: ops, target: "sidebar")
    end

    html = broadcasts.map(&:to_s).join # rubocop:disable Style/MapJoin
    expect(html).to include('target="sidebar"')
  end

  it "rejects a focus op (broadcasting focus steals focus in every tab)" do
    focus_ops = TodoItemComponent.new(todo: Todo.new).js.focus("#field")

    expect { TodoItemComponent.broadcast_to("alerts", js: focus_ops) }
      .to raise_error(ArgumentError, /focus/)
  end

  it "rejects a focus_first op the same way" do
    focus_ops = TodoItemComponent.new(todo: Todo.new).js.focus_first("#menu")

    expect { TodoItemComponent.broadcast_to("alerts", js: focus_ops) }
      .to raise_error(ArgumentError, /focus/)
  end

  it "rejects focus even when it is mixed among allowed ops (no partial broadcast)" do
    mixed = TodoItemComponent.new(todo: Todo.new).js.add_class("#bell", "unread").focus("#field")

    expect { TodoItemComponent.broadcast_to("alerts", js: mixed) }
      .to raise_error(ArgumentError, /focus/)
  end

  # Issue #226: submit joins the actor-only set — a broadcast submit would
  # force-submit the form in EVERY subscriber's tab.
  it "rejects a submit op (broadcasting submit force-submits every subscriber's form)" do
    submit_ops = TodoItemComponent.new(todo: Todo.new).js.submit

    expect { TodoItemComponent.broadcast_to("alerts", js: submit_ops) }
      .to raise_error(ArgumentError, /submit/)
  end

  it "rejects a raw-array submit op the same way (escape hatch can't bypass it)" do
    expect { TodoItemComponent.broadcast_to("alerts", js: [["submit", { "to" => "@root" }]]) }
      .to raise_error(ArgumentError, /submit/)
  end

  # Issue #228: paste_into joins the actor-only set — a broadcast that reads
  # every subscriber's clipboard would be hostile (browsers would block it
  # without a gesture anyway, but default-deny regardless).
  it "rejects a paste_into op (broadcasting a clipboard read would be hostile)" do
    paste_ops = TodoItemComponent.new(todo: Todo.new).js.paste_into("#code")

    expect { TodoItemComponent.broadcast_to("alerts", js: paste_ops) }
      .to raise_error(ArgumentError, /paste_into/)
  end

  it "rejects a raw-array paste_into op the same way (escape hatch can't bypass it)" do
    expect { TodoItemComponent.broadcast_to("alerts", js: [["paste_into", { "to" => "#code" }]]) }
      .to raise_error(ArgumentError, /paste_into/)
  end

  # Issue #239: the persist ops join the actor-only set — a broadcast that
  # rewrites or wipes every subscriber's localStorage draft would be hostile.
  it "rejects persist_state / persist_clear (broadcasting a draft write would be hostile)" do
    js = TodoItemComponent.new(todo: Todo.new).js

    expect { TodoItemComponent.broadcast_to("alerts", js: js.persist_state(step: 1)) }
      .to raise_error(ArgumentError, /persist_state/)
    expect { TodoItemComponent.broadcast_to("alerts", js: js.persist_clear) }
      .to raise_error(ArgumentError, /persist_clear/)
  end

  # Issue #342: check_group joins the actor-only set — a broadcast that ticks
  # or clears every subscriber's selection would be hostile.
  it "rejects a check_group op (broadcasting a selection change would be hostile)" do
    ops = TodoItemComponent.new(todo: Todo.new).js.check_group("ids[]", false)

    expect { TodoItemComponent.broadcast_to("alerts", js: ops) }
      .to raise_error(ArgumentError, /check_group/)
  end

  it "rejects an empty op chain (a dead reactive:js broadcast is a mistake)" do
    empty = TodoItemComponent.new(todo: Todo.new).js

    expect { TodoItemComponent.broadcast_to("alerts", js: empty) }
      .to raise_error(ArgumentError, /no ops/)
  end

  # The MODULE-LEVEL door (issue #185) must behave exactly like the class-level
  # one: same emission, same actor-only refusal. Pinned because the ops
  # serializer used to live only on the includer class — the module form
  # crashed with NoMethodError instead of refusing, and a naive future fix
  # could have routed it around BROADCAST_REFUSED_OPS entirely (issue #228
  # channel audit).
  describe "module-level Phlex::Reactive.broadcast_to(js:)" do
    it "broadcasts a reactive:js stream exactly like the class-level form" do
      broadcasts = capture_turbo_stream_broadcasts("alerts") do
        Phlex::Reactive.broadcast_to("alerts", js: ops)
      end

      html = broadcasts.map(&:to_s).join # rubocop:disable Style/MapJoin
      expect(html).to include('action="reactive:js"')
      expect(html).to include("add_class")
    end

    it "rejects the actor-only ops (the refusal covers BOTH broadcast doors)" do
      paste_ops = TodoItemComponent.new(todo: Todo.new).js.paste_into("#code")

      expect { Phlex::Reactive.broadcast_to("alerts", js: paste_ops) }
        .to raise_error(ArgumentError, /paste_into/)
    end
  end

  # Transport opts (exclude:/visible_to:) thread to pgbus via THREAD-LOCALS (its
  # broadcast_stream_to patch reads Thread.current[:pgbus_broadcast_*]), NOT via
  # StreamsChannel kwargs (turbo-rails swallows unknown kwargs — issue #187). So
  # broadcast_js_to sets the thread-local when pgbus is present, and passes NO
  # transport kwargs to broadcast_action_to (Action Cable ignores them anyway).
  describe "transport opts thread to pgbus (pgbus-present)" do
    before { allow(Phlex::Reactive).to receive(:pgbus_streams?).and_return(true) }

    it "sets the exclude thread-local during the broadcast" do
      seen = nil
      allow(Turbo::StreamsChannel).to receive(:broadcast_action_to) do
        seen = Thread.current[:pgbus_broadcast_exclude]
      end

      TodoItemComponent.broadcast_to("alerts", js: ops, exclude: "conn-actor-1")

      expect(seen).to eq("conn-actor-1")
      expect(Thread.current[:pgbus_broadcast_exclude]).to be_nil # cleared after
    end

    it "sets the visible_to thread-local during the broadcast" do
      seen = nil
      allow(Turbo::StreamsChannel).to receive(:broadcast_action_to) do
        seen = Thread.current[:pgbus_broadcast_visible_to]
      end

      TodoItemComponent.broadcast_to("alerts", js: ops, visible_to: "user:7")

      expect(seen).to eq("user:7")
    end

    it "never passes exclude:/visible_to: as broadcast_action_to kwargs" do
      seen_kwargs = nil
      allow(Turbo::StreamsChannel).to receive(:broadcast_action_to) do |*_a, **kwargs|
        seen_kwargs = kwargs
      end

      TodoItemComponent.broadcast_to("alerts", js: ops, exclude: "conn-actor-1", visible_to: "user:7")

      expect(seen_kwargs).not_to have_key(:exclude)
      expect(seen_kwargs).not_to have_key(:visible_to)
    end
  end

  it "still broadcasts to the stream when no transport opts are passed (real transport)" do
    expect do
      capture_turbo_stream_broadcasts("alerts") do
        TodoItemComponent.broadcast_to("alerts", js: ops)
      end
    end.not_to raise_error
  end
end
