# frozen_string_literal: true

require "rails_helper"

# Issue #248 — reply.pending: an action that ENQUEUES the work replies with a
# truthful pending state and hands the fulfilment to the app's own job.
RSpec.describe Phlex::Reactive::Pending, type: :request do
  let(:row_component) do
    Class.new(ApplicationComponent) do
      include Phlex::Reactive::Streamable

      def self.name = "PendingSpecRow"
      def self.model_param_name = :todo
      def initialize(todo:) = @todo = todo
      def id = dom_id(@todo)
      def view_template = li(id:) { @todo.title }
    end
  end

  let(:container_class) do
    row = row_component
    Class.new(ApplicationComponent) do
      include Phlex::Reactive::Streamable
      include Phlex::Reactive::Component

      def self.name = "PendingSpecList"

      reactive_collection :todos,
        item: row,
        container: "pending-list",
        count: "pending-count",
        size: -> { Todo.count }

      def id = "pending-root"
      def view_template = div(id:, **reactive_attrs) { "" }
    end
  end

  let(:todo) { Todo.create!(title: "buy milk", done: false) }
  let(:other) { Todo.create!(title: "walk dog", done: false) }
  let(:container) { container_class.new }

  # A stand-in for an ActiveJob class: reply.pending only ever calls
  # perform_later on it. (A class-level accumulator is fine for a throwaway
  # anonymous class in one example — hence the cop disable.)
  def fake_job
    Class.new do
      # rubocop:disable-next ThreadSafety/ClassInstanceVariable
      def self.enqueued = @enqueued ||= []
      def self.perform_later(*args) = enqueued << args
    end
  end

  # The push lane is what a settle NEEDS (there is no pull fallback), so most
  # examples run with it forced on and the pgbus seams stubbed.
  def with_settle_lane
    allow(Phlex::Reactive).to receive(:settle_capable?).and_return(true)
    allow(described_class).to receive_messages(one_shot_stream_key: "prdefer_abc123",
      signed_stream_src: "/pgbus/streams/signed-abc")
    yield
  end

  describe "the reply" do
    it "does NOT re-render the container — that would draw the pre-job world" do
      with_settle_lane do
        response = container.reply.pending(todo, in: :todos) { nil }
        expect(response.render_self?).to be(false)
      end
    end

    it "still refreshes the container's token (cosmos#1939 — or the list is act-once-only)" do
      with_settle_lane do
        response = container.reply.pending(todo, in: :todos) { nil }
        expect(response.refresh_token?).to be(true)
        expect(response.token_component).to be(container)
      end
    end

    it "chains like every other reply verb" do
      with_settle_lane do
        response = container.reply.pending(todo, in: :todos) { nil }.flash(:notice, "Queued 1…")
        expect(response.streams.join).to include("Queued 1…")
      end
    end

    it "refuses an unknown keyword rather than silently dropping it" do
      # `in:` is a Ruby keyword, so every other kwarg lands in **opts. A dropped
      # `jbo:` would mark the rows pending and enqueue NOTHING — a permanently
      # shimmering row, the exact failure this feature prevents.
      with_settle_lane do
        expect { container.reply.pending(todo, in: :todos, jbo: fake_job) }
          .to raise_error(ArgumentError, /unknown keyword\(s\) :jbo/)
      end
    end

    it "refuses a SECOND pending on the same container — the client would supersede the first" do
      with_settle_lane do
        expect { container.reply.pending(todo, in: :todos) { nil }.pending(other, in: :todos) { nil } }
          .to raise_error(Phlex::Reactive::Error, /called twice/)
      end
    end

    it "is dead on a redirect reply and says so" do
      with_settle_lane do
        expect { container.reply.redirect("/x").pending(todo, in: :todos) { nil } }
          .to raise_error(Phlex::Reactive::Error, /navigating away/)
      end
    end
  end

  describe "the enqueue block" do
    it "runs the block so the app enqueues its own jobs however it likes" do
      ran = false
      with_settle_lane { container.reply.pending(todo, in: :todos) { ran = true } }
      expect(ran).to be(true)
    end

    it "exposes the settle handle to anything enqueued inside the block" do
      seen = nil
      with_settle_lane { container.reply.pending(todo, in: :todos) { seen = described_class.current_handle } }

      expect(seen.stream_key).to eq("prdefer_abc123")
      expect(seen.container_class).to eq("PendingSpecList")
      expect(seen.anchor).to eq("pending-root")
      expect(seen.collection).to eq(:todos)
      expect(seen.count).to eq(1)
    end

    it "clears the handle again once the block returns" do
      with_settle_lane { container.reply.pending(todo, in: :todos) { nil } }
      expect(described_class.current_handle).to be_nil
    end

    it "clears the handle even when the block raises" do
      with_settle_lane do
        expect { container.reply.pending(todo, in: :todos) { raise "boom" } }.to raise_error("boom")
      end
      expect(described_class.current_handle).to be_nil
    end

    it "accepts the job:/args: sugar instead of a block" do
      job = fake_job
      with_settle_lane { container.reply.pending(todo, in: :todos, job:, args: [todo.id]) }

      expect(job.enqueued).to eq([[todo.id]])
    end

    it "passes the record itself when no args: are given" do
      job = fake_job
      with_settle_lane { container.reply.pending(todo, in: :todos, job:) }

      expect(job.enqueued).to eq([[todo]])
    end

    it "fans out over an enumerable, calling a Proc args: per record" do
      job = fake_job
      with_settle_lane do
        # rubocop:disable-next Style/ItBlockParameter -- args: is a per-record
        # lambda; `it` would shadow the enclosing example's block param.
        container.reply.pending([todo, other], in: :todos, job:, args: ->(record) { [record.id, :restore] })
      end

      expect(job.enqueued).to eq([[todo.id, :restore], [other.id, :restore]])
    end

    it "walks a one-shot Enumerable ONCE — the targets and the enqueue share it" do
      # A lazy/one-shot source consumed while resolving target ids would leave
      # run_enqueue with an exhausted object: markers on every row, no jobs.
      job = fake_job
      # rubocop:disable-next Style/ItBlockParameter -- nested blocks: `y` is the
      # yielder and `r` the record; collapsing either to `it` shadows the other.
      one_shot = Enumerator.new { |y| [todo, other].each { |r| y << r } }.lazy.map { it }

      with_settle_lane { container.reply.pending(one_shot, in: :todos, job:) }

      expect(job.enqueued).to eq([[todo], [other]])
    end

    it "resolves a Relation once, so the marked rows and the enqueued jobs cannot disagree" do
      job = fake_job
      relation = Todo.where(id: [todo.id, other.id]).order(:id)
      calls = 0
      allow(relation).to receive(:to_a).and_wrap_original do
        calls += 1
        it.call
      end

      with_settle_lane { container.reply.pending(relation, in: :todos, job:) }

      expect(calls).to eq(1)
      expect(job.enqueued.size).to eq(2)
    end

    it "narrows the handle to ONE target per job, so a failure can be attributed" do
      seen = []
      job = Class.new do
        define_singleton_method(:perform_later) do |*|
          seen << Phlex::Reactive::Pending.current_handle.target_ids
        end
      end
      with_settle_lane { container.reply.pending([todo, other], in: :todos, job:) }

      expect(seen).to eq([todo, other].map { [ActionView::RecordIdentifier.dom_id(it)] })
    end

    it "gives the BLOCK form the whole target list — an arbitrary enqueue cannot be mapped back" do
      seen = nil
      with_settle_lane do
        container.reply.pending([todo, other], in: :todos) { seen = described_class.current_handle.target_ids }
      end

      expect(seen.size).to eq(2)
    end

    it "refuses an Array args: for a multi-record pending (ambiguous)" do
      job = Class.new { def self.perform_later(*) = nil }
      with_settle_lane do
        expect { container.reply.pending([todo, other], in: :todos, job:, args: [1]) }
          .to raise_error(ArgumentError, /Proc/)
      end
    end
  end

  describe "the emitted wire streams" do
    subject(:streams) do
      with_settle_lane do
        response = container.reply.pending([todo, other], in: :todos) { nil }
        described_class.streams_for(response.pending_segments.first).map(&:to_s)
      end
    end

    it "marks every pending row with data-reactive-pending + aria-busy" do
      row_ids = [todo, other].map { ActionView::RecordIdentifier.dom_id(it) }
      # rubocop:disable-next Style/ItBlockParameter -- nested blocks: the inner
      # `it` is the stream, the outer one the row id; they must stay distinct.
      row_ids.each do |dom_id|
        marker = streams.find { it.include?(%(target="#{dom_id}")) }
        expect(marker).to include('action="reactive:js"')
        expect(marker).to include("data-reactive-pending")
        expect(marker).to include("aria-busy")
      end
    end

    it "emits exactly ONE subscription directive, anchored on the container" do
      directives = streams.select { it.include?('action="reactive:defer"') }
      expect(directives.size).to eq(1)
      expect(directives.first).to include('target="pending-root"')
      expect(directives.first).to include('data-reactive-defer-via="stream"')
      expect(directives.first).to include('data-reactive-defer-src="/pgbus/streams/signed-abc"')
      expect(directives.first).to include('data-reactive-defer-since-id="0"')
    end

    it "carries no fallback defer token — :fetch is not a settle lane" do
      expect(streams.join).not_to include("data-reactive-defer-token")
    end
  end

  describe "degrading without the push lane" do
    it "still runs the enqueue block — the work must happen either way" do
      allow(Phlex::Reactive).to receive(:settle_capable?).and_return(false)
      ran = false
      container.reply.pending(todo, in: :todos) { ran = true }
      expect(ran).to be(true)
    end

    it "installs NO handle, so reactive_settle no-ops in the job" do
      allow(Phlex::Reactive).to receive(:settle_capable?).and_return(false)
      seen = :unset
      container.reply.pending(todo, in: :todos) { seen = described_class.current_handle }
      expect(seen).to be_nil
    end

    it "records no segment — no pending markers, no lie about a settle that can never land" do
      allow(Phlex::Reactive).to receive(:settle_capable?).and_return(false)
      response = container.reply.pending(todo, in: :todos) { nil }
      expect(response.pending_segments).to be_empty
      expect(response.pending?).to be(false)
    end
  end

  describe "targets without a collection" do
    it "accepts Streamable component instances directly" do
      with_settle_lane do
        response = container.reply.pending(row_component.new(todo:)) { nil }
        streams = described_class.streams_for(response.pending_segments.first).map(&:to_s)
        expect(streams.join).to include(%(target="#{ActionView::RecordIdentifier.dom_id(todo)}"))
      end
    end

    it "refuses a bare record with no collection to resolve it through" do
      with_settle_lane do
        expect { container.reply.pending(todo) { nil } }
          .to raise_error(ArgumentError, /in: :collection_name/)
      end
    end
  end
end
