# frozen_string_literal: true

require "rails_helper"

# Issue #249 — the opt-in pending MARKUP hook. A row component that defines
# `pending_template` gets its markup swapped by reply.pending (a real "Queued"
# badge, a genuinely removed button), in addition to the #248 markers.
RSpec.describe Phlex::Reactive::Pending, type: :request do
  let(:plain_row) do
    Class.new(ApplicationComponent) do
      include Phlex::Reactive::Streamable

      def self.name = "PendingTemplateSpecPlainRow"
      def self.model_param_name = :todo
      def initialize(todo:) = @todo = todo
      def id = dom_id(@todo)
      def view_template = li(id:) { @todo.title }
    end
  end

  let(:hook_row) do
    Class.new(ApplicationComponent) do
      include Phlex::Reactive::Streamable

      def self.name = "PendingTemplateSpecHookRow"
      def self.model_param_name = :todo
      def initialize(todo:) = @todo = todo
      def id = dom_id(@todo)
      def view_template = li(id:) { button { "Archive #{@todo.title}" } }

      private

      def pending_template = li(id:, class: "queued") { span { "Queued #{@todo.title}" } }
    end
  end

  let(:todo) { Todo.create!(title: "buy milk", done: false) }
  let(:row_dom_id) { ActionView::RecordIdentifier.dom_id(todo) }

  def container_for(row)
    Class.new(ApplicationComponent) do
      include Phlex::Reactive::Streamable
      include Phlex::Reactive::Component

      def self.name = "PendingTemplateSpecList"

      reactive_collection :todos, item: row, container: "pending-list"

      def id = "pending-root"
      def view_template = div(id:, **reactive_attrs) { "" }
    end.new
  end

  def streams_for(container, target = todo, **)
    allow(Phlex::Reactive).to receive(:settle_capable?).and_return(true)
    allow(described_class).to receive_messages(one_shot_stream_key: "prdefer_abc123",
      signed_stream_src: "/pgbus/streams/signed-abc")
    response = container.reply.pending(target, **) { nil }
    described_class.streams_for(response.pending_segments.first).map(&:to_s)
  end

  after { Phlex::Reactive::Pending::Markup.reset! }

  describe "a row WITHOUT the hook" do
    it "emits exactly the #248 markers + directive — no replace stream" do
      streams = streams_for(container_for(plain_row), in: :todos)

      expect(streams.size).to eq(3)
      expect(streams[0]).to include('action="reactive:js"', %(target="#{row_dom_id}"))
      expect(streams[1]).to include('action="reactive:js"', 'target="pending-root"')
      expect(streams[2]).to include('action="reactive:defer"')
      expect(streams.join).not_to include('action="replace"')
    end
  end

  describe "a row WITH the hook" do
    subject(:streams) { streams_for(container_for(hook_row), in: :todos) }

    it "swaps the row's markup to the pending template" do
      replace = streams.find { it.include?('action="replace"') }

      expect(replace).to include(%(target="#{row_dom_id}"))
      expect(replace).to include("Queued buy milk")
      expect(replace).not_to include("Archive buy milk")
    end

    it "replaces BEFORE marking, so the markers land on the swapped node" do
      replace_at = streams.index { it.include?('action="replace"') }
      marker_at = streams.index { it.include?('action="reactive:js"') && it.include?(%(target="#{row_dom_id}")) }

      expect(replace_at).to be < marker_at
    end

    it "still emits the container marker and ONE directive" do
      expect(streams.count { it.include?('action="reactive:defer"') }).to eq(1)
      expect(streams.join).to include('target="pending-root"')
    end

    it "works for a Streamable instance passed without a collection" do
      out = streams_for(container_for(hook_row), hook_row.new(todo:))

      expect(out.join).to include("Queued buy milk")
    end
  end

  describe "the variant class" do
    it "keeps the parent's name, so a signed token still constantizes" do
      expect(Phlex::Reactive::Pending::Markup.variant_for(hook_row).name).to eq("PendingTemplateSpecHookRow")
    end

    it "is memoized per row class" do
      first = Phlex::Reactive::Pending::Markup.variant_for(hook_row)

      expect(Phlex::Reactive::Pending::Markup.variant_for(hook_row)).to be(first)
    end

    it "is rebuilt after a reset (the engine calls it on Rails code reload)" do
      before_reset = Phlex::Reactive::Pending::Markup.variant_for(hook_row)
      Phlex::Reactive::Pending::Markup.reset!

      expect(Phlex::Reactive::Pending::Markup.variant_for(hook_row)).not_to be(before_reset)
    end

    it "is reset by the engine's to_prepare hook" do
      before_reset = Phlex::Reactive::Pending::Markup.variant_for(hook_row)
      Rails.application.reloader.prepare!

      expect(Phlex::Reactive::Pending::Markup.variant_for(hook_row)).not_to be(before_reset)
    end
  end

  describe "a pending template that drops the row's id" do
    let(:idless_row) do
      Class.new(ApplicationComponent) do
        include Phlex::Reactive::Streamable

        def self.name = "PendingTemplateSpecIdlessRow"
        def self.model_param_name = :todo
        def initialize(todo:) = @todo = todo
        def id = dom_id(@todo)
        def view_template = li(id:) { @todo.title }

        private

        def pending_template = li { "Queued" }
      end
    end

    it "fails loudly — the settle could never find the row again" do
      expect { streams_for(container_for(idless_row), in: :todos) }
        .to raise_error(Phlex::Reactive::Error, /pending_template.*id=/m)
    end
  end

  describe "without the push lane" do
    it "does not swap the markup — nothing could ever settle it" do
      allow(Phlex::Reactive).to receive(:settle_capable?).and_return(false)
      response = container_for(hook_row).reply.pending(todo, in: :todos) { nil }

      expect(response.pending_segments).to be_empty
    end
  end
end
