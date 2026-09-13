# frozen_string_literal: true

module Views
  module Docs
    module Pages
      class AsyncActions < DocsUI::Page
        title 'Async actions'
        eyebrow 'Guide'
        description 'reply.pending and reactive_settle: an action that enqueues background work marks its targets ' \
                    'pending and lets your own job settle the collection — row, count and empty-state — when the ' \
                    'work is actually done'

        def lead
          'An action that *does* the work can reply honestly. An action that ' \
            '*enqueues* it cannot — the reply renders before the job touches the ' \
            'database. `reply.pending` marks the targets instead, and your own job ' \
            'settles them when the work finishes.'
        end

        def content
          the_lie
          the_shape
          the_reply
          the_settle
          the_rules
          peers
          config_reference
        end

        private

        def the_lie
          DocsUI::Section('The reply that is guaranteed to be wrong') do
            md <<~'MD'
              The endpoint runs your action inside a transaction and renders the
              reply **there**, while the queue adapter publishes on **commit**. So
              any `reply.morph` after an enqueue renders from a database the job has
              not touched yet:

              ```ruby
              def restore_all
                count = BatchRestoreService.call(bulk_payment: @bulk_payment)  # fans out N jobs
                reply.morph.flash(:notice, "Putting #{count} back…")           # renders the PRE-job world
              end
              ```

              The morph re-renders every row with a live "Put back" button for work
              already requested, sitting directly beside the "Queued 177" flash the
              same reply emitted.
            MD

            DocsUI::Callout(:warning) do
              md <<~MD
                The usual workaround is a `queued:` kwarg threaded into **every** row
                component with a second render branch, a `@queued_*` flag on the
                container, and the header button's count forced to `0`. That is ~60
                lines of identical bookkeeping per screen — and it still never tells
                the operator the **outcome**: the page says "Queued" forever until
                someone reloads.
              MD
            end
          end
        end

        def the_shape
          DocsUI::Section('The shape') do
            md <<~MD
              ```ruby
              class ReconcileQueue < ApplicationComponent
                include Phlex::Reactive::Component

                reactive_collection :unreconcilable,
                  item: TransferRow, container: "unreconcilable",
                  count: "unreconcilable-count", empty: NothingToReconcile,
                  size: -> { @bulk_payment.transfers.unreconcilable.count }

                action :re_execute, params: { transfer_id: :integer }

                def re_execute(transfer_id:)
                  transfer = @bulk_payment.transfers.re_executable.find(transfer_id)
                  authorize! transfer, :update?
                  reply.pending(transfer, in: :unreconcilable, job: ReExecuteJob, args: [transfer.id])
                end
              end
              ```

              ```ruby
              class ReExecuteJob < ApplicationJob
                include Phlex::Reactive::Settles

                def perform(transfer_id)            # signature UNCHANGED
                  transfer = Transfer.find(transfer_id)
                  result   = Transfers::ReExecuteService.call(transfer:)

                  reactive_settle do |s|
                    if result.success?
                      s.remove(transfer)                # row + count + empty-state
                    else
                      s.replace(transfer)               # back to actionable
                      s.flash(:alert, result.error)     # the operator learns the outcome
                    end
                  end
                end
              end
              ```

              And the case that motivated the whole feature — work that moves a
              record between two lists — is one call:

              ```ruby
              reactive_settle { |s| s.move(transfer, from: :declined, to: :unreconcilable) }
              ```
            MD
          end
        end

        def the_reply
          DocsUI::Section('What reply.pending emits') do
            md <<~'MD'
              It deliberately does **not** re-render the container — that is the bug.
              It emits three things:

              1. a `data-reactive-pending="true"` + `aria-busy="true"` marker on
                 every target, over the existing `reactive:js` op lane;
              2. **one** subscription directive, anchored on the container, opening a
                 single durable one-shot stream that **all N settles share**;
              3. an inert `reactive:token` refresh, so the container's signed token
                 rolls forward and the list is not act-once-only.

              One CSS rule covers the whole pending vocabulary:

              ```css
              [data-reactive-pending] { opacity: .5; pointer-events: none; }
              ```

              | Argument | |
              |---|---|
              | `records` | one record, an enumerable of records, or built Streamable components |
              | `in: :name` | the `reactive_collection` they live in — how the row DOM ids *and* the count / empty-state bookkeeping are resolved |
              | a block | your enqueue. **Anything ActiveJob-enqueued inside it captures the settle handle**, including from a service object |
              | `job:` / `args:` | sugar for the common case. `args:` is an Array (one record) or a Proc called per record; omitted means `perform_later(record)` |
              | `peers: true` | also broadcast each settle to the container's record stream. Default is actor-only, matching `reply.defer` |

              The block form is what makes the motivating case work — the enqueue
              usually lives in a service object, not the action:

              ```ruby
              def restore_all
                restorable = @bulk_payment.transfers.restorable.to_a
                reply.pending(restorable, in: :declined, peers: true) do
                  BatchRestoreService.call(bulk_payment: @bulk_payment)
                end.flash(:notice, "Putting #{restorable.size} back…")
              end
              ```
            MD
          end
        end

        def the_settle
          DocsUI::Section('The settle verbs') do
            md <<~MD
              | Verb | Emits |
              |---|---|
              | `s.replace(record)` | the row, re-rendered in place. No count churn — a replace moves no boundary |
              | `s.remove(record, from: :name)` | row + count + empty-state restore. `from:` defaults to the collection `reply.pending` named |
              | `s.append(record, to: :name)` / `s.prepend` | row + count + empty-state clear |
              | `s.move(record, from:, to:)` | ordered remove-then-append between two collections |
              | `s.count(:name)` | only the count companion |
              | `s.flash(level, content)` | the outcome — this is how the page stops saying "Queued" |
              | `s.js(ops)` / `s.streams!(*raw)` | the `reply.js` / `reply.streams` escape hatches |

              Every one routes through the same `Phlex::Reactive::Collections`
              decisions the actor's reply uses — the 0↔1 empty-state boundary and the
              count companion live in exactly one place, so the job-side and reply-side
              paths cannot drift.
            MD
          end
        end

        def the_rules
          DocsUI::Section('The rules that make it safe') do
            md <<~MD
              **The handle rides ActiveJob metadata, not `perform`'s arity.**
              `reply.pending` installs it in a thread-local and runs your enqueue
              inside it; `Settles#initialize` captures it onto the job instance and
              `#serialize` copies it into the job's metadata. So **every other
              caller of the same job — a nightly sweep, a webhook — keeps working
              unchanged**, and `reactive_settle` is simply a no-op there. That is
              load-bearing: these jobs almost always have non-UI callers.

              **It works under `enqueue_after_transaction_commit = true`.** Rails
              defers that enqueue to `ActiveRecord.after_all_transactions_commit`,
              and the endpoint runs your action inside a transaction — so the
              enqueue (and its `serialize`) happens *after* the block has exited.
              The capture is therefore at job **instantiation**, which is
              synchronous inside the block either way. Nothing to configure.

              **A job that raises still clears the pending state — when it can
              attribute it.** The `job:`/`args:` form enqueues one job per record
              and narrows each job's handle to *that record's* target, so a failure
              clears exactly its row and the container, then re-raises for your
              retry policy. The **block** form cannot be narrowed (the gem cannot
              map an arbitrary enqueue back to a record), so a failure there clears
              nothing and logs why — un-dimming 176 rows that are still working
              would be a worse lie; `finish: true` sweeps them up. The subscription
              is deliberately **not** torn down on failure — a retry must still be
              able to reach the actor.

              **Finishing clears every target, not just the container.** A settle
              that only flashes emits no row stream, so nothing swaps that row's
              node — the finish sweep is what removes its markers.

              **One `reply.pending` per container, per reply.** Every pending
              segment emits a directive targeting the container's id, and the client
              keys subscriptions by target — a second call would supersede the first
              and orphan its jobs, so it raises instead.

              **Peer delivery is best effort.** If a peer broadcast fails after the
              actor's message already went out, the job is *not* failed — retrying
              it would re-run `perform` and send the actor's settle (and its flash)
              a second time. The failure is logged instead.

              **One stream key per `reply.pending` call.** A durable broadcast to a
              never-seen key creates a real PGMQ table (reclaimed by pgbus's hourly
              orphan sweep at a 24 h threshold), so a key per record would leave 177
              tables sitting for a day and open 177 SSE connections. All N settles
              share one key and one subscription.

              **Teardown is therefore explicit.** Because the key is shared, tearing
              down on the *first* arrival would cut off the other N−1.
              `reactive_settle` finishes automatically when `reply.pending` marked
              exactly **one** target; a fan-out passes `finish: true` from whatever
              knows it is last — a `Pgbus::Batch` `on_finish` callback, or the final
              job of a staggered sequence. Until then the subscription is superseded
              by the container's next `reply.pending`, or closed when the page
              unloads.

              **The signature is not authorization.** `reply.pending` signs the
              *container's* identity so the job can rebuild it off the request
              thread. That is not permission to act — `authorize!` in the action,
              exactly as everywhere else.
            MD

            DocsUI::Callout(:info) do
              md <<~MD
                **`reply.pending` needs the defer PUSH lane**
                (`Phlex::Reactive.settle_capable?` — pgbus reactive Streams +
                `SignedName` + ActiveJob, and `defer_transport` not forced to
                `:fetch`). A settle has no pull fallback: the client cannot poll "is
                the job done yet".

                Without it, `reply.pending` **degrades rather than breaks** — your
                enqueue still runs, no handle is installed, and **no pending markers
                are emitted**, so the UI shows the pre-job world (today's behavior)
                instead of a shimmer that could never resolve. A one-time warning
                says so.

                The pgbus **client** must be on the page too. The server picks the
                push lane on server-side capability alone; if the browser has no
                `<pgbus-stream-source>` element registered, `reply.defer` degrades
                to its fetch token but a settle cannot — the subscription never
                opens and the markers would sit there. The client logs a loud
                console error naming the cause.
              MD
            end
          end
        end

        def peers
          DocsUI::Section('Broadcasting a collection delta to peers') do
            md <<~MD
              `broadcast_to(append:)` emits the **bare row** — it has no container
              instance, so it cannot resolve the declaration or run the size
              resolver. Its collection counterpart does:

              ```ruby
              ReconcileQueue.broadcast_collection_to(@bulk_payment, :transfers,
                container: self, in: :unreconcilable, remove: transfer,
                exclude: reactive_connection_id)
              ```

              `row:` carries the row component's extra init kwargs — pass the same
              ones the actor got, or a peer whose row has a required kwarg raises
              instead of rendering. A `remove:` may be a record or an already-built
              dom-id string, matching `reply.remove(id, from:)`.

              Row **plus** count companion **plus** empty-state toggle. `coalesce:`
              (default `settle_coalesce_window_ms`, 50 ms) applies to the
              **aggregate** streams only: the count and empty-state are idempotent
              replaces of stable targets, so a 177-row fan-out collapses to a handful
              of them. The **row** stream is never coalesced — an append is not
              idempotent, and each row is a distinct target.

              Coalescing needs pgbus with
              [zoolutions/pgbus#465](https://github.com/zoolutions/pgbus/issues/465);
              on anything older the window is ignored and every aggregate goes out —
              chattier, equally correct. The actor's own lane never needs it: its row
              and aggregates are concatenated into **one** durable message per
              settle, so there is nothing extra to collapse.
            MD
          end
        end

        def config_reference
          DocsUI::Section('Configuration reference') do
            md <<~MD
              | Setting | Default | What it does |
              |---|---|---|
              | `Phlex::Reactive.settle_coalesce_window_ms` | `50` | Window for the aggregate (count / empty-state) streams on the peers path. |

              There is deliberately **no** `settle_token_ttl`. A settle has no
              pull lane for a token to govern — the client cannot poll "is the
              job done yet", and redeeming such a token at the defer endpoint
              would render the *pre-job* component, i.e. the exact bug
              `reply.pending` fixes. The settle's wait is bounded by the job.

              See also [Deferred rendering](/docs/deferred-rendering) — the transport
              this composes with — and [Collections](/docs/example-collections) for
              the synchronous add/remove case.
            MD
          end
        end
      end
    end
  end
end
