# frozen_string_literal: true

module Views
  module Docs
    module Pages
      # Concurrency (zoolutions/phlex-reactive#364): the conformance tiers, what is
      # fiber-local and why, the configuration finalized at boot, and what Ractor
      # mode needs and still waits on upstream.
      class Concurrency < DocsUI::Page
        title 'Concurrency & Ractors'
        eyebrow 'Guide'
        description 'How phlex-reactive behaves under Puma threads, Falcon fibers and Ruby Ractors: ' \
                    'fiber-local request state, a configuration finalized at boot, and what Ractor mode waits on.'

        def lead
          'phlex-reactive is thread-safe under Puma, fiber-safe under Falcon, and adds nothing of its own that ' \
            'stops a Ractor: its configuration is finalized at boot and its caches are per-Ractor. A whole app in ' \
            'Ractor mode still waits on Rails, ActiveSupport and Phlex.'
        end

        def content
          tiers
          request_state
          finalized_configuration
          ractor_mode
          checking
        end

        private

        def tiers
          DocsUI::Section('What is held, and how') do
            md <<~MD
              phlex-reactive is held to the zoolutions concurrency tiers, each with a
              mechanical gate in CI ([conformance-kit](https://github.com/zoolutions/conformance-kit)):

              | Tier | What it means here | Checked by |
              |---|---|---|
              | 1 thread-safe | No unguarded shared mutable state on the request or broadcast path | Every `rubocop-thread_safety` cop, no excludes; thread-contention examples over rendering, tokens, params and broadcasts |
              | 2 fiber-safe | Request state is fiber-local; the same work runs inside one Async reactor | The Falcon browser lanes; the Async examples |
              | 3 Ractor-clean | Every setting is Ractor-shareable after boot, no class is written on the request path, caches are per-Ractor | `conformance-audit --strict`; the Ruby 4.0 Ractor canary |
              | 4 compiler-probed | Spinel and Roundhouse readiness is measured, never gated | The conformance workflow's report-only probes |
            MD
          end
        end

        def request_state
          DocsUI::Section('Request state is fiber-local') do
            md <<~MD
              Everything that belongs to one request lives in `Thread.current[]`,
              which Ruby keeps **per fiber**: the acting client's connection id
              (`with_connection_id`), the requesting host (`with_url_options`), the
              defer binding, and the `verify_authorized` tracking window. Under Falcon
              every request is a fiber, so two requests on one thread never see each
              other's state, and nothing has to be reset between them.

              The off-request view context and the Turbo stream builder are cached
              the same way. Puma builds them once per thread; Falcon once per request,
              because each request is a new fiber. That rebuild is measured
              (`benchmark/micro/view_context.rb`, Ruby 4.0.6): about 14 µs and 36
              objects for the view context, and 863 objects for a whole action round
              trip in a new fiber against 810 with warm caches. That is a few percent
              of a round trip, so the cache stays per fiber: a view context shared by
              two fibers on one thread would interleave their output, since a render
              that waits on the database yields mid-render under Falcon.
            MD
          end
        end

        def finalized_configuration
          DocsUI::Section('The configuration is finalized at boot') do
            md <<~MD
              Once the app has booted, the engine calls `Phlex::Reactive.finalize!`.
              It runs after your `config/initializers` and after every
              `after_initialize` block you registered, so they can still set and
              append. It freezes the param-type and named-schema registries and stores
              every setting as a deep-frozen, Ractor-shareable **copy**: the objects
              you handed in are not frozen.

              What that changes for you:

              - **Lists are frozen after boot.** Append to `authorization_errors` in an
                initializer or an `after_initialize` block; after boot, assign a new
                list. Writers keep working, and what they write is shared too.
              - **A Proc is shared only when it can be.** A block written in an
                initializer has `main` as its `self`, which no Ractor can share: it
                keeps working on the main Ractor. Write a caster (or `error_flash`)
                as a capture-free lambda in a module body to make it shareable.
              - **Nothing you configure makes boot raise.** A logger, an APM object
                or a lambda that closes over app state is kept as it is and works on
                the main Ractor only.
              - **The verifier is never shared.** It is an
                `ActiveSupport::MessageVerifier`, which ActiveSupport cannot build or
                use outside the main Ractor yet.
              - **Give the renderer by name** to have it follow a code reload in
                development; a class keeps rendering the class object it was given.

              Booting phlex-reactive without the engine? Call
              `Phlex::Reactive.finalize!` at the end of your own boot.
            MD
            DocsUI::Code(<<~RUBY, lexer: :ruby, filename: 'config/initializers/phlex_reactive.rb')
              # Shareable: self is the module, and nothing is captured.
              module ReactiveTypes
                MONEY = ->(value) { BigDecimal(value.to_s) rescue Phlex::Reactive::ParamSchema::DROP }
              end
              Phlex::Reactive.param_type(:money, &ReactiveTypes::MONEY)

              Phlex::Reactive.renderer = "ApplicationController"
              Phlex::Reactive.authorization_errors << Pundit::NotAuthorizedError
            RUBY
          end
        end

        def ractor_mode
          DocsUI::Section('Ractor mode') do
            md <<~MD
              A non-main Ractor can read the configuration once it is finalized. For
              the request path to write no class it also needs **eager loading** (the
              production default): with it, the engine prepends `verify_authorized`'s
              interceptor to every component and resolves every component's
              registries and render memos at boot.

              What runs inside a non-main Ractor today, on Ruby 4.0 (the gem's Ractor
              canary): param coercion through a compiled schema, `Phlex::Reactive::Stream`
              wrapping, `Streamable#dom_id`, reading the finalized configuration, and
              upgrading a verified token payload.

              What waits upstream:

              - **Rendering.** Phlex 2.4.1 reads its unshareable `ATTRIBUTE_CACHE` on
                every element with attributes; a per-Ractor cache is
                [yippee-fun/phlex#1055](https://github.com/yippee-fun/phlex/pull/1055).
              - **Signing and verifying tokens.** `ActiveSupport::MessageVerifier`
                cannot be built or used outside the main Ractor (its codec's class
                attributes and `Messages::Metadata::ENVELOPE_SERIALIZERS` are not
                shareable).
              - **The endpoint.** Rails controllers keep class state of their own,
                and Rails' Ractor support is still landing
                ([rails/rails#58306](https://github.com/rails/rails/pull/58306) and its follow-ups).

              CI's report-only kino smoke serves the dummy app with `kino -m ractor`
              through `ractor-rails-shim` and records the first blocker it meets.
            MD
          end
        end

        def checking
          DocsUI::Section('Checking your app') do
            md <<~MD
              `bin/rails phlex_reactive:doctor` reports Ractor readiness as an
              advisory line: whether eager loading is on, whether the configuration
              is finalized, and which settings hold a value a non-main Ractor cannot
              read (an `around_action` block written in an initializer, say). It never
              fails the doctor.
            MD
          end
        end
      end
    end
  end
end
