# frozen_string_literal: true

require "system_helper"

# Issue #478: a subscribing root catches up on a broadcast sent after its
# render and before its source connected, over REAL SSE. The demo action
# renders the page, then finishes the todo and broadcasts, before it answers:
# the page is always born stale. Runs only in the pgbus cells.
RSpec.describe "reactive_subscribe catch-up (issue #478)", :pgbus, type: :system do
  before do
    skip "pgbus transport cell only (TRANSPORT=pgbus)" unless ENV["TRANSPORT"] == "pgbus"
  end

  let(:todo) { Todo.create!(title: "Ship the release") }

  def subscribe_source = "pgbus-stream-source[data-reactive-subscribe-source]"
  def subscribed = page.evaluate_script("window.__subscribed")

  # Frames replay in order: once the later frame shows Done, the earlier one
  # (sent before the render) would already have marked the paragraph.
  it "replays a durable broadcast sent before the source connected, from the watermark the root rendered" do
    visit "/subscribe/#{todo.id}/catch_up?mode=replay"

    expect(page).to have_css("[data-testid='rendered-state']", text: "Open")
    expect(page).to have_css("[data-testid='todo-replay-state']", text: "Done", wait: 10)
    expect(page).to have_no_css("[data-testid='rendered-state'].replayed-stale")
    expect(page).to have_css("#{subscribe_source}[since-id]", visible: :all, count: 1)
  end

  it "dispatches reactive:subscribed on the root, which refetches what an ephemeral stream lost" do
    visit "/subscribe/#{todo.id}/catch_up"

    expect(page).to have_css("[data-testid='rendered-state']", text: "Open")
    expect(page).to have_css("[data-testid='todo-catch-up-state']", text: "Done", wait: 10)
    expect(page).to have_no_css("#{subscribe_source}[since-id]", visible: :all)
    expect(subscribed).to match([hash_including("id" => "todo-catch-up-#{todo.id}", "reconnect" => false)])
  end

  it "dispatches it again, as a reconnect, when the root's source connects again" do
    visit "/subscribe/#{todo.id}/catch_up"
    expect(page).to have_css("#{subscribe_source}[connection-id]", visible: :all, wait: 10)
    expect(page).to have_css("[data-testid='todo-catch-up-state']", text: "Done", wait: 10)
    first = find(subscribe_source, visible: :all)["connection-id"]

    # A page render that dropped the source: the client mints it again.
    page.execute_script(<<~JS)
      document.querySelector("#{subscribe_source}").remove()
      document.dispatchEvent(new CustomEvent("turbo:render"))
    JS

    expect(page).to have_css("#{subscribe_source}[connection-id]:not([connection-id='#{first}'])", visible: :all,
      wait: 10)
    expect(subscribed.map { it["reconnect"] }).to eq([false, true])
  end
end
