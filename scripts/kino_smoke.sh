#!/usr/bin/env bash
# The report-only kino-smoke job (.github/workflows/main.yml, issue #364):
# serve the dummy app with kino in Ractor mode (ractor-rails-shim), GET /up,
# POST one reactive action, and write what happened, the first blocker
# included, to tmp/kino-smoke/. It cannot pass until Rails and Phlex run in a
# non-main Ractor, so it never fails: the job reads the report.
#
#   BUNDLE_GEMFILE=gemfiles/kino.gemfile scripts/kino_smoke.sh
set -uo pipefail

out=tmp/kino-smoke
port="${KINO_SMOKE_PORT:-39292}"
mkdir -p "$out"
export RAILS_ENV=test
# A file database: every worker Ractor opens its own connection, and an
# in-memory SQLite database would be empty in each.
export DATABASE_URL="sqlite3:$PWD/$out/dummy.sqlite3"

boot='require "./spec/dummy/config/environment"'
bundle exec ruby -e "$boot; ActiveRecord::Schema.verbose = false; load 'spec/dummy/db/schema.rb'" > "$out/schema.txt" 2>&1
bundle exec kino --check spec/dummy/config/kino.ru > "$out/check.txt" 2>&1
check=$?

bundle exec kino -m ractor -w 2 -p "$port" spec/dummy/config/kino.ru > "$out/server.log" 2>&1 &
server=$!
for _ in $(seq 1 90); do
  curl -s -o /dev/null "http://127.0.0.1:$port/up" && break
  sleep 1
done

up=$(curl -s -o "$out/up.body" -w '%{http_code}' "http://127.0.0.1:$port/up")
token=$(bundle exec ruby -e "$boot; print Phlex::Reactive.sign('c' => 'CounterComponent', 's' => { 'count' => 1 })" 2>/dev/null)
action=$(curl -s -o "$out/action.body" -w '%{http_code}' -H 'Content-Type: application/json' \
  -H 'Accept: text/vnd.turbo-stream.html' --data "{\"token\":\"$token\",\"act\":\"increment\",\"params\":{}}" \
  "http://127.0.0.1:$port/reactive/actions")
kill "$server" 2>/dev/null
wait "$server" 2>/dev/null

# kino's own lines: a crashed worker, or a request answered with its error.
blocker=$(grep -m1 -E '^kino\[[0-9]+\] .*(crashed|[0-9]{3} (GET|POST) .* · )' "$out/server.log" | cut -c1-400 || true)
{
  echo "kino --check: exit $check ($(grep -m1 '^check:' "$out/check.txt" || echo 'no verdict'))"
  echo "GET /up: HTTP $up"
  echo "POST /reactive/actions (CounterComponent#increment): HTTP $action"
  echo "first blocker: ${blocker:-none}"
  echo "kino's error lines (first 5):"
  grep -E '^kino\[[0-9]+\] .*(crashed|[0-9]{3} (GET|POST) .* · )' "$out/server.log" | cut -c1-400 | head -5
} | tee "$out/report.txt"
exit 0
