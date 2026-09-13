# frozen_string_literal: true

require "rails_helper"

# Issue #248 end-to-end, through the REAL action endpoint: an action that
# enqueues work replies with a truthful pending state, the app's own job
# captures the settle handle across the enqueue, and settling it emits the full
# collection bookkeeping the actor's reply would have.
RSpec.describe "async-action lifecycle (issue #248)", type: :request do
  let(:klass) { ArchiveQueueComponent }
  let!(:todo) { Todo.create!(title: "buy milk") }
  let(:dom_id) { ActionView::RecordIdentifier.dom_id(todo) }

  # What the actor's one-shot durable stream received.
  let(:broadcasts) { [] }

  before do
    captured = broadcasts
    stream = double("stream")
    allow(stream).to receive(:broadcast) { |html, **| captured << html.to_s }
    stub_const("Pgbus", Module.new) unless defined?(Pgbus)
    allow(Pgbus).to receive(:stream).and_return(stream)

    allow(Phlex::Reactive).to receive(:settle_capable?).and_return(true)
    allow(Phlex::Reactive::Defer).to receive_messages(
      one_shot_stream_key: "prdefer_deadbeef", signed_stream_src: "/pgbus/streams/signed"
    )
  end

  # Restore whatever the suite had, not a hardcoded :test — otherwise this spec
  # silently leaks :test into every example that follows it.
  around do
    previous = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    it.run
    ActiveJob::Base.queue_adapter = previous
  end

  describe "the action's reply" do
    it "marks the row pending and opens ONE subscription, without re-rendering the list" do
      post_action(klass, act: "archive", params: { id: todo.id })

      expect(response).to have_http_status(:ok)
      # The pending marker rides the existing reactive:js op lane.
      expect(response.body).to include('action="reactive:js"', %(target="#{dom_id}"))
      expect(response.body).to include("data-reactive-pending")
      # Exactly one subscription directive, anchored on the container.
      expect(response.body.scan('action="reactive:defer"').size).to eq(1)
      expect(response.body).to include('target="archive-queue-root"', 'data-reactive-defer-via="stream"')
    end

    it "does NOT draw the pre-job world — no row remove, no count change, no re-render" do
      post_action(klass, act: "archive", params: { id: todo.id })

      expect(response.body).not_to include(%(action="remove" target="#{dom_id}"))
      expect(response.body).not_to include('action="replace" target="archive-queue-root"')
      expect(response.body).not_to include('target="archive-queue-count"')
    end

    it "still rolls the container's token forward (cosmos#1939 — else act-once-only)" do
      post_action(klass, act: "archive", params: { id: todo.id })

      expect(response.body).to include("data-reactive-token-value")
    end

    it "carries the flash the action chained on" do
      post_action(klass, act: "archive", params: { id: todo.id })

      expect(response.body).to include("Archiving buy milk…")
    end

    it "narrows the handle to this record's target, so a failure is attributable" do
      post_action(klass, act: "archive", params: { id: todo.id })

      handle = ArchiveTodoJob.queue_adapter.enqueued_jobs.first["phlex_reactive_settle"]
      expect(handle["ids"]).to eq([dom_id])
    end

    it "enqueues the app's own job with its own arguments" do
      expect { post_action(klass, act: "archive", params: { id: todo.id }) }
        .to have_enqueued_job(ArchiveTodoJob).with(todo.id)
    end

    it "does not destroy the record — the JOB owns the work" do
      expect { post_action(klass, act: "archive", params: { id: todo.id }) }.not_to change(Todo, :count)
    end
  end

  describe "the job's settle" do
    it "emits the row remove, the count companion and the empty-state restore" do
      post_action(klass, act: "archive", params: { id: todo.id })
      perform_enqueued_jobs

      payload = broadcasts.join
      expect(payload).to include('action="remove"', %(target="#{dom_id}"))
      expect(payload).to include('target="archive-queue-count"')
      # 1 -> 0: the empty-state comes back INTO the container.
      expect(payload).to include('action="append"', 'target="archive-queue"')
    end

    it "tells the operator the outcome — the page stops saying 'Archiving…'" do
      post_action(klass, act: "archive", params: { id: todo.id })
      perform_enqueued_jobs

      expect(broadcasts.join).to include("Archived buy milk")
    end

    it "tears the one-shot subscription down (a single-target pending auto-finishes)" do
      post_action(klass, act: "archive", params: { id: todo.id })
      perform_enqueued_jobs

      expect(broadcasts.join).to include('target="reactive-defer-src-archive-queue-root"')
    end
  end

  describe "the fan-out (the enqueue lives in a block)" do
    let!(:second) { Todo.create!(title: "walk dog") }

    it "marks every row pending but opens only ONE subscription for the whole call" do
      post_action(klass, act: "archive_all")

      [todo, second].each do
        expect(response.body).to include(%(target="#{ActionView::RecordIdentifier.dom_id(it)}"))
      end
      expect(response.body.scan('action="reactive:defer"').size).to eq(1)
    end

    it "hands the handle to every job enqueued inside the block" do
      post_action(klass, act: "archive_all")

      expect(ArchiveTodoJob.queue_adapter.enqueued_jobs.size).to eq(2)
      ids = [todo, second].map { ActionView::RecordIdentifier.dom_id(it) }
      # The BLOCK form cannot map an arbitrary enqueue back to a record, so every
      # job carries the WHOLE target list — "these jobs settle these targets".
      ArchiveTodoJob.queue_adapter.enqueued_jobs.each do
        expect(it["phlex_reactive_settle"]).to include("key" => "prdefer_deadbeef", "ids" => ids)
      end
    end

    it "settles every row and never tears the shared subscription down mid-fan-out" do
      post_action(klass, act: "archive_all")
      perform_enqueued_jobs

      payload = broadcasts.join
      [todo, second].each do
        expect(payload).to include(%(target="#{ActionView::RecordIdentifier.dom_id(it)}"))
      end
      expect(payload).not_to include('target="reactive-defer-src-archive-queue-root"')
    end
  end

  describe "a job with NO settle handle (a sweep, a webhook)" do
    it "runs unchanged and broadcasts nothing" do
      ArchiveTodoJob.perform_later(todo.id)
      expect { perform_enqueued_jobs }.to change(Todo, :count).by(-1)

      expect(broadcasts).to be_empty
    end
  end

  describe "without the push lane" do
    before { allow(Phlex::Reactive).to receive(:settle_capable?).and_return(false) }

    it "degrades to a plain enqueue: the work still happens, nothing lies about pending" do
      expect { post_action(klass, act: "archive", params: { id: todo.id }) }
        .to have_enqueued_job(ArchiveTodoJob)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("data-reactive-pending")
      expect(response.body).not_to include('action="reactive:defer"')
    end

    it "leaves reactive_settle a no-op in the job" do
      post_action(klass, act: "archive", params: { id: todo.id })
      perform_enqueued_jobs

      expect(broadcasts).to be_empty
      expect(Todo.count).to eq(0)
    end
  end

  # Issue #254: Rails' `enqueue_after_transaction_commit` (the 7.2+ recommended
  # setting, and the default in many apps) defers `job.enqueue` to
  # ActiveRecord.after_all_transactions_commit. The endpoint runs every action
  # inside transaction_wrapper, so the deferral ALWAYS fires after
  # reply.pending's with_handle block has exited — `serialize` runs there, with
  # an empty thread-local. The only moment guaranteed to be inside the block is
  # the job's INSTANTIATION, which is where the handle is captured.
  describe "under enqueue_after_transaction_commit = true (issue #254)" do
    around do
      previous = ArchiveTodoJob.enqueue_after_transaction_commit
      ArchiveTodoJob.enqueue_after_transaction_commit = true
      it.run
      ArchiveTodoJob.enqueue_after_transaction_commit = previous
    end

    it "still carries the handle through the job:/args: sugar" do
      post_action(klass, act: "archive", params: { id: todo.id })

      enqueued = ArchiveTodoJob.queue_adapter.enqueued_jobs
      expect(enqueued.size).to eq(1)
      expect(enqueued.first["phlex_reactive_settle"]).to include("key" => "prdefer_deadbeef", "ids" => [dom_id])
    end

    it "still carries the handle through the BLOCK form" do
      Todo.create!(title: "walk dog")
      post_action(klass, act: "archive_all")

      enqueued = ArchiveTodoJob.queue_adapter.enqueued_jobs
      expect(enqueued.size).to eq(2)
      enqueued.each { expect(it["phlex_reactive_settle"]).to include("key" => "prdefer_deadbeef") }
    end

    it "settles the row instead of leaving it shimmering until someone reloads" do
      post_action(klass, act: "archive", params: { id: todo.id })
      perform_enqueued_jobs

      payload = broadcasts.join
      expect(payload).to include('action="remove"', %(target="#{dom_id}"))
      expect(payload).to include("Archived buy milk")
    end

    it "leaves a job enqueued OUTSIDE any pending call carrying nothing" do
      ArchiveTodoJob.perform_later(todo.id)

      expect(ArchiveTodoJob.queue_adapter.enqueued_jobs.first).not_to have_key("phlex_reactive_settle")
    end
  end

  describe "a rolled-back action" do
    it "leaks no pending marker and no subscription directive" do
      allow(Todo).to receive(:find).and_raise(ActiveRecord::RecordNotFound)
      post_action(klass, act: "archive", params: { id: todo.id })

      expect(response.body).not_to include('action="reactive:defer"')
      expect(response.body).not_to include("data-reactive-pending")
    end
  end
end
