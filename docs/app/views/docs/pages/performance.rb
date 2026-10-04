# frozen_string_literal: true

module Views
  module Docs
    module Pages
      class Performance < DocsUI::Page
        title 'Performance'
        eyebrow 'Guide'
        description 'How phlex-reactive keeps the component re-render, identity-token signing, param coercion, and broadcast fan-out fast, plus how to benchmark them yourself'

        def lead
          'phlex-reactive aims to be fast in the places that run on every interaction — the re-render, ' \
            'the token signing, the param coercion, and the client hot path.'
        end

        def content
          overview
          hot_paths
          observability
          measuring
          before_change
          numbers
          verify_and_sign
          deferred_segments
          client_numbers
          loading_the_client
          dormant_roots
          ci
          every_change
          adding_a_benchmark
        end

        private

        def overview
          DocsUI::Section('What we optimize') do
            DocsUI::Prose() do
              p do
                plain 'phlex-reactive aims to be fast in the places that run on every interaction: the '
                plain 'component re-render, the identity-token signing, the param coercion, and the client '
                plain 'request hot path. This page documents how those paths are kept fast, how to measure '
                plain 'them yourself, and how performance is part of every change.'
              end
              p do
                plain 'The honest summary: the re-render is the part we control and the part we optimized '
                plain 'hardest, but a full HTTP action is dominated by the Rails middleware stack and (for '
                plain 'record-backed components) the database — so the render wins matter most for '
                strong { 'broadcasts' }
                plain ', which have no HTTP overhead to amortize against. To be precise about the fan-out: '
                plain 'a '
                code { 'broadcast_to' }
                plain ' call renders the component '
                strong { 'once' }
                plain ' and hands the finished HTML to the transport, so every subscriber of that stream '
                plain 'shares one payload (the per-subscriber cost is transport-side, not a render). The '
                plain 'render cost multiplies per '
                strong { 'call' }
                plain ': pushing one change to K different stream keys with a hand-written loop over '
                code { 'broadcast_to' }
                plain ' is K builds + K renders + K token signings of byte-identical HTML. For that same-payload, '
                plain 'many-key fan-out, passing '
                code { 'each:' }
                plain ' (issue #119) renders '
                strong { 'once' }
                plain ' and loops only the cheap channel call — measured at ~9.5× throughput and ~8× fewer '
                plain 'allocations at K=10 (see the fan-out table below). Per-viewer content ('
                code { 'visible_to:' }
                plain '-style rendering, DIFFERENT HTML per viewer) stays the irreducible render-per-viewer case. '
                plain 'Measure before you optimize; the harness below exists so you never have to guess.'
              end
            end
          end
        end

        def hot_paths
          DocsUI::Section('The hot paths') do
            DocsUI::Prose() do
              ul do
                li do
                  code { 'render_component' }
                  plain ' — every action re-render and every broadcast render. Renders through '
                  plain "phlex-rails' lightweight "
                  code { '#render_in' }
                  plain ' against a memoized off-request view context, instead of '
                  code { 'ActionController.renderer.render' }
                  plain '. ~1.9× faster, ~half the allocations, byte-identical HTML.'
                end
                li do
                  plain 'view context / '
                  code { 'TagBuilder' }
                  plain ' — built once per thread per component class and reused. The context is '
                  plain 'request-bound ('
                  code { 'Phlex::Reactive.request_bound_view_context' }
                  plain ') so request-dependent helpers — '
                  code { 'form_authenticity_token' }
                  plain ', '
                  code { 'protect_against_forgery?' }
                  plain ', host-aware '
                  code { '*_url' }
                  plain ' — keep working during a re-render/broadcast. The request setup happens only on '
                  plain 'the build, not per render, and it is reset on Rails code reload.'
                end
                li do
                  code { 'reactive_token' }
                  plain ' — every render (it is in '
                  code { 'reactive_attrs' }
                  plain '). Ivar symbols ('
                  code { ':@count' }
                  plain ') and state string-keys are precomputed per class, so signing no longer allocates '
                  plain 'a Symbol/String per state key. The HMAC itself dominates and is unavoidable.'
                end
                li do
                  code { 'on(:action)' }
                  plain ' — every trigger rendered. The no-params case (the common one) skips re-serializing '
                  code { '{}' }
                  plain ' to JSON.'
                end
                li do
                  code { 'coerce_params' }
                  plain ' — every action with a param schema. Three wins on this path: the schema is '
                  strong { 'compiled once at declaration' }
                  plain ' ('
                  code { 'ParamSchema.compile' }
                  plain ', from '
                  code { 'action :name, params:' }
                  plain '), so a click never re-walks or re-validates it; the per-request work is '
                  strong { 'bracket-key expansion' }
                  plain ' of Rails-form field names ('
                  code { 'invoice[items][0][qty]' }
                  plain ' → nested hash) using a frozen '
                  code { 'BRACKET_SEGMENT' }
                  plain ' regex (no per-key recompile); and each scalar dispatches through the '
                  strong { 'param-type registry' }
                  plain ', which is frozen after boot ('
                  code { 'freeze_param_types!' }
                  plain ') so lookups hit a stable hash with no allocation.'
                end
                li do
                  plain 'client meta lookups — every dispatch. The page-stable action path is resolved once '
                  plain 'per controller; CSRF + pgbus connection id stay live (they can rotate).'
                end
              end
            end
          end
        end

        def observability
          DocsUI::Section('Observability (ActiveSupport::Notifications)') do
            DocsUI::Callout(:tip) do
              plain 'Turnkey APM adapters ('
              code { 'Phlex::Reactive.apm = :appsignal' }
              plain '), error reporting, and the full event reference now live on the '
              a(href: '/docs/observability') { 'Observability & APM' }
              plain ' page. This section keeps the performance-relevant note: an unsubscribed '
              code { 'instrument' }
              plain ' is cheap, so the hot paths carry it unconditionally.'
            end
            DocsUI::Prose() do
              p do
                plain 'The hot paths emit '
                code { 'ActiveSupport::Notifications' }
                plain ' events so an APM (AppSignal, Datadog, Skylight) sees reactive traffic at the '
                strong { 'component level' }
                plain ' — which component/action a slow request was, how long a render took, and broadcast '
                plain 'fan-out. Three events, all in the '
                code { 'phlex_reactive' }
                plain ' namespace:'
              end
              ul do
                li do
                  code { 'action.phlex_reactive' }
                  plain ' — one per request. Payload: '
                  code { 'component' }
                  plain ', '
                  code { 'action' }
                  plain ', '
                  code { 'outcome' }
                  plain ' ('
                  code { 'ok' }
                  plain '/'
                  code { 'denied_undeclared' }
                  plain '/'
                  code { 'invalid_token' }
                  plain '/'
                  code { 'not_found' }
                  plain '/'
                  code { 'unauthorized' }
                  plain '/'
                  code { 'unverified' }
                  plain ').'
                end
                li do
                  code { 'render.phlex_reactive' }
                  plain ' — around each component render. Payload: '
                  code { 'component' }
                  plain ', '
                  code { 'bytesize' }
                  plain '.'
                end
                li do
                  code { 'broadcast.phlex_reactive' }
                  plain ' — around each '
                  code { 'broadcast_to' }
                  plain ' call (fires on Action Cable AND pgbus). Payload: '
                  code { 'component' }
                  plain ', '
                  code { 'stream_action' }
                  plain ', '
                  code { 'streamables' }
                  plain ' (the key count).'
                end
                li do
                  code { 'defer.phlex_reactive' }
                  plain ' — one per deferred render (the '
                  code { 'reply.defer' }
                  plain ' endpoint). Payload: '
                  code { 'component' }
                  plain ', '
                  code { 'outcome' }
                  plain ' ('
                  code { 'ok' }
                  plain '/'
                  code { 'no_content' }
                  plain '/'
                  code { 'invalid_token' }
                  plain '/'
                  code { 'not_found' }
                  plain '/'
                  code { 'unauthorized' }
                  plain ').'
                end
              end
              p do
                strong { 'Payloads carry names, the outcome, and sizes only' }
                plain ' — never the token, the params, or component state, so an event can never leak a '
                plain 'secret. An '
                code { 'invalid_token' }
                plain ' event has no trusted component name (the token did not verify), so it is omitted.'
              end
              p { plain 'Subscribe from an initializer exactly as you would for any Rails event:' }
            end
            DocsUI::Code(<<~'RUBY', lexer: :ruby, filename: 'config/initializers/phlex_reactive_apm.rb')
              ActiveSupport::Notifications.subscribe('action.phlex_reactive') do |*args|
                event = ActiveSupport::Notifications::Event.new(*args)
                # event.payload => { component:, action:, outcome: }
                # event.duration => ms
                MyAPM.record("reactive.#{event.payload[:outcome]}", event.duration,
                  component: event.payload[:component], action: event.payload[:action])
              end
            RUBY
            DocsUI::Prose() do
              p do
                plain 'To watch reactive traffic in your own log without an APM, flip on the bundled '
                code { 'LogSubscriber' }
                plain ' (default off). It logs one compact line per event at DEBUG:'
              end
            end
            DocsUI::Code(<<~RUBY, lexer: :ruby, filename: 'config/initializers/phlex_reactive.rb')
              Phlex::Reactive.log_events = true
              # [reactive] Counter#increment ok (3.1ms)
              # [reactive] Counter#drop_table denied_undeclared (0.2ms)
              # [reactive] render Counter 512B (0.9ms)
              # [reactive] broadcast replace Counter →2 (1.4ms)
              # [reactive] defer SlowTotals ok (18.2ms)
            RUBY
            DocsUI::Callout(:tip) do
              plain 'The events fire whether or not you enable the LogSubscriber — the flag only controls the '
              plain "gem's own log lines. An unsubscribed instrument is cheap (a few objects per call, zero "
              plain 'retained), so the hot paths carry it unconditionally.'
            end
            DocsUI::Prose() do
              h3 { 'Client debug mode (devtools-lite)' }
              p do
                plain 'The '
                code { 'LogSubscriber' }
                plain ' above is the '
                strong { 'server' }
                plain ' lens. The '
                strong { 'client' }
                plain ' lens is '
                code { 'console.error' }
                plain ' on a failure plus the lifecycle events — but on the '
                em { 'successful-but-wrong' }
                plain ' path (which streams arrived? did a token refresh come?) there was nothing to see. '
                code { 'Phlex::Reactive.debug' }
                plain ' fills that gap: turn it on and every reactive root carries '
                code { 'data-reactive-debug="true"' }
                plain ', so the generic controller '
                code { 'console.group' }
                plain 's every dispatch in the browser.'
              end
            end
            DocsUI::Code(<<~RUBY, lexer: :ruby, filename: 'config/initializers/phlex_reactive.rb')
              Phlex::Reactive.debug = Rails.env.development?
            RUBY
            DocsUI::Code(<<~TEXT, lexer: :text, filename: 'browser console')
              ▼ reactive #todo_42 rename → 200 (48ms)
                  params: [title] + collected: [title]
                  encoding: json
                  streams: replace → #todo_42
                  token: refreshed ✓
            TEXT
            DocsUI::Callout(:tip) do
              strong { 'Names and outcomes only.' }
              plain ' The trace shows the param and collected-field '
              strong { 'names' }
              plain ' (never their values — they may be sensitive), the encoding, the status, the response '
              plain 'stream actions + targets, whether a token refresh arrived ('
              strong { 'never the token value' }
              plain '), and the round-trip ms. Off (the default) it does nothing — one attribute check per '
              plain 'dispatch, no string building — so leave it gated on '
              code { 'Rails.env.development?' }
              plain '.'
            end
            DocsUI::Prose() do
              h3 { 'Why a param silently vanished (verbose_errors)' }
              p do
                plain 'The '
                code { 'LogSubscriber' }
                plain ' tells you a request happened; '
                code { 'Phlex::Reactive.verbose_errors' }
                plain ' tells you '
                em { 'why an action got its keyword default instead of your value' }
                plain ' — the drop-don\'t-fabricate contract means a param that fails coercion or isn\'t in '
                plain 'the schema is dropped '
                strong { 'without an error' }
                plain '. When on, param coercion warn-logs every dropped key with its '
                strong { 'bracketed path' }
                plain ' and reason ('
                code { 'undeclared' }
                plain ' — not in the schema, the '
                code { 'invoice[date]' }
                plain '-vs-flat-schema footgun; or '
                code { 'uncoercible' }
                plain ' — present but wouldn\'t cast), and an endpoint failure carries a plain-text '
                plain 'diagnostic body. It defaults to '
                code { 'Rails.env.local?' }
                plain ' (development '
                strong { 'and' }
                plain ' test), so production stays opaque unless you opt in.'
              end
            end
            DocsUI::Code(<<~RUBY, lexer: :ruby, filename: 'config/initializers/phlex_reactive.rb')
              Phlex::Reactive.verbose_errors = Rails.env.local?  # the default; set = false to silence
              # [phlex-reactive] dropped param invoice[date] (undeclared)
              # [phlex-reactive] dropped param invoice_items_attributes[0][qty] (uncoercible)
            RUBY
            DocsUI::Callout(:note) do
              plain 'The diagnostics collector is a '
              strong { 'nil check on the hot path' }
              plain ' — with the flag off, '
              code { 'coerce' }
              plain ' passes a '
              code { 'nil' }
              plain ' collector and every diagnostic branch early-returns, so the drop-path stays zero-cost '
              plain 'in production. The bracketed-path logging only runs when you flip the flag on.'
            end
          end
        end

        def measuring
          DocsUI::Section('Measuring') do
            DocsUI::Prose() do
              p { plain 'Everything is driven from rake:' }
            end
            DocsUI::Code(<<~SHELL, lexer: :shell)
              rake bench           # the micro-benchmark suite (alias for bench:micro)
              rake bench:micro     # render, reactive_token, verify/sign, coerce_params — isolates each method
              rake bench:request   # end-to-end POST /reactive/actions through the full Rack stack
              rake bench:client    # the client dispatch hot path (extractToken, collectFields, recompute) via bun
              rake bench:one[render]  # a single micro-bench by name
            SHELL
            DocsUI::Prose() do
              ul do
                li do
                  strong { 'Micro-benches' }
                  plain ' ('
                  code { 'benchmark/micro/*.rb' }
                  plain ') isolate one method with benchmark-ips (throughput) and memory_profiler '
                  plain '(allocations). They boot the dummy app so they exercise the real render path.'
                end
                li do
                  strong { 'The request bench' }
                  plain ' ('
                  code { 'benchmark/request/derailed.rb' }
                  plain ") drives the dummy app's full Rack stack (middleware → router → controller → token "
                  plain 'verify → action → re-render → turbo-stream) via '
                  code { 'Rack::MockRequest' }
                  plain ' — the same call-the-app primitive derailed_benchmarks uses — so the numbers '
                  plain 'reflect production action latency.'
                end
                li do
                  strong { 'The client bench' }
                  plain ' ('
                  code { 'benchmark/client/' }
                  plain ', run with '
                  code { 'bun' }
                  plain ') covers the JS dispatch hot path — '
                  code { '#extractToken' }
                  plain ', '
                  code { '#collectFields' }
                  plain ', '
                  code { 'recompute' }
                  plain ' — with '
                  a(href: 'https://github.com/evanwashere/mitata') { plain 'mitata' }
                  plain ' + '
                  a(href: 'https://github.com/capricorn86/happy-dom') { plain 'happy-dom' }
                  plain ". It drives the controller's PUBLIC surface only (no test-only exports on the "
                  plain 'shipped controller), so nothing under '
                  code { 'app/javascript/' }
                  plain ' changes. Read the framing below before comparing numbers across machines.'
                end
              end
              h3 { 'Reading the output' }
              p do
                plain 'benchmark-ips reports '
                strong { 'i/s' }
                plain ' (iterations per second — higher is better) and '
                strong { 'μs/i' }
                plain ' (microseconds per call — lower is better). memory_profiler reports '
                strong { 'objects/bytes allocated' }
                plain ' (transient GC pressure) and '
                strong { 'retained' }
                plain ' (objects that survive — a steady climb here is a leak). For a re-render, retained '
                plain 'should be 0; a non-zero retained count per render is the smell the view-context '
                plain 'memoization fixed.'
              end
            end
          end
        end

        def before_change
          DocsUI::Section('Measure BEFORE you change') do
            DocsUI::Prose() do
              p do
                plain 'The first rule: capture the baseline before touching code, or you cannot claim a '
                plain 'delta. The cleanest way for a gem is an isolated worktree so '
                code { 'main' }
                plain ' and your branch run the same script on the same machine:'
              end
            end
            DocsUI::Code(<<~SHELL, lexer: :shell)
              git worktree add --detach /tmp/baseline main
              # Copy the harness AND the Rakefile/Gemfile so `rake bench` exists in the
              # pristine tree (main predates the bench task).
              cp -r benchmark /tmp/baseline/ && cp Gemfile Rakefile /tmp/baseline/
              (cd /tmp/baseline && bundle install && RAILS_ENV=test bundle exec rake bench:micro) > /tmp/before.txt
              RAILS_ENV=test bundle exec rake bench:micro > /tmp/after.txt   # your branch
              diff /tmp/before.txt /tmp/after.txt
              git worktree remove --force /tmp/baseline
            SHELL
            DocsUI::Prose() do
              p do
                plain 'If the branch added a bench that calls a method not on '
                code { 'main' }
                plain ' (e.g. a new '
                code { 'reset_*!' }
                plain '), write a baseline-safe script that only calls methods present on '
                code { 'main' }
                plain ' and run that in both trees.'
              end
            end
            DocsUI::Callout(:note) do
              plain 'There is no committed baseline file — shared CI runners are too noisy for a hard ' \
                    'regression gate — which is exactly why the before/after has to be a deliberate ' \
                    'same-machine measurement, not a comparison against a number from another box.'
            end
            DocsUI::Prose() do
              p do
                plain 'Toggling a single optimization in place (e.g. '
                code { 'PHLEX_REACTIVE_NO_CACHE=1 ruby benchmark/micro/render.rb' }
                plain ') is an even cleaner apples-to-apples for one change — it removes machine-to-machine '
                plain 'and worktree variance.'
              end
            end
          end
        end

        def numbers
          DocsUI::Section('Representative numbers') do
            DocsUI::Prose() do
              p do
                plain 'Measured on Ruby 3.4 +YJIT, Apple Silicon, the dummy app — the before column is '
                plain 'pristine '
                code { 'main' }
                plain ' run in an isolated worktree with the same script as the after column, so it is a '
                plain 'true same-machine before/after. '
                strong { 'Your absolute numbers will differ; the ratios are the point.' }
              end
              ul do
                li do
                  code { 'render_component' }
                  plain ' throughput: 6.99k i/s (143 μs) → 14.1k i/s (71 μs) — '
                  strong { '2.0× faster' }
                  plain '.'
                end
                li do
                  code { 'render_component' }
                  plain ' allocations: 212 obj → 99 obj — '
                  strong { '−53%' }
                  plain '.'
                end
                li do
                  code { 'to_stream_replace' }
                  plain ' throughput: 4.60k i/s (217 μs) → 8.00k i/s (125 μs) — '
                  strong { '1.7× faster' }
                  plain '.'
                end
                li do
                  code { 'to_stream_replace' }
                  plain ' allocations: 331 obj → 191 obj — '
                  strong { '−42%' }
                  plain '.'
                end
                li do
                  code { 'reactive_token' }
                  plain ' (state) allocations: 14 obj → 11 obj — −21%.'
                end
                li do
                  code { 'on(:action)' }
                  plain ' (no params) allocations: 6 obj → 5 obj — −17%.'
                end
              end
              h3 { 'Multi-key broadcast fan-out (issue #119)' }
              p do
                plain 'The '
                code { 'broadcast' }
                plain ' bench doubles the transport out to a no-op, so what is measured is the server-side '
                plain 'build + render + identity-HMAC cost a broadcast pays before the wire. Fanning one '
                plain 'component out to K=10 stream keys, a hand-written loop over '
                code { 'broadcast_to(key, replace:)' }
                plain ' vs '
                code { 'broadcast_to(each: keys, replace:)' }
                plain ':'
              end
              ul do
                li do
                  plain 'Throughput: 2.88k i/s (347 μs) → 27.3k i/s (37 μs) — '
                  strong { '9.5× faster' }
                  plain ' (and within ~4% of a single 1-key broadcast: K renders + K HMACs collapse to 1 + 1).'
                end
                li do
                  plain 'Allocations: 1250 obj / 186 KB → 151 obj / 22 KB — '
                  strong { '−88%' }
                  plain ' objects, 0 retained.'
                end
                li do
                  code { 'model_param_name' }
                  plain ' (the measure-first candidate): 815k i/s, 8 obj/call — immaterial next to the '
                  plain '~37 μs build, so it was measured and left alone (no memoization).'
                end
              end
              h3 { 'Full-stack request numbers' }
              p { plain 'No clean before/after — these are reference figures for production action shape:' }
              ul do
                li do
                  code { 'POST /reactive/actions' }
                  plain ' (state-backed): ~1.6k req/s (636 μs), 828 obj/req.'
                end
                li do
                  code { 'POST /reactive/actions' }
                  plain ' (record-backed, +DB): ~1.1k req/s (895 μs), 1316 obj/req.'
                end
                li do
                  code { 'coerce_params' }
                  plain ' (2-row nested form): ~37k i/s (27 μs), 218 obj/call.'
                end
              end
              h3 { 'What these tell you' }
              ul do
                li do
                  plain 'The render path got ~2× faster and halved its allocations — but at the full request '
                  plain 'level that delta is within noise, because routing + middleware + token verify + '
                  plain 'transaction dominate. Do not expect a render optimization to move request '
                  plain 'throughput; expect it to move broadcast-heavy code — one render per broadcast '
                  plain 'call, so K stream keys (or per-viewer rendering) = K renders with no HTTP — and '
                  plain 'to cut GC pressure under load.'
                end
                li do
                  plain 'Record-backed actions are ~1.4× slower than state-backed — that is the GlobalID '
                  plain 're-find + DB write, which is the security model working as designed (state lives in '
                  plain 'the database), not overhead to remove.'
                end
              end
            end
          end
        end

        def verify_and_sign
          DocsUI::Section('Verify & sign numbers') do
            DocsUI::Prose() do
              p do
                plain 'The two MessageVerifier HMAC paths run on every interaction: '
                code { 'Phlex::Reactive.verify' }
                plain ' before anything else on every request ('
                code { 'ActionsController#verified_payload' }
                plain ' is the first line — a garbage-token flood pays it too), and '
                code { 'Phlex::Reactive.sign' }
                plain ' once per rendered component ('
                code { 'reactive_token' }
                plain ' — so N times for an N-row reactive collection). '
                code { 'benchmark/micro/verify.rb' }
                plain ' isolates both. Ruby 3.4 +YJIT, Apple Silicon, the dummy app:'
              end
              h3 { 'verify — four cost classes' }
              ul do
                li do
                  strong { 'garbage' }
                  plain ' ('
                  code { '"x" * 64' }
                  plain ', the flood cost): ~1.2M i/s (0.8 μs), 4 obj/call. A malformed token bails at '
                  plain 'format parsing before the HMAC ever runs, so a bad-token flood is the '
                  em { 'cheapest' }
                  plain ' path — nothing to optimize.'
                end
                li do
                  strong { 'tampered' }
                  plain ' (valid shape, corrupted signature): ~203k i/s (4.9 μs), 9 obj/call — '
                  strong { '6× slower than garbage' }
                  plain '. A near-miss forgery pays the full constant-time HMAC compare of the whole '
                  plain 'digest; garbage never gets there. That gap is the security model working as '
                  plain 'designed (no early-exit oracle on the signature).'
                end
                li do
                  strong { 'valid, state-backed' }
                  plain ' ('
                  code { '{c, s}' }
                  plain '): ~136k i/s (7.4 μs), 20 obj/call.'
                end
                li do
                  strong { 'valid, record-backed' }
                  plain ' ('
                  code { '{c, gid}' }
                  plain '): ~147k i/s (6.8 μs), 20 obj/call. (The GlobalID re-find + DB load happens '
                  plain 'downstream, in the action — not in verify.)'
                end
              end
              h3 { 'sign — per component, and at collection scale' }
              ul do
                li do
                  code { 'sign' }
                  plain ' ×1 (state or record): ~155k i/s (6.5 μs), 12 obj/call.'
                end
                li do
                  code { 'sign' }
                  plain ' ×100 — '
                  strong { 'the collection cost' }
                  plain ' (rendering a 100-row reactive collection signs once per row): ~1.6k i/s '
                  plain '(610 μs), 1200 obj/call. It scales linearly, as expected — the HMAC is '
                  plain 'unavoidable and there is no shared work across rows to hoist.'
                end
              end
              h3 { 'Digest / serializer: measured, and the question is closed' }
              p do
                plain 'The default verifier uses whatever '
                code { 'Rails.application.message_verifier' }
                plain ' hands back — SHA1 with the JSON-with-Marshal-fallback serializer. The bench '
                plain 'compares that against explicitly-built verifiers on the same secret with SHA256 '
                plain 'and/or a strict JSON serializer, for both verify and sign. '
                strong { 'Every variant falls within measurement noise' }
                plain ' — the differences reorder run-to-run and benchmark-ips reports them as '
                em { '"difference falls within error"' }
                plain '. The HMAC over a ~120-byte payload is not where the time goes, and the '
                plain 'serializer choice does not move it either.'
              end
              DocsUI::Callout(:note) do
                plain 'Verdict: verify is not a bottleneck (a garbage flood is ~1.2M i/s, and even a ' \
                      'valid verify is ~7 μs against a full action that is ~600 μs), and no ' \
                      'digest/serializer configuration wins measurably — so phlex-reactive ships no ' \
                      'opt-in recipe and keeps the app default. If your own profile ever shows verify ' \
                      'as hot, the setter is there — '
                code { 'Phlex::Reactive.verifier = ActiveSupport::MessageVerifier.new(secret, digest: "SHA256")' }
                plain ' — but the measurement says you will not need it. The question is closed until ' \
                      'the numbers say otherwise.'
              end
            end
          end
        end

        def deferred_segments
          DocsUI::Section('Deferred segments (reply.defer) — a latency shape, not a throughput win') do
            DocsUI::Prose() do
              p do
                code { 'reply.defer' }
                plain ' (#165) moves an expensive reply segment OFF the actor\'s critical path. Be precise ' \
                      'about what that buys: the actor\'s reply latency improves by roughly the deferred ' \
                      'segment\'s render cost, while time-to-full-content gets slightly WORSE (one extra ' \
                      'hop). The cost moves; it never disappears. The request-level A/B spec ('
                code { 'spec/requests/deferred_latency_spec.rb' }
                plain ') pins exactly that: with a 120 ms segment, the sync reply pays ≥ 120 ms, the ' \
                      'deferred reply dodges it, and the deferred fetch pays it instead.'
              end
              p do
                plain 'The machinery itself stays off the hot paths — the same-machine, same-checkout ' \
                      'before/after against main held '
                code { 'to_stream_replace' }
                plain ' at 14.4k → 14.2k i/s (within ±3.7% noise) and the identity token at ' \
                      '199.9k → 196.7k i/s (state-backed), allocations byte-identical. Per deferred ' \
                      'segment the reply pays one purpose-scoped '
                code { 'sign_defer' }
                plain ' (~120k i/s) and the directive build (~11 μs, 0 retained); the defer endpoint ' \
                      'pays one '
                code { 'verify_defer' }
                plain ' (~99k i/s). '
                code { 'benchmark/micro/defer_token.rb' }
                plain ' isolates all three.'
              end
              DocsUI::Callout(:warning) do
                plain 'Profile FIRST. An app-side N+1 or a missing eager-load looks exactly like ' \
                      'framework lag — the feature\'s own origin story was a scoreboard that "felt slow" ' \
                      'per keystroke and turned out to be 2+N queries fixed by one eager load. Make the ' \
                      'synchronous path cheap before making it async; defer only a segment that is ' \
                      'GENUINELY expensive.'
              end
            end
          end
        end

        def loading_the_client
          DocsUI::Section('Loading the client lazily') do
            DocsUI::Prose() do
              p do
                plain 'An app that keeps light pages light loads its Stimulus controllers on demand '
                plain '(stimulus-loading, a '
                code { 'preload: false' }
                plain ' pin). The reactive controller can load that way too, as long as '
                code { 'phlex/reactive/early' }
                plain ' is imported eagerly (issue #273). It is under 1.1 KB gzipped (a test asserts '
                plain 'it) and has no Stimulus import. Until a root connects, it queues the trigger events '
                plain 'that reach it and stops their native default where the controller would; the '
                plain 'controller replays them when it connects. Without it, a click in the load window '
                plain 'is lost, so the only safe choice used to be loading the full client on every page '
                plain 'that might contain a root.'
              end
              p do
                plain 'Each root marks the moment with '
                code { 'data-reactive-connected' }
                plain ' and a bubbling '
                code { 'reactive:connect' }
                plain ' event. Queued triggers older than '
                code { 'Phlex::Reactive.early_event_ttl_ms' }
                plain ' (10 s by default, read from '
                code { '<meta name="phlex-reactive-early-ttl">' }
                plain ') are dropped rather than fired out of nowhere.'
              end
            end
          end
        end

        def dormant_roots
          DocsUI::Section('Dormant roots') do
            DocsUI::Prose() do
              p do
                plain 'Loading the controller lazily only helps on pages with no reactive root. One root in '
                plain 'a shared layout (a closed dialog, a collapsed panel, a menu that loads its items on '
                plain 'open) puts the client back on every page, because a root renders '
                code { 'data-controller="reactive"' }
                plain ' and that is what makes Stimulus load and connect it. Measured on such a page '
                plain '(issue #274), with the controller pinned '
                code { 'preload: false' }
                plain ' and no other reactive root:'
              end
              ul do
                li { 'Without the dialog: 21 script modules on load, no reactive client fetched.' }
                li do
                  plain 'With the dialog, never opened: 24 script modules, and the client fetched: '
                  plain '68,492 B minified, 20,009 B gzipped, 17,623 B brotli.'
                end
                li do
                  plain 'The dialog was reactive so that its list could load on open, which took about '
                  plain '0.1–0.25 KB (gzipped) of inline markup out of each page. Loading the client for it '
                  plain 'cost roughly a hundred times that in JavaScript.'
                end
              end
              p do
                plain 'A '
                strong { 'dormant' }
                plain ' root costs nothing until it is used. It renders '
                code { 'data-reactive-dormant="reactive"' }
                plain ' in place of the controller attribute, so nothing mounts and a lazily loaded '
                plain 'controller is not fetched. The first trigger that reaches it wakes it: '
                code { 'phlex/reactive/early' }
                plain ' moves the identifier into '
                code { 'data-controller' }
                plain ', Stimulus loads and connects the controller, and the trigger is replayed.'
              end
            end
            DocsUI::Code(<<~RUBY, lexer: :ruby, filename: 'app/components/items_panel.rb')
              class ItemsPanel < ApplicationComponent
                include Phlex::Reactive::Component

                reactive_dormant              # every root of this component, inherited
                action :load

                def view_template
                  div(**mix(reactive_root, on(:load, event: "panel:opened", once: true))) { … }
                end
              end

              # Or one render at a time:
              div(**reactive_root(dormant: true)) { … }
            RUBY
            DocsUI::Callout(:warning) do
              plain 'A dormant root needs '
              code { 'import "phlex/reactive/early"' }
              plain ' in your entry point. Without that module nothing wakes the root: a link or form '
              plain 'trigger does its native thing (the link navigates, the form posts), and a dormant '
              plain 'root nested inside an awake one hands its triggers to the outer component, which '
              plain 'runs its own action of that name or answers 403. '
              code { 'bin/rails phlex_reactive:doctor' }
              plain ' lists the dormant components and says whether it found the import.'
            end
            DocsUI::Prose() do
              h3 { 'What renders awake' }
              p do
                plain "The actor's own reply renders a dormant root awake: the reply only exists because "
                plain "that page's controller is loaded, so a dormant replacement would cost one more "
                plain 'wake and save nothing. The same goes for a '
                code { 'reactive_lazy(on:)' }
                plain ' materialize and the defer endpoint. Every other render stays dormant: the page, a '
                code { 'broadcast_to' }
                plain ' (also one fired inside an action), a page refresh, a deferred render pushed over '
                plain 'a stream. If one of those lands on a root that is already awake, the root goes '
                plain 'back to sleep and the next trigger wakes it again; no trigger is lost.'
              end
              p do
                plain 'One case renders awake where you may not want it: a '
                code { 'to_stream_replace' }
                plain ' built inside an action and sent to other pages by hand. Use '
                code { 'broadcast_to' }
                plain ' for those.'
              end
              h3 { 'With reactive_lazy' }
              p do
                plain 'An event shell can be dormant: '
                code { 'reactive_lazy on: "panel:opened"' }
                plain ' plus '
                code { 'reactive_dormant' }
                plain ' gives "load this the first time it opens, and do not fetch the reactive controller '
                plain 'until then". '
                plain 'The event wakes the root and loads it in one request, and the content arrives awake. '
                code { 'on: :visible' }
                plain ' cannot be dormant, because its shell has no trigger to wake on; declaring both '
                plain 'raises. A plain '
                code { 'reactive_lazy' }
                plain ' shell always mounts, because it fetches on connect. On a lazy component, declare '
                code { 'reactive_dormant' }
                plain ' on the class: the framework renders the shell, so a per-render '
                code { 'reactive_root(dormant: true)' }
                plain ' in the template never reaches it.'
              end
              h3 { 'Limits' }
              ul do
                li do
                  plain 'Use it for a root whose only behaviour is its triggers. Anything the controller '
                  plain 'does at connect waits for the wake too: '
                  code { 'reactive_persist' }
                  plain ' restore, '
                  code { 'reactive_compute' }
                  plain ' seeding, show/filter sync, dirty tracking. The browser inspector ('
                  code { 'inspect.js' }
                  plain ') does not list a dormant root.'
                end
                li do
                  plain 'Only element-bound '
                  code { 'on' }
                  plain ' / '
                  code { 'on_client' }
                  plain ' triggers wake a root. A '
                  code { 'window:' }
                  plain ' or '
                  code { 'outside:' }
                  plain ' trigger, and the feature actions (list navigation, tags, nested rows), do not.'
                end
                li do
                  plain 'When the root also lists a controller of your own, put it first: '
                  code { 'mix({ data: { controller: "dropdown" } }, reactive_root)' }
                  plain '. Waking appends '
                  code { 'reactive' }
                  plain ' to the list, so that order matches what an awake reply renders. In the other '
                  plain 'order, the first morph reply reorders the list and Stimulus reconnects both '
                  plain 'controllers once.'
                end
                li do
                  plain 'A dormant root nested inside an awake one belongs to the outer root until it '
                  plain 'wakes (its fields are collected with the outer root\'s actions).'
                end
                li do
                  plain 'Waking costs '
                  code { 'early.js' }
                  plain ' 53 bytes: 1,007 B → 1,060 B gzipped (bun, level 9), under a 1,100 B test budget.'
                end
              end
            end
          end
        end

        def client_numbers
          DocsUI::Section('Client dispatch numbers') do
            DocsUI::Prose() do
              p do
                plain 'The client hot path — the JS that runs in the browser on every click and keystroke — '
                plain 'is benched off-browser with mitata + happy-dom ('
                code { 'rake bench:client' }
                plain '). The three benched paths are '
                code { '#extractToken' }
                plain ' (regex-reading the next signed token out of the turbo-stream response body), '
                code { '#collectFields' }
                plain " (the one walk that auto-collects a root's named inputs into the action params, "
                plain 'scoped past nested reactive roots), and '
                code { 'recompute' }
                plain ' (the client-side data-binding compute). All three are driven through the '
                strong { "controller's public surface" }
                plain ' ('
                code { 'dispatch()' }
                plain ' / '
                code { 'recompute()' }
                plain ') — no test-only export is added to the shipped controller.'
              end
              h3 { 'How to read these — two different kinds of number' }
              p do
                plain 'These are '
                strong { 'not all the same currency.' }
                plain ' Read them by what engine produced them:'
              end
              ul do
                li do
                  strong { 'engine-faithful' }
                  plain ' — '
                  code { '#extractToken' }
                  plain ' is a pure regex pass over a string. bun runs on JavaScriptCore, the same '
                  plain 'engine class a browser uses, so the regex numbers approximate real browser cost '
                  plain '(not identical, but the right order of magnitude).'
                end
                li do
                  strong { 'engine-relative' }
                  plain ' — '
                  code { '#collectFields' }
                  plain ' and '
                  code { 'recompute' }
                  plain ' walk a real DOM, provided by happy-dom (a JS DOM implementation, NOT a real '
                  plain "browser's C++ DOM). happy-dom's node/query costs differ from Blink/WebKit in "
                  plain 'absolute terms, so treat these as a '
                  strong { 'same-machine before/after baseline' }
                  plain ' — valid for measuring whether a change made THIS path faster or slower, not as '
                  plain 'an absolute "microseconds in Chrome" figure.'
                end
              end
              h3 { 'Representative baselines' }
              p do
                plain 'Measured on bun 1.3 (JavaScriptCore), Apple M2 Max. Your absolute numbers will '
                plain 'differ; capture your own before/after on one machine.'
              end
              ul do
                li do
                  strong { 'engine-faithful. ' }
                  code { '#extractToken' }
                  plain ' over a ~2KB single-component response: ~4.4 µs. Over a ~500KB 200-row reactive '
                  plain 'collection (the worst realistic scan — every row carries its own token, the '
                  plain "container's fresh token rides last): ~9 µs. For comparison, a full "
                  code { 'DOMParser' }
                  plain ' parse of that same 500KB body is ~4.3 ms — '
                  strong { '~450× slower' }
                  plain ': the targeted regex is why token extraction never parses the body into a document. '
                  plain 'The two per-id regexes are '
                  strong { 'memoized on the stable root id' }
                  plain ' (issue #118) — compiled once, reused across every response, rebuilt only if the id '
                  plain 'changes — but this was '
                  strong { 'measured, not assumed: ' }
                  plain 'extractToken is already ~0.25% of the '
                  code { 'DOMParser' }
                  plain ' ceiling, so removing two regex allocations per call is a correctness/cleanliness win '
                  plain 'that sits below the timing floor of the dispatch-driven bench. Not worth further optimization.'
                end
                li do
                  strong { 'engine-relative. ' }
                  code { '#collectFields' }
                  plain ' via a full dispatch over happy-dom: ~34 µs for a 5-field form, ~96 µs for a '
                  plain '60-field grid. Adding 2 nested reactive roots (the ownership filter, issue #15) '
                  plain 'adds ~6%. The ownership check is hoisted to once per dispatch (issue #117): with '
                  plain 'no nested reactive root — the common case — the '
                  code { 'closest()' }
                  plain ' scope check per field is skipped entirely. '
                  code { 'collectFields' }
                  plain ' runs once per dispatch, so this is dominated by the dispatch overhead and the '
                  plain 'fast path does not move it out of noise.'
                end
                li do
                  strong { 'engine-relative. ' }
                  code { 'recompute' }
                  plain ' on a 30-input calculator (read every declared input, run the reducer, write '
                  plain 'one output): ~23 µs per keystroke over happy-dom, down from ~31 µs (~25%). This '
                  plain 'is where the issue #117 fast path pays off: the pre-#117 per-name '
                  code { 'querySelectorAll' }
                  plain ' + '
                  code { 'closest()' }
                  plain ' walk ran per input AND per output on every keystroke (~60 DOM queries on a '
                  plain '30-field calculator); the hoisted ownership probe plus a first-wins '
                  code { 'byName' }
                  plain ' memo collapses that to one query per distinct declared name, with the ownership '
                  plain 'decision made once. A per-keystroke (method-level) win, not a request-level one.'
                end
              end
              DocsUI::Callout(:note) do
                plain 'The '
                code { 'collectFields' }
                plain ' / '
                code { 'recompute' }
                plain " figures include the full dispatch() overhead around the walk (that's the price of "
                plain 'benching through the public surface instead of a private export). They are a '
                plain 'consistent baseline for a before/after, not the isolated cost of the walk alone.'
              end
              h3 { 'Payload size (what the browser downloads)' }
              p do
                plain 'The client runtime is auto-pinned and preloaded on every page, so its transfer size '
                plain 'is a real cost. The authored source is comment-dense on purpose (the source IS the '
                plain "documentation, and the JS suite imports it), so the gem doesn't ship it to browsers — "
                plain 'it ships a '
                strong { 'prebuilt minified twin' }
                plain ' of each module ('
                code { 'rake build:js' }
                plain ', bun) with a linked sourcemap. The engine pins the '
                code { '.min.js' }
                plain '; devtools resolves the '
                code { '.map' }
                plain ' back to the readable source on demand.'
              end
              ul do
                li do
                  code { 'reactive_controller.js' }
                  plain ': 106 KB → '
                  strong { '22 KB' }
                  plain ' minified (−79%); ~36 KB → '
                  strong { '~7.7 KB' }
                  plain ' gzipped (−78%).'
                end
                li do
                  code { 'confirm.js' }
                  plain ' + '
                  code { 'compute.js' }
                  plain ': 7 KB → 0.5 KB combined (the two override seams).'
                end
              end
              p do
                plain 'The bun minifier output is '
                strong { 'deterministic' }
                plain ' (byte-identical across bun patch releases), so the '
                code { '.min.js' }
                plain '/'
                code { '.min.js.map' }
                plain ' are committed and shipped in the gem — consumers need no bun — and CI ('
                code { 'rake build:js_check' }
                plain ') rebuilds and fails if a source edit landed without a rebuild. The system suite '
                plain 'runs the vendored minified build in a real browser under both Puma and Falcon, so '
                plain 'the code that ships is the code that is proven.'
              end
            end
          end
        end

        def ci
          DocsUI::Section('CI') do
            DocsUI::Prose() do
              p do
                plain 'The '
                code { 'bench' }
                plain ' job in '
                code { '.github/workflows/main.yml' }
                plain ' runs the micro suite and the request bench on every PR and uploads the report as '
                plain 'the '
                code { 'benchmarks' }
                plain ' artifact. It is run-and-report, never a hard fail — it surfaces trends, it does not '
                plain "gate merges on a flaky threshold. Download the artifact from the PR's checks tab to "
                plain 'see the numbers for that branch.'
              end
            end
          end
        end

        def every_change
          DocsUI::Section('Performance is part of every change') do
            DocsUI::Prose() do
              p do
                plain 'See '
                a(href: 'https://github.com/zoolutions/phlex-reactive/blob/main/.claude/rules/performance.md') do
                  plain '.claude/rules/performance.md'
                end
                plain ': any change to a hot path ships with a bench, the README/CHANGELOG/docs are updated, '
                plain 'and the JS vendored copy is re-synced. Run '
                code { '/perf' }
                plain ' to benchmark the current branch and get a written before/after.'
              end
            end
          end
        end

        def adding_a_benchmark
          DocsUI::Section('Adding a benchmark') do
            DocsUI::Prose() do
              p do
                plain 'A new hot path gets a new '
                code { 'benchmark/micro/<name>.rb' }
                plain '. Use the shared harness:'
              end
            end
            DocsUI::Code(<<~RUBY, lexer: :ruby, filename: 'benchmark/micro/my_hot_path.rb')
              require_relative "../support/boot"   # boots the dummy app + schema

              BenchSupport.header("my hot path")
              BenchSupport.ips { |x| x.report("thing") { thing_under_test } }
              BenchSupport.allocations("thing") { thing_under_test }
            RUBY
            DocsUI::Prose() do
              p do
                code { 'rake bench:micro' }
                plain ' picks it up automatically (it globs '
                code { 'benchmark/micro/*.rb' }
                plain ').'
              end
              p do
                plain 'A new '
                strong { 'client' }
                plain ' hot path gets a '
                code { 'benchmark/client/<name>.bench.js' }
                plain ' that registers its benches with mitata and is imported by '
                code { 'benchmark/client/index.bench.js' }
                plain '. Drive the controller through its public methods (as '
                code { 'benchmark/client/support/harness.js' }
                plain ' does) — never add a test-only export to the shipped controller, which would trip '
                plain 'the vendored-client re-sync rule.'
              end
            end
          end
        end
      end
    end
  end
end
