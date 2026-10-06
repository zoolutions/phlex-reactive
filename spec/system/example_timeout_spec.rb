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

  it "rejects a negative or NaN bound instead of silently disabling the watchdog (only 0 opts out)" do
    expect { SystemExampleTimeout.guard(-1) { :ran } }.to raise_error(ArgumentError, /finite and non-negative/)
    expect { SystemExampleTimeout.guard(Float::NAN) { :ran } }.to raise_error(ArgumentError, /finite and non-negative/)
    expect(SystemExampleTimeout.guard(0) { :ran }).to eq(:ran)
  end

  # 3 s, not less: the bound also covers the before hooks (fixtures, a first DB
  # checkout on a pgbus cell), and firing there would end the whole run.
  it "fails an example that outlives its metadata bound, naming the bound", timeout: 3 do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    expect { sleep 20 }.to raise_error(SystemExampleTimeout::Exceeded, /exceeded 3s .*is the server wedged\?/)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 6
  end

  it "recognises a timeout wrapped with an earlier failure (body failed, teardown timed out)" do
    wrapped = RSpec::Core::MultipleExceptionError.new(RuntimeError.new("body"), SystemExampleTimeout::Exceeded.new)

    expect(SystemExampleTimeout.timed_out?(wrapped)).to be(true)
    expect(SystemExampleTimeout.timed_out?(SystemExampleTimeout::Exceeded.new)).to be(true)
    expect(SystemExampleTimeout.timed_out?(RuntimeError.new)).to be(false)
    expect(SystemExampleTimeout.timed_out?(nil)).to be(false)
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
