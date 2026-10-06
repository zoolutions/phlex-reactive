# frozen_string_literal: true

# Issue #320: a wedged dummy server must FAIL the browser suite, not hang it.
# Capybara's default_max_wait_time bounds matchers only, and Playwright's own
# timeouts bound browser calls only — when the server wedges (e.g. a request
# fiber leaves the pinned connection's lock held, see
# falcon_fiber_isolation_spec.rb) the TEST thread blocks on that lock in the
# example or its transactional teardown, which nothing bounds. CI then sat 3.5 h
# per cell until it was cancelled.
#
# So every system example runs under a watchdog:
#   1. after `seconds` it raises Exceeded into the example thread, naming the
#      bound ("is the server wedged?"); RSpec records it as the failure.
#   2. if the example STILL hasn't finished GRACE_SECONDS later (its teardown is
#      stuck behind the same lock), it prints the diagnosis and exits the
#      process — the run is unrecoverable, so fail now, not at CI's 6 h kill.
#   3. a timed-out example stops the rest of the run (RSpec.world.wants_to_quit):
#      the next example would hit the same wedged server and wait out its own
#      bound, one by one.
#
# The bound: `it "...", timeout: 120 do` per example, else SYSTEM_EXAMPLE_TIMEOUT
# (seconds), else DEFAULT_SECONDS. 0 disables it (e.g. while sitting in a
# debugger).
module SystemExampleTimeout
  # Not a StandardError: a `rescue => e` in driver or app code must not swallow it.
  class Exceeded < Exception; end # rubocop:disable Lint/InheritException

  DEFAULT_SECONDS = 90.0
  GRACE_SECONDS = Float(ENV.fetch("SYSTEM_EXAMPLE_TIMEOUT_GRACE", 30))

  def self.seconds_for(metadata)
    Float(metadata.fetch(:timeout) { ENV.fetch("SYSTEM_EXAMPLE_TIMEOUT", DEFAULT_SECONDS) })
  end

  def self.guard(seconds, label: nil)
    return yield unless seconds.positive?

    done = Thread::Queue.new
    watchdog = start_watchdog(Thread.current, seconds, label, done)
    begin
      yield
    ensure
      done << true
      watchdog.join
    end
  end

  def self.start_watchdog(target, seconds, label, done)
    Thread.new do
      next if done.pop(timeout: seconds)

      target.raise(Exceeded, "#{label || "system example"} exceeded #{format_seconds(seconds)}s " \
                             "(SYSTEM_EXAMPLE_TIMEOUT / `timeout:` metadata) — is the server wedged?")
      next if done.pop(timeout: GRACE_SECONDS)

      abort_run(seconds, label)
    end
  end

  def self.abort_run(seconds, label)
    $stdout.flush
    warn "\n[system timeout] #{label || "a system example"} was still stuck #{format_seconds(GRACE_SECONDS)}s " \
         "after its #{format_seconds(seconds)}s bound fired (its teardown is blocked too) — " \
         "the dummy server is wedged. Aborting the run."
    $stderr.flush
    exit!(1)
  end

  # The body may fail first (e.g. a Playwright TimeoutError) and the bound fire
  # in teardown: RSpec then reports a MultipleExceptionError wrapping both.
  def self.timed_out?(exception)
    errors = exception.respond_to?(:all_exceptions) ? exception.all_exceptions : [exception]
    errors.any?(Exceeded)
  end

  def self.format_seconds(seconds) = seconds == seconds.to_i ? seconds.to_i.to_s : seconds.to_s
end

RSpec.configure do
  it.around(:each, type: :system) do
    example = it
    SystemExampleTimeout.guard(SystemExampleTimeout.seconds_for(example.metadata), label: example.location) do
      example.run
    end

    if SystemExampleTimeout.timed_out?(example.exception)
      warn "\n[system timeout] #{example.location} timed out — skipping the rest of the run " \
           "(a wedged server would make every later example wait out its own bound)."
      RSpec.world.wants_to_quit = true
    end
  end
end
