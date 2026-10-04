# frozen_string_literal: true

require "system_helper"

# Request-count helpers (issue #279): the client keeps per-kind totals of the
# reactive requests it made on <html data-reactive-requests> (verbose-gated, on
# in dev/test), and TestHelpers::System reads, resets and waits on them — so a
# spec can say "one request on this gesture, none after" without a fetch spy.
RSpec.describe "Reactive request-count helpers (issue #279)", type: :system do
  it "counts one action request per gesture, and fails the count after two" do
    visit "/counter"
    reset_reactive_requests!

    find("[data-testid='inc']").click
    expect(page).to have_reactive_requests(1)
    expect(page).to have_reactive_requests(1, kind: :action)
    expect(page).to have_reactive_requests(0, kind: :defer)
    expect(page).to have_reactive_text("counter-value", "1")

    find("[data-testid='inc']").click
    expect(page).to have_reactive_text("counter-value", "2")
    expect(reactive_request_count).to eq(action: 2, defer: 0)
    expect { expect(page).to have_reactive_requests(1, wait: 0.5) }
      .to raise_error(RSpec::Expectations::ExpectationNotMetError, /expected 1 reactive request.*got 2/)
  end

  it "counts a deferred render under kind: :defer" do
    visit "/defer"
    reset_reactive_requests!

    find("[data-testid='defer-bump']").click
    expect(page).to have_reactive_requests(1, kind: :action, wait: 5)
    expect(page).to have_reactive_requests(1, kind: :defer, wait: 5)
    expect(page).to have_css("[data-testid='totals-value']", text: "2")
  end

  # The lazy shell is the page's ONLY reactive root when it fetches: its own
  # verbose stamp must open the gate, or the count would depend on page layout.
  it "counts a lazy mount's fetch when the shell is the only reactive root" do
    visit "/lazy_stats"

    expect(page).to have_css("[data-testid='stats-value']", text: "stats:week")
    expect(page).to have_reactive_requests(1, kind: :defer)
    expect(page).to have_reactive_requests(0, kind: :action)
  end

  it "reset_reactive_requests! re-baselines after a Turbo Drive visit" do
    visit "/counter"
    find("[data-testid='inc']").click
    expect(page).to have_reactive_requests(1)

    # Mark the OLD body so the barrier below waits for Drive to swap it — the
    # old page's button would otherwise satisfy have_css before the visit lands.
    page.execute_script(<<~JS)
      window.__noReload = "alive"
      document.body.setAttribute("data-old-body", "")
      Turbo.visit("/counter")
    JS
    expect(page).to have_no_css("body[data-old-body]")
    expect(page).to have_css("[data-testid='inc']")
    wait_for_reactive
    expect(page.evaluate_script("window.__noReload")).to eq("alive") # a Drive visit, not a reload

    reset_reactive_requests!
    expect(reactive_request_count).to eq(action: 0, defer: 0)
    find("[data-testid='inc']").click
    expect(page).to have_reactive_requests(1)
  end

  context "with verbose off" do
    around do
      previous = Phlex::Reactive.verbose_errors
      Phlex::Reactive.verbose_errors = false
      it.run
    ensure
      Phlex::Reactive.verbose_errors = previous
    end

    it "writes no attribute to <html>" do
      visit "/counter"
      find("[data-testid='inc']").click
      expect(page).to have_reactive_text("counter-value", "1")
      wait_for_reactive
      expect(page).to have_no_css("html[data-reactive-requests]")
    end
  end
end
