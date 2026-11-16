# frozen_string_literal: true

require "system_helper"

# Issue #474: a component subscribed to its own broadcast stream, over REAL
# SSE. The page renders TodoStatusComponent and nothing else that subscribes
# (no turbo_stream_from); a job finishes the todo and broadcasts with
# broadcast_self. Runs only in the pgbus cells (TRANSPORT=pgbus); the :pgbus
# tag turns transactional fixtures off, so the job's write commits.
RSpec.describe "reactive_subscribe (issue #474)", :pgbus, type: :system do
  before do
    skip "pgbus transport cell only (TRANSPORT=pgbus)" unless ENV["TRANSPORT"] == "pgbus"
  end

  let(:todo) { Todo.create!(title: "Ship the release") }

  def subscribe_source = "pgbus-stream-source[data-reactive-subscribe-source]"

  # The root's own source is open (it has a connection id). The server-side
  # subscriber registration settles a beat after the handshake reaches the
  # client (see pgbus_transport_spec.rb): ephemeral delivery reaches only live
  # subscribers.
  def wait_for_subscription
    expect(page).to have_css("#{subscribe_source}[connection-id]", visible: :all, wait: 10)
    sleep 0.5
  end

  it "receives the job's broadcast on the declared stream, with no other markup on the page" do
    visit "/subscribe/#{todo.id}"
    expect(page).to have_css("[data-testid='todo-status-state']", text: "Open")
    expect(page).to have_no_css("turbo-cable-stream-source, pgbus-stream-source:not([data-reactive-subscribe-source])",
      visible: :all)
    page.execute_script("window.__noReload = true")
    wait_for_subscription

    FinishTodoJob.perform_now(todo.id)

    expect(page).to have_css("[data-testid='todo-status-state']", text: "Done", wait: 10)
    expect(page.evaluate_script("window.__noReload")).to be(true)
    expect(page).to have_css(subscribe_source, visible: :all, count: 1)
  end

  it "keeps the one connection across a replace of the root that keeps its id" do
    visit "/subscribe/#{todo.id}"
    wait_for_subscription
    before = find(subscribe_source, visible: :all)["connection-id"]

    # A plain (non-morph) replace: the controller disconnects and reconnects.
    page.execute_script(<<~JS)
      const root = document.querySelector("[data-testid='todo-status']")
      root.replaceWith(root.cloneNode(true))
    JS

    expect(page).to have_css("[data-testid='todo-status']")
    expect(page).to have_css("#{subscribe_source}[connection-id='#{before}']", visible: :all, count: 1)
  end

  # Turbo 8's page refresh by morph drops what the server did not render from
  # <body>, while the root stays connected. The minted source is
  # data-turbo-permanent, so it stays, connection and all.
  it "keeps the connection through a page refresh by morph, and still receives the broadcast" do
    visit "/subscribe/#{todo.id}"
    wait_for_subscription
    before = find(subscribe_source, visible: :all)["connection-id"]

    page.execute_script(<<~JS)
      const meta = document.createElement("meta")
      meta.name = "turbo-refresh-method"
      meta.content = "morph"
      document.head.appendChild(meta)
      window.__noReload = true
      document.addEventListener("turbo:morph", () => { document.documentElement.dataset.morphed = "" }, { once: true })
      window.Turbo.visit(location.href, { action: "replace" })
    JS

    expect(page).to have_css("html[data-morphed]", visible: :all, wait: 10)
    expect(page.evaluate_script("window.__noReload")).to be(true)
    expect(page).to have_css("#{subscribe_source}[connection-id='#{before}']", visible: :all, count: 1)

    FinishTodoJob.perform_now(todo.id)

    expect(page).to have_css("[data-testid='todo-status-state']", text: "Done", wait: 10)
  end

  # The refreshed page adds a server-rendered <pgbus-stream-source> at the end
  # of <body>. Idiomorph (Turbo 8.0.12's ignores ids) pairs an old node with a
  # new node of its tag; the minted sources sit in a permanent box whose tag no
  # server page renders, so the new source is inserted and the minted one kept.
  it "keeps a source the refreshed page adds beside the minted one" do
    visit "/subscribe/#{todo.id}"
    wait_for_subscription
    before = find(subscribe_source, visible: :all)["connection-id"]
    todo.update!(done: true) # no broadcast: the refresh renders the extra source

    page.execute_script(<<~JS)
      const meta = document.createElement("meta")
      meta.name = "turbo-refresh-method"
      meta.content = "morph"
      document.head.appendChild(meta)
      document.addEventListener("turbo:morph", () => { document.documentElement.dataset.morphed = "" }, { once: true })
      window.Turbo.visit(location.href, { action: "replace" })
    JS

    expect(page).to have_css("html[data-morphed]", visible: :all, wait: 10)
    expect(page).to have_css("pgbus-stream-source[data-testid='extra-source']", visible: :all, count: 1)
    expect(page).to have_css("#{subscribe_source}[connection-id='#{before}']", visible: :all, count: 1)
  end

  it "closes the source when the root leaves the page" do
    visit "/subscribe/#{todo.id}"
    wait_for_subscription

    page.execute_script("document.querySelector('[data-testid=\"todo-status\"]').remove()")

    expect(page).to have_no_css(subscribe_source, visible: :all, wait: 5)
  end

  it "refuses a tampered src (pgbus verifies the signature)" do
    visit "/subscribe/#{todo.id}"
    src = find(subscribe_source, visible: :all)["src"]
    status, body = page.evaluate_async_script(<<~JS, "#{src}x")
      const done = arguments[arguments.length - 1]
      fetch(arguments[0]).then(async (r) => done([r.status, await r.text()]), () => done([0, ""]))
    JS

    expect([status, body]).to eq([404, "pgbus: invalid signed stream name"])
  end
end
