# frozen_string_literal: true

module Phlex
  module Reactive
    # The job half of the async-action lifecycle (issue #248). Include it in a
    # job that does work an action merely ENQUEUED, and settle the UI when the
    # work is actually done:
    #
    #   class ReExecuteJob < ApplicationJob
    #     include Phlex::Reactive::Settles
    #
    #     def perform(transfer_id)          # signature UNCHANGED
    #       transfer = Transfer.find(transfer_id)
    #       result   = Transfers::ReExecuteService.call(transfer:)
    #
    #       reactive_settle do |s|
    #         if result.success?
    #           s.remove(transfer, from: :unreconcilable)
    #         else
    #           s.replace(transfer)
    #           s.flash(:alert, result.error)
    #         end
    #       end
    #     end
    #   end
    #
    # ## The handle rides ActiveJob metadata
    #
    # `reply.pending` installs a Pending::Handle in a thread-local and runs the
    # caller's enqueue inside it; #serialize below copies it into the job's
    # metadata, #deserialize restores it. So `perform`'s ARITY IS UNTOUCHED and
    # every OTHER caller of the same job — a nightly sweep, a webhook — enqueues
    # it with no handle, in which case `reactive_settle` is a NO-OP that returns
    # nil. That is load-bearing: these jobs almost always have non-UI callers.
    #
    # (`perform_now` does not round-trip through serialize/deserialize, so it
    # carries no handle either — which is the correct reading: a synchronous
    # call has no pending UI waiting on it.)
    #
    # ## A rolled-back action
    #
    # The endpoint builds the pending markers and the subscription directive only
    # AFTER the action's transaction committed, so a rolled-back action leaks
    # neither. Whether the ENQUEUE survives the rollback is the queue adapter's
    # business, exactly as it is for a bare `perform_later` in an action — and if
    # such a job does run, its settle broadcasts to a key nobody ever subscribed
    # to. That is inert: the one-shot queue is reclaimed by pgbus's orphan sweep.
    #
    # ## Failure is never silent, and never permanent
    #
    # If the block raises, the target's pending markers are still cleared (the
    # shimmer must not lie) and the error is RE-RAISED so the retry policy sees
    # it. The shared subscription is deliberately NOT torn down on failure — a
    # retry must still be able to reach the actor.
    module Settles
      # ActiveJob metadata key. Prefixed and spelled out — job metadata is a
      # shared namespace with every other gem in the app.
      SETTLE_METADATA_KEY = "phlex_reactive_settle"

      # Capture the in-flight settle handle at ENQUEUE time. This is the same
      # seam pgbus's own ActiveJob::CurrentAttributes integration uses, and it
      # is adapter-agnostic: it works under :async, :test and :inline as well as
      # a real backend, which is what app specs need.
      def serialize
        handle = Phlex::Reactive::Pending.current_handle
        return super unless handle

        super.merge(SETTLE_METADATA_KEY => handle.to_h_wire)
      end

      def deserialize(job_data)
        super
        @reactive_settle_handle = Phlex::Reactive::Pending::Handle.from_wire(job_data[SETTLE_METADATA_KEY])
      end

      # Settle the UI this job's work was enqueued for. Yields a
      # Phlex::Reactive::Settle bound to the container, rebuilt from the signed
      # identity the enqueue captured. Returns nil (and never runs the block)
      # when this job carries no handle.
      #
      # `finish:` controls teardown of the SHARED one-shot subscription. All N
      # settles of one reply.pending share ONE stream key (a key per record
      # would mean a PGMQ table and an SSE connection per record), so tearing
      # down on the first arrival would cut off the other N-1. The default
      # (:auto) therefore finishes only when reply.pending marked exactly one
      # target; a fan-out passes `finish: true` from whatever knows it is last —
      # a Pgbus::Batch on_finish callback, or the final job of a staggered
      # sequence. Until then the subscription is superseded by the container's
      # next pending call, or closed when the page unloads.
      def reactive_settle(finish: :auto)
        handle = @reactive_settle_handle
        return nil unless handle

        settle = build_settle(handle)
        yield settle
        deliver_settle(handle, settle, finish)
        settle
      rescue ::StandardError
        # The shimmer must resolve even when the work blew up. Clear the pending
        # markers, keep the subscription (a retry still needs it), then re-raise
        # so ActiveJob's retry policy gets its chance. A failure to broadcast the
        # cleanup itself propagates too — there is nothing deliverable, and the
        # next attempt is the only remaining hope.
        broadcast_settle_cleanup(@reactive_settle_handle) if @reactive_settle_handle
        raise
      end

      private

      def build_settle(handle)
        container = handle.container_class.constantize.from_identity(handle.container_payload)
        Phlex::Reactive::Settle.new(container, handle)
      end

      # ONE durable message to the actor, carrying every stream this settle
      # produced. Bundling is deliberate: the row, the count companion and the
      # empty-state toggle belong to the same instant, and one message per settle
      # is also why the ACTOR path needs no coalescing — there is nothing extra
      # to collapse. (Coalescing applies to the PEERS path, where the aggregates
      # really are separate channel calls.)
      def deliver_settle(handle, settle, finish)
        payload = settle.streams.join
        payload += finish_streams(handle) if finish_settle?(handle, finish)
        broadcast_settle_payload(handle, payload) unless payload.empty?
        deliver_peers(handle, settle)
      end

      def finish_settle?(handle, finish)
        return finish unless finish == :auto

        handle.count.to_i <= 1
      end

      # The teardown: clear the container's pending markers, then remove the
      # client's <pgbus-stream-source> by its deterministic id — its
      # disconnectedCallback closes the SSE, so the subscription tears itself
      # down with the content it delivered.
      def finish_streams(handle)
        clear_pending_js(handle.anchor).to_s + source_teardown(handle.anchor)
      end

      def source_teardown(anchor)
        target = Phlex::Reactive::Pending.source_id(anchor)
        %(<turbo-stream action="remove" target="#{ERB::Util.html_escape(target)}"></turbo-stream>).html_safe
      end

      # reactive:js ops that strip the pending vocabulary from ONE element.
      def clear_pending_js(target)
        ops = Phlex::Reactive::JS.new
          .remove_attr(:root, Phlex::Reactive::Pending::PENDING_ATTR)
          .remove_attr(:root, "aria-busy")
          .remove_attr(:root, "data-reactive-defer-pending")
        Phlex::Reactive::Response.js_stream(ops, target:)
      end

      # The failure path: clear the container's pending state so the UI stops
      # lying, WITHOUT tearing the subscription down.
      def broadcast_settle_cleanup(handle)
        broadcast_settle_payload(handle, clear_pending_js(handle.anchor).to_s)
      end

      # Durable is load-bearing: pgbus's since-id replay only covers
      # PGMQ-persisted messages, and that replay is what closes the
      # broadcast-before-subscribe race (the actor may still be opening the SSE
      # when a fast job finishes).
      def broadcast_settle_payload(handle, payload)
        ::Pgbus.stream(handle.stream_key, durable: true).broadcast(payload)
      end

      # The peers leg (issue #248): the same collection deltas, broadcast to the
      # container's stream so a second operator watching the same batch sees
      # them. Sent AFTER the actor's message — the actor paid for the click and
      # should not wait behind a fan-out of channel calls. `exclude:` is the
      # actor's connection id, so they never get the delta twice.
      def deliver_peers(handle, settle)
        return if handle.peers.nil? || settle.peer_ops.empty?

        keys = handle.peers.map { it.is_a?(Hash) ? GlobalID::Locator.locate(it["gid"]) : it }
        container = settle.container

        settle.peer_ops.each do |name, action, model|
          container.class.broadcast_collection_to(
            *keys, container:, in: name, action => model,
            exclude: handle.connection_id,
            coalesce: Phlex::Reactive.settle_coalesce_window_ms
          )
        end
      end
    end
  end
end
