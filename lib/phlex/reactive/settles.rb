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
    # caller's enqueue inside it; #initialize below captures it onto the job
    # instance, #serialize copies it into the job's metadata, #deserialize
    # restores it. So `perform`'s ARITY IS UNTOUCHED and every OTHER caller of
    # the same job — a nightly sweep, a webhook — builds it with no handle, in
    # which case `reactive_settle` is a NO-OP that returns nil. That is
    # load-bearing: these jobs almost always have non-UI callers.
    #
    # (A `perform_now` INSIDE the enqueue block does carry the handle, since the
    # instance is built there — so it settles synchronously. That is the right
    # reading: `reply.pending` already marked the targets, and something has to
    # resolve the shimmer. The settle's durable message is replayed from
    # since-id 0 when the client opens the subscription, so arriving before it
    # exists is safe.)
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

      # Capture the in-flight settle handle at INSTANTIATION (issue #254).
      #
      # `serialize` is the seam pgbus's own ActiveJob::CurrentAttributes
      # integration uses, and it looked like the enqueue-time hook — but under
      # Rails' `enqueue_after_transaction_commit = true` (the 7.2+ recommended
      # setting) `job.enqueue` is deferred to
      # ActiveRecord.after_all_transactions_commit, and the endpoint runs every
      # action inside a transaction. So the deferral — and with it `serialize` —
      # always fires AFTER reply.pending's `with_handle` block has exited, with
      # an empty thread-local: no metadata key, a no-op `reactive_settle`, and a
      # row left shimmering until someone reloads.
      #
      # `new` is the one moment guaranteed to be inside the block:
      # `perform_later` → `job_or_instantiate` → `new` is synchronous, deferral
      # or not. Pending#each_with_narrowed_handle narrows the thread-local per
      # record BEFORE `perform_later`, so the `job:`/`args:` attribution
      # contract is preserved.
      def initialize(...)
        super
        @reactive_settle_handle ||= Phlex::Reactive::Pending.current_handle
      end

      # The same capture at ENQUEUE, for an instance built BEFORE the block and
      # enqueued inside it (`job = MyJob.new(...)` … `reply.pending { job.enqueue }`).
      # `enqueue` runs synchronously inside the block — it is the deferral it
      # REGISTERS that runs later — so this is the last moment the thread-local
      # is visible. `||=` never overwrites: a retry's `retry_job` re-enqueues a
      # DESERIALIZED instance, which must keep the handle it came back with.
      def enqueue(...)
        @reactive_settle_handle ||= Phlex::Reactive::Pending.current_handle
        super
      end

      # Prefer the captured handle; the thread-local fallback covers an instance
      # serialized inside the block without going through either hook. A retry
      # re-enqueue re-serializes the SAME instance, which keeps its handle — the
      # right reading: the pending UI is still waiting on this work.
      def serialize
        handle = @reactive_settle_handle || Phlex::Reactive::Pending.current_handle
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

      # The teardown: clear the pending markers from EVERY target this handle
      # owns as well as the container, then remove the client's
      # <pgbus-stream-source> by its deterministic id — its disconnectedCallback
      # closes the SSE, so the subscription tears itself down with the content it
      # delivered.
      #
      # Clearing the targets (not just the anchor) is load-bearing: a settle that
      # only flashes — "could not re-execute", say — emits no row stream at all,
      # so nothing swaps that row's node and its markers would otherwise sit
      # there forever. Clearing an id whose node WAS replaced or removed is a
      # harmless no-op (the client op resolves to nothing).
      def finish_streams(handle)
        clear_pending_streams(handle.target_ids + [handle.anchor]) + source_teardown(handle.anchor)
      end

      # One reactive:js clear per id, concatenated. html_safe by construction —
      # each piece is a SafeBuffer from js_stream.
      def clear_pending_streams(ids)
        ids.uniq.map { clear_pending_js(it).to_s }.join.html_safe
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

      # The failure path: clear the pending state so the UI stops lying, WITHOUT
      # tearing the subscription down (a retry must still be able to reach the
      # actor).
      #
      # ATTRIBUTION is the constraint. A handle that owns exactly ONE target —
      # which is every job the `job:`/`args:` sugar enqueues, since it narrows
      # the handle per record — unambiguously identifies the row that just
      # failed, so both it and the container are cleared. A handle that owns
      # MANY (the block form, where the gem cannot map an arbitrary enqueue back
      # to a record) cannot: clearing all of them would un-dim 176 rows that are
      # still legitimately working, and clearing the container alone would claim
      # the whole batch is done. So that case clears nothing and says so — the
      # fan-out's own `finish: true` is what sweeps it up.
      def broadcast_settle_cleanup(handle)
        unless handle.target_ids.one?
          warn_unattributable_failure(handle)
          return
        end

        broadcast_settle_payload(handle, clear_pending_streams(handle.target_ids + [handle.anchor]))
      end

      def warn_unattributable_failure(handle)
        return unless defined?(::Rails) && ::Rails.respond_to?(:logger) && ::Rails.logger

        ::Rails.logger.warn(
          "[phlex-reactive] a settle failed for a #{handle.count}-target reply.pending — the gem " \
          "cannot tell WHICH target this job owned (the enqueue used the block form), so no " \
          "pending marker was cleared. Those markers clear when a settle calls " \
          "reactive_settle(finish: true)."
        )
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
      # Peer delivery is BEST EFFORT and never fails the job. The actor's durable
      # message has already been sent by the time we get here; re-raising would
      # hand the job to the retry policy, and the retry would re-run `perform`
      # and send the ACTOR's settle a second time — duplicating the pieces that
      # are not idempotent (a flash, an empty-state append). A peer who missed a
      # cross-tab courtesy is a far smaller problem than an actor who sees the
      # flash twice, and every other broadcast in the gem is best-effort too.
      def deliver_peers(handle, settle)
        return if handle.peers.nil? || settle.peer_ops.empty?

        keys = handle.peers.map { it.is_a?(Hash) ? GlobalID::Locator.locate(it["gid"]) : it }
        container = settle.container

        settle.peer_ops.each { deliver_peer_op(container, keys, handle, it) }
      rescue ::StandardError => e
        log_peer_failure(e)
      end

      # ONE peer op. A collection delta (append/prepend/remove) goes through
      # broadcast_collection_to so peers get the count companion and the
      # empty-state toggle too; a REPLACE moves no boundary, so it rides the
      # ordinary row broadcast. A nil name means the settle handed us a built
      # component, which self-targets.
      def deliver_peer_op(container, keys, handle, peer_op)
        name, action, model, row_kwargs = peer_op
        return broadcast_peer_component(keys, handle, model) if name.nil?

        if action == :replace
          definition = Phlex::Reactive::Collections.definition!(container, name)
          return definition.item.broadcast_to(
            *keys, replace: definition.item.send(:build, model, row_kwargs || {}),
            exclude: handle.connection_id
          )
        end

        container.class.broadcast_collection_to(
          *keys, container:, in: name, action => model, row: row_kwargs || {},
          exclude: handle.connection_id,
          coalesce: Phlex::Reactive.settle_coalesce_window_ms
        )
      end

      def broadcast_peer_component(keys, handle, component)
        component.class.broadcast_to(*keys, replace: component, exclude: handle.connection_id)
      end

      def log_peer_failure(error)
        return unless defined?(::Rails) && ::Rails.respond_to?(:logger) && ::Rails.logger

        ::Rails.logger.warn(
          "[phlex-reactive] a settle's PEER broadcast failed (#{error.class}: #{error.message}) — " \
          "the actor's settle already landed, so the job is NOT failed: retrying it would deliver " \
          "the actor's settle (and its flash) a second time."
        )
      end
    end
  end
end
