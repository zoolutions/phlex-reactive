# frozen_string_literal: true

module Phlex
  module Reactive
    # The job-side reply builder (issue #248) — what `reactive_settle` yields.
    #
    #   reactive_settle do |s|
    #     if result.success?
    #       s.remove(transfer, from: :unreconcilable)
    #     else
    #       s.replace(transfer)
    #       s.flash(:alert, result.error)
    #     end
    #   end
    #
    # The verbs mirror `reply.*` and, critically, route through the SAME
    # Phlex::Reactive::Collections decisions — so a job-side append emits the
    # row AND the count companion AND the 0<->1 empty-state toggle, instead of
    # the bare row `broadcast_to(append:)` gives you. That shared bookkeeping is
    # the whole point: it is what the app can no longer get subtly wrong.
    #
    # Unlike Response, Settle is a MUTABLE accumulator, not a value object: a
    # settle block is imperative (branch on the work's result, add a flash) and
    # every verb returns self so the calls can also be chained.
    #
    # It collects streams; Phlex::Reactive::Settles owns the delivery — one
    # durable message to the actor's shared one-shot stream, plus the optional
    # peers broadcast.
    class Settle
      attr_reader :streams

      # The rebuilt container — Settles reads it for the peers broadcast (it
      # carries the collection declaration and the size resolver).
      attr_reader :container

      # `container` is the rebuilt container component (from_identity, off the
      # request thread); `handle` is the Pending::Handle the enqueue captured.
      def initialize(container, handle)
        @container = container
        @handle = handle
        @streams = []
        @peer_ops = []
      end

      # Re-render ONE row in place. The work ran and the row is simply different
      # now (a failed re-execution going back to actionable, say). No count or
      # empty-state stream: a replace cannot change the size.
      #
      # Accepts a record (resolved through the collection's row component) or a
      # built Streamable component (its own #id is the target).
      def replace(model, morph: false, effect: nil, **row_kwargs)
        if model.is_a?(Phlex::Reactive::Streamable)
          @streams << model.to_stream_replace(morph:, effect:)
          return self
        end

        definition = definition!(nil)
        @streams.concat(Phlex::Reactive::Collections.replace_streams(definition, model, effect:, **row_kwargs))
        self
      end

      # Remove a row: the row + the count companion + the empty-state restore at
      # the 1->0 boundary. `from:` defaults to the collection reply.pending
      # named, so the common case reads `s.remove(transfer)`.
      def remove(model, from: nil, effect: nil)
        definition = definition!(from)
        @streams.concat(Phlex::Reactive::Collections.remove_streams(definition, @container, model, effect:))
        peer(definition, :remove, model)
        self
      end

      # Add a row: the row + the count companion + the empty-state clear at the
      # 0->1 boundary.
      def append(model, to: nil, effect: nil, **row_kwargs)
        add(:append, model, to, effect, row_kwargs)
      end

      def prepend(model, to: nil, effect: nil, **row_kwargs)
        add(:prepend, model, to, effect, row_kwargs)
      end

      # The case that motivated the whole issue: the work moved a record between
      # two lists. Ordered remove-then-append so the size resolvers run against
      # the post-move world in the order a reader expects, and so a row can
      # never be momentarily present in both containers.
      def move(model, from:, to:, effect: nil, **row_kwargs)
        remove(model, from:, effect:)
        append(model, to:, effect:, **row_kwargs)
      end

      # Refresh ONLY the collection's count companion — for a settle that
      # changed the size without adding or removing a visible row. `name`
      # defaults to the collection reply.pending named.
      def count(name = nil)
        @streams.concat(Phlex::Reactive::Collections.count_streams(definition!(name), @container))
        self
      end

      # Tell the operator what happened. The job is where the OUTCOME is known,
      # so this is how the page stops saying "Queued" forever.
      def flash(level, content, target: Phlex::Reactive.flash_target, dismiss_after: nil)
        @streams << Phlex::Reactive::Response.send(:flash_stream, level, content, target:, dismiss_after:)
        self
      end

      # Server-pushed client DOM ops, same vocabulary as reply.js. Defaults to
      # the container's id so self-scoped ops just work.
      def js(ops, target: :__default)
        resolved = target == :__default ? @handle.anchor : target
        @streams << Phlex::Reactive::Response.js_stream(ops, target: resolved)
        self
      end

      # Escape hatch: raw <turbo-stream> strings, exactly like reply.streams.
      def streams!(*more)
        @streams.concat(more.flatten)
        self
      end

      # The peer deltas recorded alongside the actor's streams (issue #248).
      # Collected rather than broadcast inline so Settles can send them AFTER
      # the actor's message — the actor paid for the click and should not wait
      # behind a fan-out of channel calls.
      attr_reader :peer_ops

      private

      def add(action, model, name, effect, row_kwargs)
        definition = definition!(name)
        @streams.concat(
          Phlex::Reactive::Collections.add_streams(definition, @container, model, action, row_kwargs, effect:)
        )
        peer(definition, action, model)
        self
      end

      # Resolve the collection: the explicit keyword, else the one reply.pending
      # named. A settle with neither is a call-site mistake — fail loudly rather
      # than silently emit nothing.
      def definition!(name)
        resolved = name || @handle.collection
        unless resolved
          raise Phlex::Reactive::Error,
            "this settle has no collection to work on — name it (s.remove(record, from: :items)) " \
            "or pass in: to reply.pending so the settle inherits it"
        end

        Phlex::Reactive::Collections.definition!(@container, resolved)
      end

      # Record a peer delta (only when reply.pending asked for peers:).
      def peer(definition, action, model)
        return unless @handle.peers

        @peer_ops << [definition.name, action, model]
      end
    end
  end
end
