# frozen_string_literal: true

require "system_helper"

# Falcon runs each request as a FIBER on one server thread, and transactional
# system tests PIN one connection that the test and the server share, guarded
# by a lock keyed on ActiveSupport::IsolatedExecutionState.context. Under the
# default :thread isolation that lock is a ThreadMonitor: two request fibers on
# the same thread look like one owner, both enter the pinned connection's
# critical section, and whichever leaves last unlocks a mutex the other holds
# (ThreadError) — after which every later request blocks forever and the
# browser suite hangs instead of failing (issue #303's two-roots fixture was the
# first page to make two action requests overlap). The dummy app therefore sets
# `config.active_support.isolation_level = :fiber` when it serves under Falcon;
# this example reproduces the overlap without a browser (a yield inside the
# adapter lock, exactly where the SQL log hook runs) and proves the pinned lock
# serializes fibers. It runs only in the Falcon configuration — under Puma the
# default :thread isolation is the one under test and is correct there.
RSpec.describe "Falcon: request fibers share the pinned test connection safely" do
  before do
    skip "runs with CAPYBARA_SERVER=falcon (fiber-per-request)" unless ENV["CAPYBARA_SERVER"] == "falcon"
    require "async"
  end

  it "serializes two fibers inside the pinned connection's lock, with no ThreadError" do
    # The lock every statement and transaction of the pinned connection runs
    # under (AbstractAdapter#with_raw_connection → @lock.synchronize). The sleep
    # yields the fiber mid-section, as a nested statement's log write does on a
    # busy host; with a thread-keyed lock the second fiber walks straight in.
    lock = ActiveRecord::Base.lease_connection.lock
    inside = 0
    overlaps = 0
    errors = []

    Async do
      # Inside a running reactor, Async { } starts a child task: the two fibers.
      fibers = Array.new(2) do
        Async do
          lock.synchronize do
            inside += 1
            overlaps += 1 if inside > 1
            sleep 0.001
            inside -= 1
          end
        rescue StandardError => e
          errors << e
        end
      end
      fibers.each(&:wait)
    end

    expect(errors).to be_empty
    expect(overlaps).to eq(0)
    # The lock is still usable afterwards: a wedged monitor would block here.
    expect(Todo.count).to eq(0)
  end

  it "runs the dummy app with fiber isolation, so the pinned connection's lock is fiber-keyed" do
    expect(ActiveSupport::IsolatedExecutionState.isolation_level).to eq(:fiber)
  end
end
