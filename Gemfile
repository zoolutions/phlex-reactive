# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "rake", "~> 13.0"

group :development do
  gem "rubocop", "~> 1.80", require: false
  gem "rubocop-capybara", "~> 3.0", require: false
  gem "rubocop-performance", "~> 1.26", require: false
  gem "rubocop-rake", "~> 0.7", require: false
  gem "rubocop-rspec", "~> 3.0", require: false
  gem "rubocop-thread_safety", "~> 0.8", require: false
end

group :test do
  gem "conformance-kit", "~> 0.5", require: false # concurrency conformance gates (zoolutions/phlex-reactive#363)
  gem "rspec", "~> 3.0"
  gem "rspec-rails", ">= 7.0", "< 9"

  # System tests
  gem "capybara", require: false
  gem "capybara-playwright-driver", require: false
  # The Ruby client MUST track the npm playwright version pinned in bun.lock
  # (currently 1.64.1). Gemfile.lock is committed, but keep the pin anyway: an
  # unpinned client drifts to a newer protocol than the installed driver speaks
  # on the next `bundle update` (symptom: "timeout: expected float, got
  # undefined" on every visit). Bump this pin and bun.lock's playwright together.
  gem "playwright-ruby-client", "~> 1.64.0", require: false
  gem "puma", require: false
  # Falcon is the real-server fallback for the browser suite (CAPYBARA_SERVER=falcon)
  # — an async, production-grade alternative to Puma. No webrick (not a real server).
  gem "falcon", require: false
end

group :development, :test do
  # Performance measurement. The micro-benches (benchmark/micro/*) isolate the hot
  # methods (render, reactive_token, param coercion) with benchmark-ips for
  # throughput and memory_profiler for allocations. The request-cycle bench
  # (benchmark/request/*) drives the dummy app through derailed_benchmarks for
  # end-to-end latency + memory. See docs/performance.md and `rake -T bench`.
  gem "benchmark-ips", "~> 2.13", require: false
  gem "derailed_benchmarks", "~> 2.1", require: false
  gem "memory_profiler", "~> 1.0", require: false
  gem "stackprof", "~> 0.2", require: false # derailed_benchmarks profiling backend

  # The RBS signatures in sig/ (zoolutions/phlex-reactive#364): `rbs -I sig
  # validate` in the Lint job, and spec/phlex/rbs_spec.rb's reflection diff.
  gem "rbs", require: false

  gem "actioncable", ">= 7.1", "< 9.0"
  gem "activejob", ">= 7.1", "< 9.0"
  gem "activerecord", ">= 7.1", "< 9.0"
  # ActiveStorage backs the file/multipart upload fixture (issue #34). Dev/test
  # only — phlex-reactive itself doesn't depend on it; the dummy app uses it to
  # attach an uploaded file from a reactive action.
  gem "activestorage", ">= 7.1", "< 9.0"
  gem "sqlite3", ">= 1.4"

  # pgbus is NOT a runtime dependency (it stays out of the gemspec — broadcasts
  # route through Turbo::StreamsChannel, which pgbus patches, so phlex-reactive
  # works on Action Cable OR pgbus). We pull it in here ONLY to develop and test
  # against pgbus's reactive Streams primitives (exclude:/broadcast_render/
  # auto-presence/typed-events/coalescing/msg_id) plus the exclude:/visible_to:/
  # event: forwarding through the Turbo broadcast helpers — both shipped in
  # pgbus 0.9.4. phlex-reactive 0.2.0's actor-echo suppression needs them.
  #
  # 0.9.4 is the CAPABILITY floor (Streams primitives). The reply.defer PUSH
  # lane (issue #165) additionally wants pgbus >= 0.9.10 for the age-based
  # orphan-stream sweep that reclaims its durable one-shot queues; on older
  # pgbus those queues leak (the docs steer to defer_transport = :fetch). We
  # don't raise the floor for that — the push-lane queue lifecycle is an
  # operational (Dispatcher) concern, not a code dependency.
  #
  # Presence (issue #358) needs per-connection seats, pgbus:connected after the
  # join, the close watcher and streams_authorize (zoolutions/pgbus#516, #520,
  # #523, #524; 0.18.1 adds the worker read-ahead fix #526), and the browser
  # suite exercises it. The DEV floor is 0.20.1 (issue #427): it runs presence
  # SQL under the adapter's lock (zoolutions/pgbus#566), so the seat sweep can
  # no longer share the transactional tests' pinned connection with a request
  # and wedge the dummy server.
  # An app without presence components still works on any pgbus with the
  # Streams primitives (the gem capability-detects at runtime).
  #
  # For fast local iteration against your own checkout, set PGBUS_PATH:
  #   PGBUS_PATH=~/Code/mhenrixon/pgbus bundle install
  #
  # pgbus requires Ruby >= 3.3 — satisfied by phlex-reactive's 3.4 floor.
  if (pgbus_path = ENV.fetch("PGBUS_PATH", nil))
    gem "pgbus", path: pgbus_path, require: false
  else
    gem "pgbus", ">= 0.20.1", require: false
  end
  gem "pg", "~> 1.5", require: false # pgbus needs PostgreSQL

  # The read-only diagnostic MCP server (issue #168) is OPTIONAL and lazy — it is
  # NOT a gemspec runtime dependency (Phlex::Reactive::MCP.load! requires it on
  # demand with a helpful message when missing, the pgbus pattern). Here only so
  # the mcp_spec and `bin/rails phlex_reactive:mcp` can exercise it; a host app
  # adds `gem "mcp"` itself when it wants the server.
  gem "mcp", require: false
end
