# frozen_string_literal: true

module Phlex
  module Reactive
    # The async-action lifecycle (issue #248): the machinery behind
    # `reply.pending` — "mark these targets pending, let MY job settle them".
    #
    # ## Why this exists
    #
    # The endpoint runs an action inside a transaction and renders the reply
    # THERE, while a queue adapter publishes on COMMIT. So any `reply.morph`
    # after an enqueue renders from a database the job has not touched yet and
    # is GUARANTEED to draw the pre-job world — rows still present, buttons
    # still live, counts unchanged — next to a "Queued 177 transfers" flash the
    # same reply emitted. Apps worked around it with a `queued:` kwarg threaded
    # into every row component plus a second render branch; ~60 lines of
    # identical bookkeeping per screen, and the page still never learned the
    # outcome.
    #
    # ## The shape
    #
    # `reply.pending` does three things, in order:
    #
    #   1. mints ONE one-shot durable stream key for the whole call (see the
    #      shared-key rule below) and builds a Handle describing the settle;
    #   2. runs the caller's enqueue — a block, or the `job:`/`args:` sugar —
    #      with that Handle in a thread-local, so EVERY ActiveJob enqueued
    #      inside captures it through Phlex::Reactive::Settles#serialize;
    #   3. records a Segment on the Response. The ENDPOINT turns it into wire
    #      streams after the action's transaction committed (a rolled-back
    #      action can never leak a directive).
    #
    # ## One key per call — a hard design rule
    #
    # A durable pgbus broadcast to a never-seen key calls `ensure_queue!` →
    # `pgmq.create`, i.e. a REAL PGMQ table per key, reclaimed only by pgbus's
    # hourly orphan sweep at a 24h threshold. A key per record would leave 177
    # tables sitting for a day (and open 177 SSE connections). So all N settles
    # of one `reply.pending` share ONE key and ONE subscription, anchored on the
    # container component's id.
    #
    # Because the key is shared, a per-settle teardown would kill the
    # subscription on the FIRST arrival. Teardown is therefore explicit — see
    # Phlex::Reactive::Settle#finish? — and defaults to "finish when this call
    # marked exactly one record pending".
    #
    # ## No pull fallback
    #
    # Unlike `reply.defer`, a settle has no `:fetch` lane: the client cannot
    # poll "is the job done yet". So `reply.pending` needs the defer PUSH lane
    # (Phlex::Reactive.settle_capable?). Without it, it DEGRADES rather than
    # breaks: the enqueue still runs, no handle is installed (so
    # `reactive_settle` no-ops exactly like a sweep-enqueued job), and NO
    # pending markers are emitted — the UI shows the pre-job world, which is
    # today's behavior, instead of a shimmer that could never resolve.
    module Pending
      # The settle handle: everything a job needs to reach the actor and rebuild
      # the container off the request thread. It rides ActiveJob metadata, so it
      # must round-trip through plain JSON.
      Handle = Data.define(
        :stream_key,        # the shared one-shot durable pgbus key
        :container_class,   # the container component's class NAME
        :container_payload, # its reactive_identity_payload, for from_identity
        :anchor,            # the container's DOM id: subscription + teardown target
        :collection,        # the declared reactive_collection name, or nil
        :target_ids,        # the DOM ids THIS handle is responsible for un-pending
        :peers,             # peer stream key parts, or nil (actor-only)
        :connection_id      # the actor's connection id, so peers exclude the echo
      ) do
        # How many targets this handle owns — drives the `finish: :auto` default
        # (a single-target settle tears the shared subscription down; a fan-out
        # waits for an explicit finish).
        def count = target_ids.size

        def to_h_wire
          {
            "key" => stream_key, "c" => container_class, "p" => container_payload,
            "anchor" => anchor, "coll" => collection&.to_s, "ids" => target_ids,
            "peers" => peers, "cid" => connection_id
          }
        end

        def self.from_wire(data)
          return nil unless data.is_a?(Hash) && data["key"]

          new(
            stream_key: data["key"], container_class: data["c"], container_payload: data["p"],
            anchor: data["anchor"], collection: data["coll"]&.to_sym,
            target_ids: data["ids"] || [], peers: data["peers"], connection_id: data["cid"]
          )
        end
      end

      # One recorded pending segment: the handle plus the DOM ids that were
      # marked pending (the endpoint emits one marker stream per id).
      Segment = Data.define(:handle, :target_ids)

      # The attribute apps style. Set alongside aria-busy on every pending
      # target AND on the container, so one CSS rule covers both:
      #
      #   [data-reactive-pending] { opacity: .5; pointer-events: none; }
      PENDING_ATTR = "data-reactive-pending"

      # The thread/fiber-local cell holding the handle for the duration of the
      # enqueue block. Mirrors Phlex::Reactive.with_connection_id exactly.
      HANDLE_KEY = :phlex_reactive_settle_handle

      class << self
        def current_handle = Thread.current[HANDLE_KEY]

        def with_handle(handle)
          previous = Thread.current[HANDLE_KEY]
          Thread.current[HANDLE_KEY] = handle
          yield
        ensure
          Thread.current[HANDLE_KEY] = previous
        end

        # Build the Segment for one reply.pending call, running the caller's
        # enqueue with the handle installed. Returns nil when the push lane is
        # unavailable — the enqueue still ran, there is just nothing to settle.
        def build_segment(container, records, collection:, peers:, job:, args:, enqueue:)
          # Materialize ONCE. `records` may be a lazy Enumerator or a Relation,
          # and the targets and the enqueue both need to walk it — enumerating
          # twice either exhausts a one-shot source (jobs silently never enqueue)
          # or re-queries, so a concurrent write could make the marked rows and
          # the enqueued jobs disagree.
          list = materialize(records)
          targets = resolve_targets(container, list, collection)

          unless Phlex::Reactive.settle_capable?
            warn_no_lane
            run_enqueue(list, job, args, enqueue, nil)
            return nil
          end

          handle = build_handle(container, collection, targets, peers)
          with_handle(handle) { run_enqueue(list, job, args, enqueue, targets) }
          Segment.new(handle:, target_ids: targets)
        end

        # One record, or an enumerable of them, as an Array — never re-walked.
        def materialize(records)
          list = records.is_a?(Enumerable) && !records.is_a?(String) ? records.to_a : [records]
          raise ::ArgumentError, "reply.pending needs at least one target" if list.empty?

          list
        end

        # The wire streams for one segment, in apply order: the per-target
        # pending markers FIRST (so the UI stops lying immediately), then the
        # single subscription directive.
        def streams_for(segment)
          streams = segment.target_ids.map { marker_stream(it) }
          streams << marker_stream(segment.handle.anchor)
          streams << directive_stream(segment.handle)
          streams
        end

        # The deterministic id of the shared <pgbus-stream-source>. The client
        # mints it as reactive-defer-src-<anchor>; a settle removes it by this
        # exact id to tear the subscription down.
        def source_id(anchor) = "reactive-defer-src-#{anchor}"

        # Resolve the DOM id a row component would render for `model`, WITHOUT
        # rendering it (build is cheap — #id must be render-context-free, that
        # is the Streamable#id contract).
        def row_dom_id(definition, model)
          return model if model.is_a?(String)

          definition.item.send(:build, model, {}).id
        end

        private

        # Each pending target, as a DOM id. With `in:` the rows resolve through
        # the collection declaration; without it every entry must already be a
        # Streamable component (its own #id is the target).
        def resolve_targets(container, list, collection)
          if collection
            definition = Phlex::Reactive::Collections.definition!(container, collection)
            return list.map { row_dom_id(definition, it) }
          end

          list.map do
            unless it.is_a?(Phlex::Reactive::Streamable)
              raise ::ArgumentError,
                "reply.pending(#{it.class}) cannot resolve a DOM target — name the collection " \
                "the record lives in (reply.pending(record, in: :collection_name)) or pass a " \
                "Streamable component instance (its #id is the target)"
            end

            it.id
          end
        end

        def build_handle(container, collection, targets, peers)
          Handle.new(
            stream_key: one_shot_stream_key,
            container_class: container.class.name,
            container_payload: container.send(:reactive_identity_payload),
            anchor: container.id,
            collection: collection&.to_sym,
            target_ids: targets,
            peers: resolve_peers(container, peers),
            connection_id: Phlex::Reactive.current_connection_id
          )
        end

        # `peers: true` means the container's own record stream (the natural
        # "everyone looking at this batch"); an Array is that one key's parts,
        # passed through to broadcast_to(*streamables) verbatim. The parts are
        # GlobalID-serialized so they survive the trip into the job.
        def resolve_peers(container, peers)
          return nil unless peers

          parts =
            if peers == true
              record = container.class.reactive_record_ivar &&
                       container.instance_variable_get(container.class.reactive_record_ivar)
              unless record
                raise ::ArgumentError,
                  "reply.pending(peers: true) needs a record-backed container (reactive_record) — " \
                  "a state-backed one has no record stream, so pass the key parts explicitly: " \
                  "peers: [list, :todos]"
              end

              [record]
            else
              Array(peers)
            end

          parts.map { it.respond_to?(:to_gid) ? { "gid" => it.to_gid.to_s } : it.to_s }
        end

        # Run the caller's enqueue: an explicit block wins; otherwise the
        # job:/args: sugar. Neither is also fine — an action may have enqueued
        # its work before calling reply.pending (the handle is then unused,
        # which is a mistake we cannot detect, so it is documented, not guessed
        # at).
        #
        # The sugar enqueues ONE job PER RECORD, so each job gets a handle
        # NARROWED to that record's target id. That precision matters on the
        # failure path: a job that raises (or settles with nothing but a flash)
        # must clear ITS row's pending markers without un-dimming the other 176
        # rows that are still legitimately working. The BLOCK form cannot be
        # narrowed — the gem has no way to map an arbitrary enqueue back to a
        # record — so it carries the whole target list, which is the right
        # reading of "these jobs settle these targets as one unit".
        def run_enqueue(list, job, args, enqueue, targets)
          return enqueue.call if enqueue
          return unless job

          case args
          when nil then each_with_narrowed_handle(list, targets) { job.perform_later(it) }
          when ::Proc
            each_with_narrowed_handle(list, targets) { job.perform_later(*Array(args.call(it))) }
          else
            if list.size > 1
              raise ::ArgumentError,
                "reply.pending(job:, args: [...]) is ambiguous for #{list.size} records — pass a " \
                "Proc (args: ->(record) { [record.id] }) so each job gets its own arguments"
            end

            each_with_narrowed_handle(list, targets) { job.perform_later(*Array(args)) }
          end
        end

        # Yield each record with the ambient handle narrowed to that record's own
        # target id. `targets` is nil on the no-lane path (no handle is installed
        # at all), in which case this is a plain each.
        def each_with_narrowed_handle(list, targets)
          return list.each { yield(it) } unless targets

          handle = current_handle
          list.each_with_index do |record, index|
            id = targets[index]
            narrowed = id ? handle.with(target_ids: [id]) : handle
            with_handle(narrowed) { yield(record) }
          end
        end

        # Mark ONE element pending: data-reactive-pending + aria-busy, via the
        # existing reactive:js op lane (@root-scoped to the target), so this
        # needs no client change at all.
        def marker_stream(target_id)
          ops = Phlex::Reactive::JS.new
            .set_attr(:root, PENDING_ATTR, "true")
            .set_attr(:root, "aria-busy", "true")
          Phlex::Reactive::Stream.wrap(
            Phlex::Reactive::Response.js_stream(ops, target: target_id),
            action: "reactive:js", target: target_id, renders_root: false
          )
        end

        # The subscription directive — the SAME reactive:defer wire the push
        # lane already speaks, so the client needs nothing new. Deliberately NO
        # data-reactive-defer-token: that attribute is the client's degrade-to-
        # fetch path, and a settle has no fetch lane (POSTing it would render
        # the pre-job component, re-creating the exact bug this fixes).
        def directive_stream(handle)
          src = signed_stream_src(handle.stream_key)
          html = %(<turbo-stream action="#{Phlex::Reactive::Defer::DIRECTIVE_ACTION}" \
target="#{ERB::Util.html_escape(handle.anchor)}" data-reactive-defer-via="stream" \
data-reactive-defer-src="#{ERB::Util.html_escape(src)}" data-reactive-defer-since-id="0"></turbo-stream>)
          Phlex::Reactive::Stream.wrap(
            html.html_safe, action: Phlex::Reactive::Defer::DIRECTIVE_ACTION,
            target: handle.anchor, renders_root: false
          )
        end

        # The key + src minting are Defer's, verbatim — one implementation of
        # the pgbus queue-name budget and the signed SSE src, so the two lanes
        # can never disagree about either. (Private on Defer, reached the same
        # way the rest of the identity internals are off-instance.)
        def one_shot_stream_key = Phlex::Reactive::Defer.send(:one_shot_stream_key)
        def signed_stream_src(key) = Phlex::Reactive::Defer.send(:signed_stream_src, key)

        # No settle lane is a CONFIG fact, not a per-reply event — warn once per
        # process (a pending reply can fire per click; per-reply spam would bury
        # the signal), then degrade to a plain enqueue.
        def warn_no_lane
          return if @no_lane_warned

          @no_lane_warned = true
          return unless defined?(::Rails) && ::Rails.respond_to?(:logger) && ::Rails.logger

          ::Rails.logger.warn(
            "[phlex-reactive] reply.pending needs the defer PUSH lane (pgbus reactive Streams + " \
            "SignedName + ActiveJob, and defer_transport not forced to :fetch) — a settle has no " \
            "pull fallback. Enqueuing without a settle handle; no pending markers were emitted."
          )
        end
      end
    end
  end
end
