# frozen_string_literal: true

require "system_helper"

# The global reactive-activity signal + the system-test helpers built on it
# (issue #201). The client maintains a document-level in-flight count across ALL
# reactive roots — incremented when a dispatch round trip or a deferred render
# starts, decremented when it settles — and exposes it as a
# <html data-reactive-active> marker plus reactive:busy / reactive:idle events on
# document. TestHelpers::System waits on that primitive so a spec never scrapes
# the union of per-root busy/pending selectors, holds a node a morph detaches, or
# reads a transient blank before a value settles.
#
# Waiting matchers are the barrier for every async hop — never a snapshot right
# after a click.
RSpec.describe "Global reactive-activity signal (issue #201)", type: :system do
  it "lights the <html> marker during a dispatch round trip and clears it on settle" do
    visit "/counter"

    # A pending observer flips a page flag on reactive:busy and back on
    # reactive:idle — proving the document-level EVENTS fire on the count edges.
    page.execute_script(<<~JS)
      window.__reactiveBusy = null
      document.addEventListener("reactive:busy", () => (window.__reactiveBusy = true))
      document.addEventListener("reactive:idle", () => (window.__reactiveBusy = false))
    JS

    find("[data-testid='inc']").click

    # The layer settles: the marker clears and the idle event has fired. Assert
    # via the helper (its whole contract) and prove the value landed. #counter-value
    # is a real DOM id, so have_reactive_text keys on it directly.
    wait_for_reactive
    expect(page).to have_no_css("html[data-reactive-active]")
    expect(page.evaluate_script("window.__reactiveBusy")).to be(false)
    expect(page).to have_reactive_text("counter-value", "1")
  end

  # Issue #464: the idle edge comes after the reply is drawn, and it records
  # what failed in the window it ends.
  describe "a failed round trip (issue #464)" do
    it "makes wait_for_reactive raise ReactiveReplyError naming the action, kind and status" do
      visit "/counter"
      find("[data-testid='boom']").click # a 403: the authorizer denies inside the action

      expect { wait_for_reactive }.to raise_error(
        Phlex::Reactive::TestHelpers::System::ReactiveReplyError,
        'reactive action "boom" failed (http 403) on #counter'
      )
      expect(page).to have_css("html[data-reactive-errors]")
    end

    it "only waits with allow_error: true, and the next busy edge clears the record" do
      visit "/counter"
      find("[data-testid='boom']").click

      expect(wait_for_reactive(allow_error: true)).to be_nil
      expect(page).to have_css("html[data-reactive-errors]")

      find("[data-testid='inc']").click
      expect(wait_for_reactive).to be_nil
      expect(page).to have_no_css("html[data-reactive-errors]")
    end
  end

  it "returns nil after a clean round trip, with the reply already drawn for a one-shot read" do
    visit "/counter"

    find("[data-testid='inc']").click

    expect(wait_for_reactive).to be_nil
    # No waiting matcher: a single read right after the barrier sees the morph.
    expect(page.evaluate_script("document.getElementById('counter-value').textContent")).to eq("1")
  end

  it "wait_for_reactive spans a DEFERRED render (round trip + async segment), then reads the settled value" do
    SlowTotalsComponent.render_delay_ms = 300
    visit "/defer"
    expect(page).to have_css("[data-testid='totals-value']", text: "0")

    find("[data-testid='defer-bump']").click

    # Barrier on the GLOBAL idle signal — it covers BOTH the action round trip and
    # the deferred segment (data-reactive-active stays up until the defer arrives),
    # which wait_for_turbo could not. After it returns the whole layer is settled.
    wait_for_reactive(timeout: 5)
    expect(page).to have_no_css("html[data-reactive-active]")
    expect(page).to have_no_css("#slow-totals[data-reactive-defer-pending]")
    expect(page).to have_css("[data-testid='totals-value']", text: "2")
  ensure
    SlowTotalsComponent.render_delay_ms = 0
  end

  it "have_reactive_value / have_reactive_text re-resolve by id, immune to a compute re-seed replacing the node" do
    # The compute-seed page paints its derived fields from the client on connect;
    # the value settles a beat after render (the exact StaleReference case #201
    # cites). The matchers re-query by id each poll, so they wait it out cleanly.
    visit "/compute_seed"

    expect(page).to have_reactive_value("total", "6")
    expect(page).to have_reactive_value("half", "3")
    expect(page).to have_reactive_text("seed-total-label", "6")

    # And the layer is idle: a client-only seed is synchronous, so nothing is ever
    # in flight — the marker never appears for a seed (compute-seed is not counted).
    wait_for_reactive
    expect(page).to have_no_css("html[data-reactive-active]")
  end
end
