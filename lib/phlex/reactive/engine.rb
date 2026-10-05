# frozen_string_literal: true

require "rails/engine"

module Phlex
  module Reactive
    # Rails engine: mounts the action endpoint, makes the client runtime
    # available to the asset pipeline, and auto-pins it for importmap apps so
    # `phlex-reactive` works with zero manual wiring on a standard Rails+Phlex
    # app. (Configurable — see config/ options on Phlex::Reactive.)
    class Engine < ::Rails::Engine
      isolate_namespace Phlex::Reactive

      # The client's feature modules (issue #275), each its own file at the
      # bare specifier phlex/reactive/features/<name>. The DEFAULT client
      # (phlex/reactive/reactive_controller) is one file with all of them
      # bundled in and never fetches these. The opt-in phlex/reactive/core
      # imports one only when a root on the page uses it. Listed here once; the
      # precompile list and the importmap pins below are built from it. The
      # build script (scripts/build_client.js), the core's own table and the
      # default entry name the same features —
      # spec/phlex/engine_client_pin_spec.rb fails when they disagree.
      CLIENT_FEATURES = %w[persist defer form bindings compute effects hints devtools].freeze
      # (Gzipped, bun zlib level 9: the default file 26.1 KB; the core 12.3 KB;
      # persist 3.2, defer 2.8, form 1.0, bindings 5.4, compute 2.1, effects
      # 1.7, hints 1.0, devtools 1.6 KB. spec/javascript/bundle_budget.test.js
      # is the source of truth and holds a ratchet on each.)

      # Mount POST /reactive/actions -> Phlex::Reactive::ActionsController#create
      # and POST /reactive/defer -> #deferred (the pull-lane defer endpoint,
      # issue #165), and GET /reactive/fragment/:id -> FragmentsController#show
      # (the privately cacheable lazy render, issue #277). Apps can change the
      # paths with Phlex::Reactive.action_path / .defer_path / .fragment_path
      # before boot.
      initializer "phlex_reactive.routes" do
        it.routes.append do
          post Phlex::Reactive.action_path, to: "phlex/reactive/actions#create", as: :phlex_reactive_action
          post Phlex::Reactive.defer_path, to: "phlex/reactive/actions#deferred", as: :phlex_reactive_defer
          get "#{Phlex::Reactive.fragment_path}/:id", to: "phlex/reactive/fragments#show",
            as: :phlex_reactive_fragment
        end
      end

      # Make the MINIFIED client build available to Propshaft/Sprockets so it can
      # be fingerprinted, served, and pinned in importmap. The browser ships the
      # minified twin (about a fifth of the source; `rake build:js`), not
      # the comment-dense source. The .min.js.map is precompiled too so devtools
      # resolves the linked sourcemap back to the readable source on demand.
      initializer "phlex_reactive.assets" do
        if it.config.respond_to?(:assets)
          it.config.assets.paths << root.join("app/javascript").to_s
          # The opt-in effects stylesheet (issue #215): built-in enter/exit/
          # update animations, linked by the app with
          # stylesheet_link_tag "phlex/reactive/effects".
          it.config.assets.paths << root.join("app/assets/stylesheets").to_s
          it.config.assets.precompile += %w[
            phlex/reactive/reactive_controller.min.js
            phlex/reactive/reactive_controller.min.js.map
            phlex/reactive/core.min.js
            phlex/reactive/core.min.js.map
            phlex/reactive/early.min.js
            phlex/reactive/early.min.js.map
            phlex/reactive/confirm.min.js
            phlex/reactive/confirm.min.js.map
            phlex/reactive/confirm_predicate.min.js
            phlex/reactive/confirm_predicate.min.js.map
            phlex/reactive/compute.min.js
            phlex/reactive/compute.min.js.map
            phlex/reactive/inspect.min.js
            phlex/reactive/inspect.min.js.map
            phlex/reactive/effects.css
          ]
          it.config.assets.precompile += CLIENT_FEATURES.flat_map do
            ["phlex/reactive/features/#{it}.min.js", "phlex/reactive/features/#{it}.min.js.map"]
          end
        end
      end

      # Auto-pin the client controller for importmap apps so it loads without
      # manual configuration. Apps that don't use importmap include it via the
      # asset pipeline instead (see README).
      initializer "phlex_reactive.importmap", after: "importmap" do
        if defined?(::Importmap::Map) && it.respond_to?(:importmap)
          # The DEFAULT client: one file, the core and every feature bundled.
          it.importmap.pin(
            "phlex/reactive/reactive_controller",
            to: "phlex/reactive/reactive_controller.min.js",
            preload: true
          )
          # The OPT-IN client (issue #275): the controller without its
          # features, which it imports on demand (the feature pins below). An
          # app imports this INSTEAD of reactive_controller, never both. Not
          # preloaded: an app that does not opt in must not fetch it. One that
          # does re-pins it with preload: true, like any entry it imports
          # eagerly.
          it.importmap.pin(
            "phlex/reactive/core",
            to: "phlex/reactive/core.min.js",
            preload: false
          )
          # The early-trigger capture (issue #273): a ~1 KB module the app
          # imports EAGERLY (`import "phlex/reactive/early"`) so a trigger that
          # fires before a lazily loaded controller connects is replayed on
          # connect instead of lost. Preloaded: it must run before the triggers.
          it.importmap.pin(
            "phlex/reactive/early",
            to: "phlex/reactive/early.min.js",
            preload: true
          )
          # The overridable confirm resolver (issue #55). reactive_controller.js
          # imports it by this BARE specifier — `import { confirmResolver } from
          # "phlex/reactive/confirm"` — NOT a relative "./confirm.js" (issue #57:
          # a relative sibling import inside the digested controller resolves to
          # an undigested /assets/.../confirm.js that 404s under Propshaft). This
          # pin maps the bare specifier to the digested asset, so the controller's
          # own import AND an app's `import { setConfirmResolver } from
          # "phlex/reactive/confirm"` both resolve through the import map.
          it.importmap.pin(
            "phlex/reactive/confirm",
            to: "phlex/reactive/confirm.min.js",
            preload: true
          )
          # The client-side compute (data-binding) registry behind
          # reactive_compute. reactive_controller.js imports it by this bare
          # specifier (same import-map rationale as confirm above), and an app
          # registers reducers via `import { setComputeReducer } from
          # "phlex/reactive/compute"` — both resolve through this pin.
          it.importmap.pin(
            "phlex/reactive/compute",
            to: "phlex/reactive/compute.min.js",
            preload: true
          )
          # The client-side confirm-predicate registry (issue #179) — the
          # multi-field escape hatch for conditional confirmation. Same bare-specifier
          # rationale as confirm/compute: reactive_controller.js imports it, and an app
          # registers predicates via `import { setConfirmPredicate } from
          # "phlex/reactive/confirm_predicate"` — both resolve through this pin.
          it.importmap.pin(
            "phlex/reactive/confirm_predicate",
            to: "phlex/reactive/confirm_predicate.min.js",
            preload: true
          )
          # The on-demand client inspector (issue #168). NOT preloaded — it is a
          # dev/debugging tool loaded only when you `import("phlex/reactive/inspect")`
          # from the console, so no page pays for it. The pin makes that dynamic
          # import resolve without any app wiring.
          it.importmap.pin(
            "phlex/reactive/inspect",
            to: "phlex/reactive/inspect.min.js",
            preload: false
          )
          # Feature modules (issue #275), for the opt-in phlex/reactive/core.
          # NOT preloaded: the core imports one only when a root on the page
          # uses it, so a page without such a root never fetches it — and the
          # default client never does. An app on the core that knows it needs
          # one on every page re-pins it with preload: true.
          importmap = it.importmap
          CLIENT_FEATURES.each do
            importmap.pin(
              "phlex/reactive/features/#{it}",
              to: "phlex/reactive/features/#{it}.min.js",
              preload: false
            )
          end
        end
      end

      # Flush memoized off-request view contexts on every code reload (dev) so a
      # reloaded renderer controller class is never served from a stale memo. In
      # production to_prepare runs once (eager load), so the cache simply builds
      # fresh after boot. See Streamable.reset_all_view_contexts!.
      config.to_prepare do
        Phlex::Reactive::Streamable.reset_all_view_contexts!
        Phlex::Reactive.reset_stream_builder!
        Phlex::Reactive::Pending::Markup.reset!
      end

      # Boot-time guard (issue #26): warn if the action path doesn't resolve to
      # the gem controller. Runs after_initialize so the host's full route set
      # (including a bottom-of-file catch-all that would shadow our appended
      # route) is drawn. Turns the opaque "every reactive POST 404s" failure into
      # a one-line log pointing at the cause. No-op when the route is fine.
      config.after_initialize do
        Phlex::Reactive.warn_unless_action_route_mounted!

        # Attach the opt-in LogSubscriber (issue #107) exactly once, only when
        # the app enabled it. attach_to is idempotent-safe here because this runs
        # once per boot; the events fire for APMs regardless of this flag.
        Phlex::Reactive::LogSubscriber.attach_to(:phlex_reactive) if Phlex::Reactive.log_events

        # Attach the turnkey APM adapter (issue #207) when an app set
        # Phlex::Reactive.apm. Resolution is deferred to HERE — after initializers
        # ran, so the vendor SDK (if any) is loaded — and no-ops with one warning
        # when the named SDK is absent (the pgbus optionality invariant). Idempotent.
        Phlex::Reactive::APM.attach! if Phlex::Reactive.apm

        # Freeze the param-type registry (issue #109): custom types register in
        # an initializer, which has run by now, so no further registration is
        # accepted. A schema referencing a type is validated at declaration; the
        # frozen registry makes runtime registration a loud error rather than a
        # never-validated type. Idempotent.
        Phlex::Reactive.freeze_param_types!
        # Freeze the named-schema registry the same way (issue #184).
        Phlex::Reactive.freeze_param_schemas!
      end
    end
  end
end
