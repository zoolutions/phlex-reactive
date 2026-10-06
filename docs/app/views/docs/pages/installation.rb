# frozen_string_literal: true

module Views
  module Docs
    module Pages
      class Installation < DocsUI::Page
        title 'Installation'
        eyebrow 'Guide'
        description 'Install phlex-reactive in Rails: add the gem, run the installer, register the Stimulus controller for importmap, esbuild, or bun, then verify with the doctor'

        def lead
          'Add the gem, run the installer, register one Stimulus controller eagerly — ' \
            'the Rails engine wires up the endpoint and assets for you.'
        end

        def content
          install
          generators
          importmap
          jsbundling
          bun
          requirements
          falcon
          configuration
          verify
        end

        private

        def install
          DocsUI::Section('Install') do
            DocsUI::Code(<<~RUBY, lexer: :ruby, filename: 'Gemfile')
              gem "phlex-reactive"
            RUBY
            DocsUI::Code(<<~SHELL, lexer: :shell)
              bundle install
              bin/rails generate phlex:reactive:install
            SHELL
            DocsUI::Prose() do
              p { plain 'The Rails engine automatically:' }
              ul do
                li do
                  plain 'mounts '
                  code { 'POST /reactive/actions' }
                  plain ' → '
                  code { 'Phlex::Reactive::ActionsController#create' }
                end
                li do
                  plain "adds the gem's "
                  code { 'app/javascript' }
                  plain ' to the asset paths'
                end
                li do
                  plain 'auto-pins (and '
                  code { 'preload: true' }
                  plain 's) the client controller for importmap apps'
                end
              end
              p do
                plain 'The '
                strong { 'installer' }
                plain ' ('
                code { 'phlex:reactive:install' }
                plain ') does the host-app wiring:'
              end
              ul do
                li do
                  plain 'registers the '
                  code { 'reactive' }
                  plain ' Stimulus controller eagerly in your entrypoint'
                end
                li do
                  plain 'writes '
                  code { 'config/initializers/phlex_reactive.rb' }
                  plain ' with the common options'
                end
              end
              p do
                plain "If you'd rather wire it by hand, register the controller once (eagerly — below)."
              end
            end
          end
        end

        def generators
          DocsUI::Section('Generators') do
            DocsUI::Code(<<~SHELL, lexer: :shell)
              # Setup (idempotent)
              bin/rails generate phlex:reactive:install

              # Scaffold a state-backed component (record-less)
              bin/rails generate phlex:reactive:component Counter increment decrement

              # Scaffold a record-backed component (signed GlobalID identity)
              bin/rails generate phlex:reactive:component Todos::Item toggle rename --record todo

              # Custom signed state vars
              bin/rails generate phlex:reactive:component Wizard next_step --state step open
            SHELL
            DocsUI::Prose() do
              p do
                plain 'The component generator also writes an RSpec spec when your app has a '
                code { 'spec/' }
                plain ' directory.'
              end
            end
          end
        end

        def importmap
          DocsUI::Section('importmap-rails (default Rails 7+)') do
            DocsUI::Code(<<~JS, lexer: :javascript, filename: 'app/javascript/controllers/index.js')
              import { application } from "controllers/application"
              import ReactiveController from "phlex/reactive/reactive_controller"
              application.register("reactive", ReactiveController)
            JS
            DocsUI::Callout(:warning, title: 'Eager, or lazy with phlex/reactive/early') do
              plain 'If you '
              code { 'lazyLoadControllersFrom' }
              plain ', the controller is fetched on first appearance — and a user who clicks ' \
                    'immediately after load can fire before it connects, so nothing happens. Eager ' \
                    "registration (above) guarantees it's bound before any interaction. To load it " \
                    'lazily instead, add '
              code { 'import "phlex/reactive/early"' }
              plain ' to your entry point: that module (under 1.3 KB gzipped, pinned and preloaded by ' \
                    'the engine) queues an '
              code { 'on(...)' }
              plain ' or '
              code { 'on_client(...)' }
              plain ' trigger that fires before the controller connects, and the controller replays ' \
                    'it on connect. That includes a '
              code { 'window:' }
              plain ' hotkey pressed anywhere on the page: it is never prevented, and it is replayed ' \
                    'only if the controller connects within 1.5 s of the keypress (or the early-event ' \
                    'TTL, if that is shorter). Two limits: a ' \
                    'captured link or form trigger has its native behavior stopped while it waits, ' \
                    'so it does nothing if the controller never loads; and other controller actions ' \
                    '(nested rows, tags, list navigation, compute) and '
              code { 'outside:' }
              plain ' triggers are not captured.'
            end
            DocsUI::Prose() do
              p do
                plain 'The same module lets a root cost nothing until it is used: '
                code { 'reactive_dormant' }
                plain ' (or '
                code { 'reactive_root(dormant: true)' }
                plain ') renders the root without '
                code { 'data-controller="reactive"' }
                plain ", so a lazily loaded controller is not fetched until one of the root's " \
                      'triggers fires. See '
                a(href: '/docs/performance') { 'Dormant roots' }
                plain ' on the performance page.'
              end
            end
          end
        end

        def jsbundling
          DocsUI::Section('esbuild / rollup / webpack (jsbundling)') do
            DocsUI::Code(<<~JS, lexer: :javascript, filename: 'app/javascript/controllers/index.js')
              import { application } from "./application"
              import ReactiveController from "phlex/reactive/reactive_controller"
              application.register("reactive", ReactiveController)
            JS
            DocsUI::Prose() do
              p do
                plain 'The gem ships a prebuilt minified module ('
                code { 'reactive_controller.min.js' }
                plain ', the whole client in one file, about 25 KB gzipped) with a linked sourcemap. It ' \
                      'imports three small modules by their bare names: '
                code { 'phlex/reactive/confirm' }
                plain ', '
                code { 'phlex/reactive/confirm_predicate' }
                plain ' and '
                code { 'phlex/reactive/compute' }
                plain ', the seams an app can override. Point your bundler at the gem with one prefix ' \
                      'alias for '
                code { 'phlex/reactive' }
                plain ':'
              end
            end
            DocsUI::Code(<<~JS, lexer: :javascript, filename: 'esbuild.config.mjs')
              import * as esbuild from "esbuild"
              import { execSync } from "node:child_process"
              const gemJs = `${execSync("bundle show phlex-reactive").toString().trim()}/app/javascript`

              await esbuild.build({
                // …
                plugins: [{
                  name: "phlex-reactive",
                  setup(build) {
                    build.onResolve({ filter: /^phlex\\/reactive\\// }, ({ path }) => ({ path: `${gemJs}/${path}.min.js` }))
                  },
                }],
              })
            JS
            DocsUI::Prose() do
              p do
                plain 'The same alias covers the opt-in split client ('
                code { 'phlex/reactive/core' }
                plain ', a smaller controller that imports its feature modules on demand); add '
                code { 'splitting: true, format: "esm"' }
                plain ' so each feature becomes its own chunk. See '
                a(href: '/docs/performance') { 'What loads when' }
                plain ' on the performance page before you opt in.'
              end
              p do
                plain 'Importing '
                code { 'reactive_controller.js' }
                plain ' also registers the '
                code { 'reactive:visit' }
                plain ' Turbo '
                code { 'StreamAction' }
                plain ' that powers '
                code { 'reply.redirect' }
                plain '. The '
                code { 'import ReactiveController' }
                plain " above covers this; if you vendor the file, make sure it's actually imported " \
                      "(not tree-shaken away) or redirects won't fire."
              end
            end
          end
        end

        def bun
          DocsUI::Section('bun (bun-rails)') do
            DocsUI::Prose() do
              p do
                plain 'Same as esbuild. Point the import at the gem path or vendor the file.'
              end
            end
          end
        end

        def requirements
          DocsUI::Section('Requirements') do
            DocsUI::Prose() do
              ul do
                li do
                  strong { 'Rails' }
                  plain ' ≥ 7.1'
                end
                li do
                  strong { 'Phlex 2' }
                  plain ' via '
                  code { 'phlex-rails' }
                  plain ', with an '
                  code { 'ApplicationComponent < Phlex::HTML' }
                  plain ' base class that includes the Phlex Rails helpers ('
                  code { 'dom_id' }
                  plain ', '
                  code { 't' }
                  plain ', routes, etc.)'
                end
                li do
                  strong { 'Turbo' }
                  plain ' ≥ 8 (for morphing) — '
                  code { 'turbo-rails' }
                  plain ', with '
                  code { 'window.Turbo' }
                  plain ' available'
                end
                li do
                  plain 'A '
                  code { '<meta name="csrf-token">' }
                  plain ' in your layout (standard Rails)'
                end
                li do
                  strong { 'pgbus' }
                  plain ' (optional, recommended) — the reliable broadcast transport. See '
                  a(href: doc_path('broadcasting')) { 'Broadcasting' }
                  plain ' and '
                  a(href: doc_path('transport-pgbus')) { 'Transport: pgbus' }
                  plain ' to wire it up.'
                end
              end
            end
          end
        end

        def falcon
          DocsUI::Section('Running under Falcon') do
            DocsUI::Prose() do
              p do
                plain 'Falcon serves each request as a fiber on one thread. Rails keys its per-request ' \
                      'state on '
                code { 'config.active_support.isolation_level' }
                plain ', which defaults to '
                code { ':thread' }
                plain ', so under Falcon every thread-keyed value is shared by the requests that thread ' \
                      'serves: '
                code { 'ActiveSupport::CurrentAttributes' }
                plain ', '
                code { 'IsolatedExecutionState' }
                plain ', thread variables ('
                code { 'Thread#thread_variable_get' }
                plain '), and the lock on the connection transactional tests pin (two overlapping ' \
                      'requests wedge the server). Set it to '
                code { ':fiber' }
                plain ' for an app served by Falcon:'
              end
            end
            DocsUI::Code(<<~RUBY, lexer: :ruby, filename: 'config/application.rb')
              config.active_support.isolation_level = :fiber
            RUBY
            DocsUI::Prose() do
              p do
                plain 'phlex-reactive keeps its own request state in fiber-local storage, so the gem ' \
                      'works either way; this setting protects the app around it. Puma serves a thread ' \
                      'per request and needs nothing. '
                code { 'bin/rails phlex_reactive:doctor' }
                plain ' fails when Falcon serves the app under '
                code { ':thread' }
                plain ', and is advisory when Falcon is bundled beside another server and is not the ' \
                      'only server loaded: it sees every server in the bundle, but a rake task loads only ' \
                      'the ones the Gemfile auto-requires, so it cannot tell which one runs.'
              end
            end
          end
        end

        def configuration
          DocsUI::Section('Configuration') do
            DocsUI::Prose() do
              p do
                plain 'Create '
                code { 'config/initializers/phlex_reactive.rb' }
                plain ' as needed:'
              end
            end
            DocsUI::Code(<<~'RUBY', lexer: :ruby, filename: 'config/initializers/phlex_reactive.rb')
              Phlex::Reactive.base_controller_name = "ApplicationController"   # CSRF + auth + Current
              Phlex::Reactive.renderer             = ApplicationController     # app helpers during render
              Phlex::Reactive.authorization_errors = [Pundit::NotAuthorizedError]
              # Phlex::Reactive.action_path = "/_r/actions"                   # custom endpoint
              # Phlex::Reactive.verifier    = ActiveSupport::MessageVerifier.new(ENV["REACTIVE_KEY"])
              # Phlex::Reactive.flash_target = "flash"                         # DOM id reply…flash appends into
              # Phlex::Reactive.flash_component = ->(level, content) { MyFlash.new(level:, content:) } # renders string flashes
              # Phlex::Reactive.error_flash  = ->(kind) { "Something went wrong (#{kind})." } # flash on endpoint failures
            RUBY
            DocsUI::Prose() do
              p do
                strong { 'error_flash' }
                plain ' turns the failures the '
                strong { 'endpoint' }
                plain ' catches — bad token, default-deny, authorization, missing record (the '
                code { '400' }
                plain '/'
                code { '403' }
                plain '/'
                code { '404' }
                plain ' rescue paths) — into a turbo-stream flash the user sees, at the '
                strong { 'same status' }
                plain ' it already returns (statuses never change). The '
                code { 'kind' }
                plain ' argument is one of '
                code { ':tampered' }
                plain ', '
                code { ':unknown_class' }
                plain ', '
                code { ':not_reactive_class' }
                plain ', '
                code { ':forbidden' }
                plain ', '
                code { ':not_found' }
                plain '. It composes with '
                code { 'flash_target' }
                plain '/'
                code { 'flash_component' }
                plain ' above.'
              end
            end
            observability
            action_path_meta
            client_metas
            param_types
          end
        end

        def observability
          DocsUI::Prose() do
            h3 { 'Observability & diagnostics' }
            p do
              plain 'Three opt-in knobs help you see what the endpoint and client are doing. '
              plain 'None of them change HTTP statuses or leak token/param values.'
            end
            ul do
              li do
                code { 'Phlex::Reactive.verbose_errors' }
                plain ' — diagnostic endpoint error bodies + dropped-param logging (statuses never change). '
                plain 'Defaults to '
                code { 'Rails.env.local?' }
                plain ' — on in development '
                strong { 'and' }
                plain ' test, off in production.'
              end
              li do
                code { 'Phlex::Reactive.log_events' }
                plain ' — one compact line per reactive event (action/render/broadcast) at '
                code { 'DEBUG' }
                plain ' — '
                code { '[reactive] Counter#increment ok (3.1ms)' }
                plain '. Default off. The events fire for your APM regardless ('
                code { 'ActiveSupport::Notifications' }
                plain ', '
                code { '*.phlex_reactive' }
                plain '); this flag only controls the gem’s own log lines.'
              end
              li do
                code { 'Phlex::Reactive.debug' }
                plain ' — client debug mode (devtools-lite). When on, every reactive root carries '
                code { 'data-reactive-debug="true"' }
                plain ' and the console groups every dispatch — action, param '
                strong { 'names' }
                plain ' (never values), status, stream targets, round-trip ms. Off by default; gate it on '
                code { 'Rails.env.development?' }
                plain '.'
              end
            end
          end
        end

        def action_path_meta
          DocsUI::Prose() do
            p do
              plain 'If you change '
              code { 'action_path' }
              plain ', expose it to the client:'
            end
          end
          DocsUI::Code(<<~ERB, lexer: :erb)
            <meta name="phlex-reactive-action-path" content="<%= Phlex::Reactive.action_path %>">
          ERB
        end

        def client_metas
          DocsUI::Prose() do
            h3 { 'Client page-meta knobs' }
            p do
              plain 'Two more '
              code { '<meta>' }
              plain ' tags tune the client runtime. There is '
              strong { 'no' }
              plain ' server-side setting for either — they live in your layout head.'
            end
          end
          DocsUI::Code(<<~ERB, lexer: :erb)
            <%# Client request timeout (default 30s). A hung request aborts client-side after %>
            <%# this window (reactive:error kind "timeout"), so the per-component queue never wedges. %>
            <meta name="phlex-reactive-timeout" content="15000"> <%# 15s, in ms %>

            <%# Latency simulator — DEVELOPMENT ONLY. Exposes window.PhlexReactive.enableLatencySim(ms) / %>
            <%# disableLatencySim() so you can actually SEE pending/optimistic affordances (~5ms locally). %>
            <%= tag.meta(name: "phlex-reactive-env", content: "development") if Rails.env.development? %>
          ERB
          DocsUI::Prose() do
            p do
              plain 'A timed-out POST may have '
              strong { 'succeeded' }
              plain ' server-side — phlex-reactive never auto-replays, so make retryable actions idempotent. '
              plain 'With the latency simulator meta present, toggle it from the browser console: '
              code { 'PhlexReactive.enableLatencySim(400)' }
              plain ' delays every action 400ms (persists to sessionStorage, clears when the tab closes). '
              plain 'Without the meta there is no global handle and zero production surface.'
            end
          end
        end

        def param_types
          DocsUI::Prose() do
            h3 { 'Custom param types' }
            p do
              plain 'Register your own coercion for '
              code { 'action ..., params:' }
              plain ' in the initializer. The block gets the raw client value and returns the coerced value, or '
              code { 'Phlex::Reactive::ParamSchema::DROP' }
              plain ' to reject it (the keyword default then applies — the drop-don’t-fabricate contract).'
            end
          end
          DocsUI::Code(<<~RUBY, lexer: :ruby, filename: 'config/initializers/phlex_reactive.rb')
            Phlex::Reactive.param_type(:money) do |value|
              /\\A\\d+(\\.\\d{1,2})?\\z/.match?(value.to_s) ? BigDecimal(value) : Phlex::Reactive::ParamSchema::DROP
            end

            # then, in any component:
            #   action :charge, params: { amount: :money }
            #   def charge(amount:) = @invoice.charge!(amount) # a BigDecimal, or unset
          RUBY
          DocsUI::Callout(:warning, title: 'Register during boot only') do
            plain 'The registry is '
            strong { 'frozen after initialization' }
            plain ' (the engine’s '
            code { 'after_initialize' }
            plain ' calls '
            code { 'freeze_param_types!' }
            plain '), so a runtime '
            code { 'param_type' }
            plain ' call raises. Declare every custom type in the initializer.'
          end
        end

        def verify
          DocsUI::Section('Verify it works') do
            DocsUI::Prose() do
              p do
                plain 'Run the doctor — it validates the whole install (route, Stimulus registration, ' \
                      'CSRF, the identity verifier, and every component) and prints '
                code { '✓/✗/?' }
                plain ' with a fix for each failure:'
              end
            end
            DocsUI::Code(<<~SHELL, lexer: :shell)
              bin/rails phlex_reactive:doctor
            SHELL
            DocsUI::Prose() do
              p do
                plain 'Then drop a counter on any page, click '
                code { '+' }
                plain ', and watch it increment with no full-page reload. If it reloads or does ' \
                      'nothing, check the testing guide troubleshooting section.'
              end
            end
            DocsUI::Callout(:tip) do
              plain 'The doctor is read-only and safe to run anywhere. A '
              code { '✗' }
              plain ' points at the exact fix; a '
              code { '?' }
              plain ' is advisory (e.g. it can’t confirm csrf_meta_tags in a Phlex-only layout). ' \
                    'No full-page reload on the click is the runtime signal everything is wired.'
            end
          end
        end
      end
    end
  end
end
