# frozen_string_literal: true

require "rails_helper"

# Issue #249 end-to-end, through the REAL action endpoint: a row that defines
# `pending_template` has its markup swapped by reply.pending, and the swapped
# markup still carries a token that verifies on the row's next action.
RSpec.describe "reply.pending markup hook (issue #249)", type: :request do
  let(:klass) { PendingMarkupQueueComponent }
  let!(:todo) { Todo.create!(title: "buy milk") }
  let(:dom_id) { ActionView::RecordIdentifier.dom_id(todo) }

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

  around do
    previous = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    it.run
    ActiveJob::Base.queue_adapter = previous
  end

  it "swaps the row to its pending markup AND marks it" do
    post_action(klass, act: "archive", params: { id: todo.id })

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(%(action="replace" target="#{dom_id}"))
    expect(response.body).to include('data-testid="queued-badge"')
    expect(response.body).not_to include('data-testid="archive"')
    expect(response.body).to include("data-reactive-pending")
  end

  it "signs the PARENT's name into the swapped row's token, so its next action verifies" do
    post_action(klass, act: "archive", params: { id: todo.id })

    fragment = Nokogiri::HTML5.fragment(response.body)
    row = fragment.css("turbo-stream[action=replace][target=#{dom_id}] template").first.children.first
    token = row["data-reactive-token-value"]

    # An anonymous class name in the token would fail to constantize → 400.
    post Phlex::Reactive.action_path,
      params: { token:, act: "rename", params: { title: "renamed" } }.to_json,
      headers: { "Content-Type" => "application/json", "Accept" => "text/vnd.turbo-stream.html" }

    expect(response).to have_http_status(:ok)
    expect(todo.reload.title).to eq("renamed")
  end

  # The contract: swapped markup is un-pended by a settle that REPLACES or
  # REMOVES the row — the markers alone are attributes any settle strips.
  it "is un-pended by the job's settle removing the row" do
    post_action(klass, act: "archive", params: { id: todo.id })
    perform_enqueued_jobs

    expect(broadcasts.join).to include(%(action="remove" target="#{dom_id}"))
  end
end
