# frozen_string_literal: true

require "system_helper"

# Issue #358: presence over REAL SSE — two browser sessions on one roster.
# Runs only in the pgbus cell (TRANSPORT=pgbus) AND only once pgbus has
# per-connection presence (zoolutions/pgbus#515): until a release carries it
# the capability probe is false and every example skips. The pgbus initializer
# makes every connection the same guest member, so two sessions are two seats
# of one member.
RSpec.describe "Presence (issue #358)", :pgbus, type: :system do
  before do
    skip "pgbus transport cell only (TRANSPORT=pgbus)" unless ENV["TRANSPORT"] == "pgbus"
    skip "needs pgbus with per-connection presence (zoolutions/pgbus#515)" unless Phlex::Reactive::Presence.capable?
  end

  # A join, leave or expiry re-renders the roster in PresenceRenderJob (a state
  # change renders in the action itself). The dummy's adapter is :test, which
  # never performs; run jobs in-process, as an app's adapter would.
  around do
    saved = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :async
    it.run
  ensure
    ActiveJob::Base.queue_adapter = saved
  end

  def seats = page.all("[data-reactive-presence-peer]", visible: :all).map { it["data-reactive-presence-peer"] }.uniq

  def open_roster
    visit "/presence"
    expect(page).to have_css("pgbus-stream-source[connection-id]", visible: :all, wait: 10)
    expect(page).to have_css("[data-reactive-presence-me]", visible: :all, wait: 10)
  end

  it "shows a second tab joining, its selection, and its leaving" do
    Capybara.using_session(:a) { open_roster }

    Capybara.using_session(:b) do
      open_roster
      find("[data-testid='step-2']").click
      expect(page).to have_css("[data-testid='step-2'] [data-reactive-presence-me]", wait: 10)
    end

    Capybara.using_session(:a) do
      # B's tab joined: the guest member now has two seats, and B's dot is on step 2.
      expect(page).to have_css("[data-testid='seats']", text: "2", wait: 10)
      expect(page).to have_css("[data-testid='step-2'] [data-reactive-presence-same-member]", wait: 10)
      expect(seats.size).to eq(2)
    end

    Capybara.using_session(:b) { visit "about:blank" }

    Capybara.using_session(:a) do
      expect(page).to have_no_css("[data-testid='step-2'] [data-reactive-presence-peer]", wait: 10)
      expect(page).to have_no_css("[data-testid='seats']", wait: 10)
    end
  end

  it "fires reactive:presence with the seat that joined" do
    Capybara.using_session(:a) do
      open_roster
      page.execute_script(<<~JS)
        const root = document.querySelector("[data-testid='viewers']")
        root.addEventListener("reactive:presence", (e) => root.setAttribute("data-joined", e.detail.joined.length))
      JS
    end

    Capybara.using_session(:b) { open_roster }

    Capybara.using_session(:a) do
      expect(page).to have_css("[data-testid='viewers'][data-joined='1']", wait: 10)
    end
  end
end
