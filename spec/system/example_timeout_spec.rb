# frozen_string_literal: true

require "system_helper"

# Issue #320: a dummy server that stops answering must FAIL the example within
# a bound, naming the bound — not hang the browser suite until CI's 6-hour kill.
# spec/system/support/example_timeout.rb wraps every system example in a
# watchdog; these examples prove it under whichever server CAPYBARA_SERVER picks
# (Puma and Falcon both run this file in CI).
#
# They must not wedge the shared server for the examples after them: /stall
# sleeps a BOUNDED few seconds (no DB, no lock), so the request finishes on its
# own and Capybara's post-example reset waits for it.
RSpec.describe "System example timeout (issue #320)", type: :system do
  it "seconds_for reads per-example metadata first, then SYSTEM_EXAMPLE_TIMEOUT, then the default" do
    expect(SystemExampleTimeout.seconds_for({ timeout: 7 })).to eq(7.0)

    original = ENV.fetch("SYSTEM_EXAMPLE_TIMEOUT", nil)
    begin
      ENV["SYSTEM_EXAMPLE_TIMEOUT"] = "42"
      expect(SystemExampleTimeout.seconds_for({})).to eq(42.0)
      ENV.delete("SYSTEM_EXAMPLE_TIMEOUT")
      expect(SystemExampleTimeout.seconds_for({})).to eq(SystemExampleTimeout::DEFAULT_SECONDS)
    ensure
      ENV["SYSTEM_EXAMPLE_TIMEOUT"] = original
    end
  end

  it "fails an example that outlives its metadata bound, naming the bound", timeout: 0.5 do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    expect { sleep 10 }.to raise_error(SystemExampleTimeout::Exceeded, /exceeded 0\.5s .*is the server wedged\?/)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 3
  end

  it "cuts off a visit whose request the server never answers within the bound" do
    visit "/nav_probe" # warm the browser so only the stalled request is timed
    expect(page).to have_css("[data-testid='nav-probe']")

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect do
      SystemExampleTimeout.guard(2) { visit "/stall?seconds=8" }
    end.to raise_error(SystemExampleTimeout::Exceeded, /exceeded 2s .*is the server wedged\?/)

    # Cut off at the bound, well before the server would have answered (8 s).
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be_between(1.5, 5)
  end
end
