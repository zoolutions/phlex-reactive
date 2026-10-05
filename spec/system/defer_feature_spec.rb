# frozen_string_literal: true

require "system_helper"

# Issue #275: reply.defer, reactive_lazy and reactive_lazy(on:/cache:) live in a
# FEATURE MODULE the client imports only when something on the page needs it.
# These examples pin when that is, and that nothing is lost on the way:
#
#   - a page with no lazy root and no deferred reply never fetches the module;
#   - a page with a lazy root fetches it once;
#   - a `reactive:defer` stream — the first deferred reply on a page that had
#     no reason to load the module — is not lost: the module loads, then the
#     stream is applied;
#   - a stream that INTRODUCES a lazy shell (what a broadcast does) is rendered
#     as it is, and the new root's own connect loads the module.
#
# (What a lazy shell does once the module is there is the business of
# lazy_mount_spec, lazy_on_spec, lazy_cache_spec and defer_spec.)
RSpec.describe "The defer feature module (issue #275)", type: :system do
  around do
    SlowTotalsComponent.render_delay_ms = 100
    it.run
  ensure
    SlowTotalsComponent.render_delay_ms = 0
  end

  def defer_fetches
    page.evaluate_script(<<~JS)
      performance.getEntriesByType("resource").filter((e) => e.name.includes("/features/defer.js")).length
    JS
  end

  it "is not fetched by a page with no lazy root and no deferred reply" do
    visit "/counter"
    find("[data-testid='inc']").click
    expect(page).to have_css("[data-testid='count']", text: "1")

    expect(defer_fetches).to eq(0)
  end

  it "is fetched once by a page with a lazy root" do
    visit "/lazy_stats"

    expect(page).to have_css("[data-testid='stats-value']", text: "stats:week")
    expect(defer_fetches).to eq(1)
  end

  it "is fetched by the first deferred REPLY on a page that had not loaded it, and the reply is not lost" do
    visit "/defer"
    expect(page).to have_css("[data-testid='totals-value']", text: "0")
    expect(defer_fetches).to eq(0)

    find("[data-testid='defer-bump']").click

    # The reply carried a reactive:defer stream; the module was not there yet.
    expect(page).to have_css("[data-testid='defer-count']", text: "1")
    expect(page).to have_css("[data-testid='totals-value']", text: "2")
    expect(page).to have_no_css("#slow-totals[data-reactive-defer-pending]")
    expect(defer_fetches).to eq(1)
    expect(page).to have_reactive_requests(1, kind: :defer)
  end

  it "loads for a lazy shell that a STREAM brings onto a page that had none (a broadcast)" do
    visit "/counter"
    expect(page).to have_css("#counter")
    expect(defer_fetches).to eq(0)

    # What a broadcast delivers: a turbo-stream whose template is a lazy shell.
    # The shell's markup is taken from the page that renders it.
    page.execute_script(<<~JS)
      fetch("/lazy_stats").then((response) => response.text()).then((html) => {
        const shell = new DOMParser().parseFromString(html, "text/html").getElementById("lazy-stats")
        window.__shellPending = shell.getAttribute("data-reactive-defer-pending")
        Turbo.renderStreamMessage(
          `<turbo-stream action="append" targets="body"><template>${shell.outerHTML}</template></turbo-stream>`
        )
      })
    JS

    expect(page).to have_css("[data-testid='stats-value']", text: "stats:week")
    expect(page).to have_no_css("#lazy-stats[data-reactive-defer-pending]")
    expect(page.evaluate_script("window.__shellPending")).to eq("true")
    expect(defer_fetches).to eq(1)
    # The page's first root still works.
    find("[data-testid='inc']").click
    expect(page).to have_css("[data-testid='count']", text: "1")
  end
end
