# frozen_string_literal: true

module Phlex
  module Reactive
    # Streamable gives a self-contained Phlex component the ability to render
    # ITSELF as a Turbo Stream and to broadcast itself over a stream. Every
    # streamable component must implement `#id` returning a stable DOM id —
    # that id is the Turbo Stream target, so you never hand-pick targets.
    #
    # Class methods (use in controllers):
    #   render turbo_stream: Counter.replace(counter)
    #   render turbo_stream: [Row.append(target: "items", model: @item),
    #                         Totals.update(@order)]
    #
    # Broadcast methods (use in models/jobs/actions):
    #   Counter.broadcast_replace_to(counter, model: counter)
    #   Row.broadcast_append_to(@list, target: "items", model: @item)
    #
    # Convention: the `id` you set on the root element in `view_template` must
    # equal what `#id` returns, so replace/broadcast_replace target it.
    #
    # NOTE: we intentionally do NOT include Turbo::Streams::ActionHelper — it
    # pulls in ActionView::Helpers::TagHelper, which overrides Phlex's internal
    # `tag` method and breaks rendering. We use Turbo::Streams::TagBuilder
    # directly instead.
    module Streamable
      extend ActiveSupport::Concern

      # A per-thread cache entry: an off-request view context + the Turbo
      # TagBuilder bound to it, tagged with the renderer + generation it was
      # built for. Rebuilt on a thread when the renderer object changes or the
      # class generation is bumped — so a reset/reload/renderer-swap is picked
      # up without ever sharing a mutable context across threads.
      ThreadViewContext = Struct.new(:view_context, :builder, :renderer, :generation)

      # Actor-only ops: a js broadcast rejects a broadcast that carries one.
      # Focus ops steal focus in every subscriber's tab (issue #96); submit
      # (issue #226) would force-submit every subscriber's form; paste_into
      # (issue #228) would read every subscriber's clipboard. They belong to
      # the actor's own reply (reply.js) or gesture (on_client / a reducer's
      # $ops), never a broadcast. Names mirror Phlex::Reactive::JS's verbs.
      BROADCAST_REFUSED_OPS = %w[focus focus_first submit paste_into persist_state persist_clear].freeze

      # The broadcast_to verb kwargs (issue #185) → their Turbo stream action.
      # SELF-TARGETING verbs derive the target from the component's #id (require a
      # Streamable payload); CONTAINER verbs need an explicit target: and accept any
      # Phlex component; :js rides the reactive:js custom action.
      BROADCAST_VERBS = {
        replace: "replace", update: "update", append: "append",
        prepend: "prepend", remove: "remove", js: "reactive:js"
      }.freeze
      BROADCAST_SELF_TARGETING = %i[replace remove].freeze
      # The broadcast_collection_to verbs (issue #248) — a collection DELTA, so
      # only the three that change the size. (A `replace:` row is an ordinary
      # broadcast_to: it moves no boundary and needs no count refresh.)
      COLLECTION_VERBS = %i[append prepend remove].freeze
      BROADCAST_CONTAINER = %i[update append prepend].freeze
      BROADCAST_MORPHABLE = %i[replace update].freeze

      # Issue #185: the 11 broadcast_*_to / _to_each methods are removed — each
      # raises a guided error printing the broadcast_to rewrite for that verb.
      # (A module constant, not defined inside class_methods, so it's a clean
      # top-level definition the removal loop below reads.)
      REMOVED_BROADCASTS = {
        broadcast_replace_to: "broadcast_to(*keys, replace: model, morph: …)",
        broadcast_update_to: "broadcast_to(*keys, update: model, morph: …)",
        broadcast_append_to: "broadcast_to(*keys, append: model, target: …)",
        broadcast_prepend_to: "broadcast_to(*keys, prepend: model, target: …)",
        broadcast_remove_to: "broadcast_to(*keys, remove: model)",
        broadcast_js_to: "broadcast_to(*keys, js: ops)",
        broadcast_replace_to_each: "broadcast_to(each: keys, replace: model)",
        broadcast_update_to_each: "broadcast_to(each: keys, update: model)",
        broadcast_append_to_each: "broadcast_to(each: keys, append: model, target: …)",
        broadcast_prepend_to_each: "broadcast_to(each: keys, prepend: model, target: …)",
        broadcast_remove_to_each: "broadcast_to(each: keys, remove: model)"
      }.freeze

      # Every class that includes Streamable, so the engine can flush their
      # memoized view contexts on a Rails code reload (dev) in one pass. A
      # WeakMap used as a set (the class is the key) so a class reloaded by
      # Zeitwerk in dev is GC'd normally — a strong Array would pin every
      # reloaded generation and leak across reloads. Guarded by a mutex;
      # registration happens at class-load time, the reset iterates under lock.
      @registry = ObjectSpace::WeakMap.new
      @registry_mutex = Mutex.new

      class << self
        # Reset every streamable class's cached view context + builder. Called
        # from the engine's reloader (config.to_prepare) so a reloaded renderer
        # controller is never served from a stale memo. No-op outside Rails.
        def reset_all_view_contexts!
          @registry_mutex.synchronize do
            @registry.each_key(&:reset_turbo_view_context!)
          end
        end

        def register(klass)
          @registry_mutex.synchronize { @registry[klass] = true }
        end

        # A point-in-time snapshot of every registered streamable class, taken
        # under the registry lock (the doctor iterates it — issue #106). Returns
        # a plain Array so callers never hold the live WeakMap or the lock while
        # working; a class GC'd later simply won't appear next time. Call
        # Rails.application.eager_load! FIRST if you need every app class loaded —
        # the WeakMap only holds classes that have actually been loaded.
        def registered_classes
          @registry_mutex.synchronize do
            classes = []
            @registry.each_key { classes << it }
            classes
          end
        end

        # The ONE broadcast implementation shared by the class-level
        # Streamable.broadcast_to and the module-level Phlex::Reactive.broadcast_to
        # (issue #185). `owner` is the Streamable class (for the instrument name +
        # its build/render seam); `component` is the built payload (nil for :js);
        # `keys` is a list of key-part arrays (one per fan-out key). Renders ONCE
        # (instrumented → render.phlex_reactive) and loops the cheap channel call
        # per key, all wrapped in the broadcast.phlex_reactive event + the pgbus
        # thread-local path (so exclude:/visible_to: reach pgbus and Action Cable
        # no-ops). Self-targeting verbs derive the target from the component's #id
        # and REQUIRE a Streamable payload; container verbs need an explicit target.
        def broadcast_component(owner, verb, payload, component, keys, morph:, target:, exclude:, visible_to:,
                                effect: nil, coalesce: nil)
          if verb == :js && !effect.nil?
            raise ArgumentError,
              "broadcast_to js: takes no effect: — effects animate element streams (replace/update/" \
              "append/prepend/remove), not client-op dispatches"
          end
          resolved_target = resolve_broadcast_target(verb, component, payload, target)
          # The instrumentation + pgbus thread-locals are owned HERE so the
          # class-level and module-level (plain-component) forms share ONE path
          # and neither is silently un-instrumented (issue #185). The js ops
          # serializer lives HERE too (issue #228): when it was a private method
          # on the includer class, the module-level owner (the Streamable module
          # itself) crashed with NoMethodError instead of refusing — the
          # actor-only gate must be reachable from BOTH broadcast doors.
          component_name = component ? component.class.name : owner.name
          Phlex::Reactive.instrument(
            "broadcast", { component: component_name, stream_action: BROADCAST_VERBS[verb], streamables: keys.size }
          ) do
            with_pgbus_broadcast_opts(exclude:, visible_to:, coalesce:) do
              # A broadcast render NEVER inherits the actor's url_options (issue
              # #232): this call may run inside an action request (where the
              # endpoint threaded the actor's host), but subscribers can be on
              # different hosts — absolute URLs in broadcast-rendered components
              # keep the process defaults, so "host-relative URLs" stays the
              # broadcast contract. Off-request callers pay one nil-write pair.
              html = verb == :js ? nil : Phlex::Reactive.with_url_options(nil) { render_broadcast_html(component) }
              ops_json = verb == :js ? broadcast_js_ops_json(payload) : nil
              keys.each { dispatch_broadcast(verb, it, resolved_target, html, ops_json, morph, effect) }
            end
          end
        end

        # Broadcast ALREADY-RENDERED html (issue #248) — no component to build or
        # render. The count companion is a plain number, not a component, so it
        # has no render leg; everything else (instrumentation, the pgbus
        # thread-locals, the per-key dispatch) is identical to
        # broadcast_component.
        def broadcast_raw(owner, verb, target, html, keys, exclude: nil, visible_to: nil, coalesce: nil)
          Phlex::Reactive.instrument(
            "broadcast", { component: owner.name, stream_action: BROADCAST_VERBS[verb], streamables: keys.size }
          ) do
            with_pgbus_broadcast_opts(exclude:, visible_to:, coalesce:) do
              keys.each { dispatch_broadcast(verb, it, target, html, nil, false, nil) }
            end
          end
        end

        # Validate + serialize broadcast ops: reject actor-only ops (focus steals
        # focus in every tab; submit force-submits every subscriber's form;
        # paste_into reads every subscriber's clipboard) and an empty chain (a
        # dead broadcast), then return the JSON wire form. Works on a JS chain
        # (inspect .ops) and a raw array. Lives on the module singleton — the
        # ONE enforcement point both broadcast doors funnel through.
        def broadcast_js_ops_json(ops)
          pairs = ops.is_a?(Phlex::Reactive::JS) ? ops.ops : Array(ops)
          refused = pairs.map { |name, _| name.to_s } & Phlex::Reactive::Streamable::BROADCAST_REFUSED_OPS
          unless refused.empty?
            raise ArgumentError,
              "broadcast_to(js:) refuses actor-only op(s) #{refused.join(", ")} — broadcasting focus " \
              "steals it in every subscriber's tab; broadcasting submit force-submits every " \
              "subscriber's form; broadcasting paste_into reads every subscriber's clipboard. " \
              "These are actor concerns (reply.js / on_client / $ops)."
          end

          Phlex::Reactive::Response.js_ops_json(ops)
        end

        # Render a built component to HTML for a broadcast, ALWAYS instrumented
        # (issue #185): a Streamable renders through its own render_component (which
        # fires render.phlex_reactive); a plain component renders through the module
        # render wrapped in the SAME render event, so neither path is silent.
        def render_broadcast_html(component)
          if component.is_a?(Phlex::Reactive::Streamable)
            component.class.render_component(component)
          else
            Phlex::Reactive.instrument(
              "render", { component: component.class.name }
            ) { Phlex::Reactive.render(component) }
          end
        end

        # Set the pgbus broadcast thread-locals for the block, gated on
        # pgbus_streams? — the SAME capability-gated path the class-level
        # instrument_broadcast uses (issue #185/#187). Duplicated at module level so
        # the shared broadcast_component owns its transport threading. On Action
        # Cable / old pgbus this is a pure `yield`.
        # `coalesce:` (issue #248) rides the SAME thread-local convention. Unlike
        # a kwarg, an unknown thread-local is silently IGNORED by a pgbus that
        # does not forward it (pre-zoolutions/pgbus#465) — so setting it is
        # always safe: an old pgbus just does not coalesce (more messages, same
        # correctness), a new one does. That is why there is no capability gate
        # here beyond the existing pgbus_streams? one.
        def with_pgbus_broadcast_opts(exclude:, visible_to:, coalesce: nil)
          return yield unless Phlex::Reactive.pgbus_streams?

          prev_exclude = Thread.current[:pgbus_broadcast_exclude]
          prev_visible = Thread.current[:pgbus_broadcast_visible_to]
          prev_coalesce = Thread.current[:pgbus_broadcast_coalesce]
          Thread.current[:pgbus_broadcast_exclude] = exclude
          Thread.current[:pgbus_broadcast_visible_to] = visible_to
          Thread.current[:pgbus_broadcast_coalesce] = coalesce
          yield
        ensure
          if Phlex::Reactive.pgbus_streams?
            Thread.current[:pgbus_broadcast_exclude] = prev_exclude
            Thread.current[:pgbus_broadcast_visible_to] = prev_visible
            Thread.current[:pgbus_broadcast_coalesce] = prev_coalesce
          end
        end

        # Resolve the DOM target for a broadcast (issue #185): a self-targeting
        # verb (replace/remove) uses the component's #id and REQUIRES a Streamable
        # payload (the #id contract) — a plain component gets a guided error steering
        # to update:; a container verb (update/append/prepend) uses the caller's
        # explicit target: (update self-targets a Streamable when no target: given).
        # :js scopes ops by the caller target (nil → document-scoped).
        def resolve_broadcast_target(verb, component, payload, target)
          return target if verb == :js

          streamable = component.is_a?(Phlex::Reactive::Streamable)
          if BROADCAST_SELF_TARGETING.include?(verb) || (verb == :update && target.nil?)
            unless streamable
              raise ArgumentError,
                "broadcast_to #{verb}: needs a Streamable payload (its #id is the target). A plain " \
                "component #{payload.class} has no #id — use update: with an explicit target:."
            end
            return component.id
          end
          raise ArgumentError, "broadcast_to #{verb}: needs a target: (the container element's id)." unless target

          target
        end

        # Route ONE key to its Turbo::StreamsChannel call for the verb (issue #185).
        # exclude:/visible_to: are NOT passed here — they ride the pgbus thread-locals
        # set by with_pgbus_broadcast_opts (turbo-rails would swallow them as kwargs).
        # `effect` (issue #215) rides the same attributes: seam morph does — every
        # broadcast_*_to delegates to broadcast_action_to(attributes:), so the attr
        # lands on the <turbo-stream> element on every verb.
        def dispatch_broadcast(verb, key, target, html, ops_json, morph, effect = nil)
          parts = Array(key)
          wire = broadcast_wire(morph, effect)
          case verb
          when :replace then ::Turbo::StreamsChannel.broadcast_replace_to(*parts, target:, html:, **wire)
          when :update then ::Turbo::StreamsChannel.broadcast_update_to(*parts, target:, html:, **wire)
          when :append then ::Turbo::StreamsChannel.broadcast_append_to(*parts, target:, html:, **wire)
          when :prepend then ::Turbo::StreamsChannel.broadcast_prepend_to(*parts, target:, html:, **wire)
          when :remove then ::Turbo::StreamsChannel.broadcast_remove_to(*parts, target:, **wire)
          when :js
            # Issue #237: the broadcast op stream carries the verbose gate too
            # (same server env for every subscriber of this payload).
            data = { reactive_ops: ops_json }
            data[:reactive_verbose] = "true" if Phlex::Reactive.verbose_errors
            ::Turbo::StreamsChannel.broadcast_action_to(
              *parts, action: "reactive:js", target:, attributes: { data: }, render: false
            )
          end
        end

        # The ONE broadcast attributes compiler (issue #185, extended #215): the
        # broadcast path emits extra <turbo-stream> attributes via `attributes:`
        # (it has no `method:` kwarg) — method="morph" and/or the per-call
        # data-reactive-effect. {} when neither, so the plain call's wire is
        # byte-identical. (Replaces morph_wire.)
        def broadcast_wire(morph, effect = nil)
          return {} if !morph && effect.nil?

          attrs = {}
          attrs[:method] = "morph" if morph
          attrs[:data] = { reactive_effect: Phlex::Reactive::Effects.wire_value(effect) } unless effect.nil?
          { attributes: attrs }
        end

        # Split the single verb kwarg out of the module-level broadcast_to's **verb
        # (issue #185) — public counterpart of the class-level extract_broadcast_verb.
        def extract_module_broadcast_verb(verb)
          unless verb.size == 1 && BROADCAST_VERBS.key?(verb.keys.first)
            raise ArgumentError,
              "broadcast_to needs exactly ONE verb kwarg (#{BROADCAST_VERBS.keys.join("/")}), got #{verb.keys.inspect}"
          end

          verb.first
        end
      end

      included do
        Phlex::Reactive::Streamable.register(self)
      end

      class_methods do
        # The keyword the positional model maps to in `initialize`. For a
        # record-backed component (Component#reactive_record), this is the SAME
        # keyword the action endpoint uses in `from_identity` — so one
        # `initialize(<record>:)` satisfies BOTH the click path and the
        # broadcast path. Otherwise it falls back to the demodulized, underscored
        # class name (Invoice -> :invoice, InvoiceItem -> :invoice_item).
        # Override when it differs.
        def model_param_name
          if respond_to?(:reactive_record_key) && reactive_record_key
            reactive_record_key
          else
            name.demodulize.underscore.to_sym
          end
        end

        def component_args(model, options)
          { model_param_name => model }.merge(options)
        end

        # Turbo::Streams::TagBuilder needs a real VIEW CONTEXT (it calls
        # `.formats` on it), not a controller class. Build one off-request from
        # the configured renderer controller, bound to a real request so
        # request-dependent helpers (form_authenticity_token, host-aware URL
        # helpers) work during a re-render/broadcast (issue #42). Memoized PER
        # THREAD — building a
        # view context instantiates the renderer controller and assembles its
        # whole helper module set, so doing it per render/broadcast was the
        # hottest server-side allocation in the action round trip. The builder
        # is bound to that one context and reused too.
        #
        # Why per-thread and not one-per-process: an ActionView context carries
        # MUTABLE state (output_buffer/view_flow that #render_in's capture
        # swaps), so a single instance shared across threads can interleave or
        # bleed content between overlapping renders on a threaded server (Puma)
        # or in concurrent jobs. A thread-local cache keeps the amortization
        # (built once per thread, reused across that thread's renders) without
        # ever sharing a buffer across threads.
        def turbo_stream_builder
          thread_view_context_cache.builder
        end

        # The off-request view context for the current thread, built once and
        # reused. Rebuilt when the configured renderer object changes (a swap of
        # Phlex::Reactive.renderer) or when the class's view-context generation
        # is bumped (reset_turbo_view_context! / Rails code reload), so a
        # reloaded controller class is never served stale.
        def turbo_view_context
          thread_view_context_cache.view_context
        end

        # Invalidate the cached view context + builder for ALL threads by bumping
        # this class's generation — each thread rebuilds lazily on its next use,
        # and entries for the old generation are dropped. Registered on Rails'
        # reloader by the engine; also used by specs. Thread-safe (an integer
        # bump; no shared mutable structure to tear down).
        def reset_turbo_view_context!
          @turbo_view_context_generation = turbo_view_context_generation + 1
        end

        def turbo_view_context_generation
          @turbo_view_context_generation ||= 0
        end

        # Render a component to HTML with a full Rails view context. Uses
        # phlex-rails' #render_in against our memoized off-request view context
        # — a direct component.call that skips ActionController's renderer.render
        # machinery (TemplateRenderer, LookupContext, the render log subscriber):
        # ~2x faster with ~half the allocations, and byte-identical HTML. The
        # view context still carries the full Rails helper set, so
        # dom_id/url_for/t()/csrf keep working during a re-render or broadcast.
        def render_component(component)
          # render.phlex_reactive (issue #107): the pure render cost — the unit
          # an APM most wants (broadcast fan-out renders once per stream key).
          # Payload carries the component NAME + html bytesize ONLY. bytesize is
          # known only after rendering, so we mutate the payload inside the block.
          event = { component: name, bytesize: 0 }
          Phlex::Reactive.instrument("render", event) do
            # Machinery renders are REAL (issue #165): a reactive_lazy component
            # emits its actual template here — the lazy shell is for the
            # page-embedded initial mount only. Two fiber-local writes; the
            # render bench holds flat.
            html = Phlex::Reactive::Defer.with_real_render { component.render_in(turbo_view_context) }
            event[:bytesize] = html.bytesize
            html
          end
        end

        # `morph: true` emits `<turbo-stream action="replace" method="morph">` so
        # Turbo 8's bundled Idiomorph morphs the subtree in place — preserving a
        # focused <input> + caret — instead of an outerHTML swap (issue #28).
        # Default (morph: false) is the unchanged plain replace.
        # Wrapped in a Phlex::Reactive::Stream (issue #114) so the endpoint reads
        # action/target/token-ness structurally. renders_root: true — a replace
        # re-renders the component's own root (carrying its fresh token); wire
        # bytes are byte-identical.
        # `effect:` (issue #215) — the PER-CALL effect override, stamped as
        # data-reactive-effect on the <turbo-stream> element (false → "off").
        # nil (the default) leaves the wire byte-identical. Same on every
        # builder below.
        def replace(model = nil, morph: false, effect: nil, **options)
          component = build(model, options)
          Phlex::Reactive::Stream.wrap(
            Phlex::Reactive::Effects.annotate(
              turbo_stream_builder.replace(component.id, html: render_component(component), **morph_method(morph)),
              effect
            ),
            action: "replace", target: component.id, renders_root: true
          )
        end

        # `morph: true` emits `<turbo-stream action="update" method="morph">` so
        # Turbo 8 morphs the inner HTML in place instead of replacing it (issue
        # #113) — a cross-tab update no longer clobbers a peer's focus/caret.
        # Default (morph: false) is the unchanged plain update.
        def update(model = nil, morph: false, effect: nil, **options)
          component = build(model, options)
          Phlex::Reactive::Stream.wrap(
            Phlex::Reactive::Effects.annotate(
              turbo_stream_builder.update(component.id, html: render_component(component), **morph_method(morph)),
              effect
            ),
            action: "update", target: component.id, renders_root: true
          )
        end

        # renders_root: false — append inserts a CHILD into `target`; even when
        # the appended component carries its OWN token, that must never count as
        # the container's own refresh (issue #44).
        def append(target:, model: nil, effect: nil, **options)
          component = build(model, options)
          Phlex::Reactive::Stream.wrap(
            Phlex::Reactive::Effects.annotate(
              turbo_stream_builder.append(target, html: render_component(component)),
              effect
            ),
            action: "append", target: target, renders_root: false
          )
        end

        def prepend(target:, model: nil, effect: nil, **options)
          component = build(model, options)
          Phlex::Reactive::Stream.wrap(
            Phlex::Reactive::Effects.annotate(
              turbo_stream_builder.prepend(target, html: render_component(component)),
              effect
            ),
            action: "prepend", target: target, renders_root: false
          )
        end

        def remove(model = nil, effect: nil, **options)
          component = build(model, options)
          Phlex::Reactive::Stream.wrap(
            Phlex::Reactive::Effects.annotate(turbo_stream_builder.remove(component.id), effect),
            action: "remove", target: component.id, renders_root: false
          )
        end

        # --- Broadcasts (server -> client over the stream transport) ---
        # With pgbus installed, Turbo::StreamsChannel broadcasts route over
        # Postgres SSE instead of Action Cable, transactionally.
        #
        # Pass RAW key parts as *streamables (e.g. broadcast_append_to(@list, :items))
        # or (model, :symbol). Do NOT pass a pre-built stream key string — the
        # broadcaster builds the key itself, and double-keying can trip the
        # transport's separator guard.

        # `exclude:` / `visible_to:` are TRANSPORT options forwarded to the
        # stream (pgbus), not component init args. `exclude:` is the actor's
        # connection id — pass it to suppress the actor's own echo (the actor
        # already got the action's HTTP response). With Action Cable these are
        # ignored; with pgbus they reach the dispatcher. See docs/broadcasting.
        # `morph: true` makes the live cross-tab update morph in place (issue #28),
        # so a peer tab keeps its focus/caret on the morphed row. The broadcast
        # path takes EXTRA <turbo-stream> attributes via `attributes:` (not the
        # TagBuilder's `method:` kwarg), so the morph flag rides there.
        # Each broadcast_*_to wraps its body in a broadcast.phlex_reactive event
        # (issue #107) via instrument_broadcast — the stream action + streamables
        # COUNT + component name, never the model/state. The event fires on BOTH
        # transports (Action Cable AND pgbus): it wraps this class-method body,
        # which is the same on either, so pgbus optionality is preserved.
        # ONE broadcast method (issue #185) — the verb is a KWARG whose value is
        # the payload, replacing the 11 broadcast_*_to / _to_each methods:
        #
        #   Item.broadcast_to(@list, :todos, replace: @todo, morph: true)   # self-target
        #   Item.broadcast_to(@list, :todos, append: todo, target: dom_id(@list, :todos),
        #     exclude: reactive_connection_id)
        #   Badge.broadcast_to(user, :alerts, js: js.add_class("#bell", "has-unread"))
        #   Counter.broadcast_to(each: accounts.map { [it, :counters] }, replace: counter)
        #   ChatComposer.broadcast_to("chat", room, update: { room:, author: })  # Hash = init kwargs
        #
        # Exactly ONE verb kwarg — replace:/update:/append:/prepend:/remove:/js:.
        # The payload is a record (built via model_param_name), an init-kwargs Hash
        # (verbatim — no **options collision), or a built Phlex component. `each:`
        # (an enumerable of stream keys) fans ONE render out to K keys (1 build + 1
        # render + 1 signing + K cheap channel calls); otherwise *streamables is the
        # single key. `morph:` applies to replace/update. `exclude:`/`visible_to:`
        # thread to pgbus via the capability-gated instrument_broadcast path; on
        # Action Cable they no-op. The class-level and module-level (Phlex::Reactive.
        # broadcast_to) forms share broadcast_component (below).
        def broadcast_to(*streamables, morph: false, target: nil, exclude: nil, visible_to: nil, each: nil,
                         effect: nil, **verb)
          name, payload = extract_broadcast_verb(verb)
          component = name == :js ? nil : coerce_broadcast_payload(payload)
          keys = each ? each.map { Array(it) } : [streamables]
          Phlex::Reactive::Streamable.broadcast_component(
            self, name, payload, component, keys, morph:, target:, exclude:, visible_to:, effect:
          )
        end

        # Broadcast a collection DELTA — the row PLUS the count companion PLUS
        # the 0<->1 empty-state toggle (issue #248), the broadcast-side
        # counterpart of reply.append / reply.remove.
        #
        #   Container.broadcast_collection_to(@list, :todos,
        #     container: @list_component, append: todo, in: :todos,
        #     exclude: reactive_connection_id)
        #
        # broadcast_to(append:) deliberately emits the BARE row: it has no
        # container instance, so it cannot resolve the declaration or run the
        # size resolver. This verb takes that instance as `container:` and runs
        # the SAME Phlex::Reactive::Collections decisions the reply path runs,
        # so a peer's list stays as correct as the actor's.
        #
        # `in:` names the declared reactive_collection; the verb is `append:`,
        # `prepend:` or `remove:` (exactly one). `exclude:`/`visible_to:` thread
        # to pgbus as everywhere else.
        #
        # `row:` is the row component's extra init kwargs (issue #186's row_kwargs
        # on the reply side) — pass the SAME ones the actor got, or a peer whose
        # row component has a required kwarg raises instead of rendering.
        #
        # `coalesce:` (a window in ms, or true) applies to the AGGREGATE streams
        # only — the count companion and the empty-state toggle are idempotent
        # replaces of stable targets, so a 177-row fan-out collapses to a
        # handful of count refreshes. The ROW stream is NEVER coalesced: an
        # append is not idempotent and each row is a distinct target. Needs
        # pgbus with zoolutions/pgbus#465; on anything older the thread-local is
        # ignored and every aggregate stream simply goes out (correct, chattier).
        # (`in:` is a Ruby keyword, so it cannot be a named parameter — it is
        # pulled out of **opts, which then holds exactly the verb kwarg.)
        def broadcast_collection_to(*streamables, container:, exclude: nil, visible_to: nil,
                                    coalesce: nil, effect: nil, row: {}, **opts)
          name = opts.delete(:in) ||
                 raise(ArgumentError, "broadcast_collection_to needs in: :collection_name")
          action, model = extract_collection_verb(opts)
          definition = Phlex::Reactive::Collections.definition!(container, name)
          keys = [streamables]

          broadcast_collection_row(definition, action, model, keys, exclude:, visible_to:, effect:, row:)
          broadcast_collection_aggregates(definition, container, action, keys, exclude:, visible_to:, coalesce:)
        end

        # Define the guided-error stub for each removed broadcast method (issue
        # #185). `verb` is referenced in define_method AND the message, so the outer
        # block param must be named — `it` is illegal here.
        # rubocop:disable-next Style/ItBlockParameter
        Phlex::Reactive::Streamable::REMOVED_BROADCASTS.each_key do |verb|
          define_method(verb) do |*, **|
            raise NoMethodError,
              "#{name}.#{verb} was removed in issue #185 — " \
              "use #{name}.#{Phlex::Reactive::Streamable::REMOVED_BROADCASTS[verb]}"
          end
        end

        private

        # Split the single verb kwarg (replace:/update:/…) out of **verb, raising
        # for zero or more than one — exactly one verb per broadcast_to call.
        def extract_broadcast_verb(verb)
          unless verb.size == 1 && BROADCAST_VERBS.key?(verb.keys.first)
            raise ArgumentError,
              "broadcast_to needs exactly ONE verb kwarg (#{BROADCAST_VERBS.keys.join("/")}), got #{verb.keys.inspect}"
          end

          verb.first
        end

        # The collection verb split — append:/prepend:/remove:, exactly one.
        def extract_collection_verb(verb)
          unless verb.size == 1 && COLLECTION_VERBS.include?(verb.keys.first)
            raise ArgumentError,
              "broadcast_collection_to needs exactly ONE verb kwarg " \
              "(#{COLLECTION_VERBS.join("/")}), got #{verb.keys.inspect}"
          end

          verb.first
        end

        # The ROW leg: routed through the ordinary broadcast_to so the row is
        # built, rendered and instrumented exactly like every other broadcast.
        # Never coalesced (distinct targets; an append is not idempotent).
        #
        # A STRING model is an already-built dom id, the same form
        # reply.remove(id, from:) and Collections.row_remove_stream accept.
        # Building a row component from it would hand the id to the component's
        # initializer as if it were a record — so it short-circuits to a raw
        # remove of that target instead.
        def broadcast_collection_row(definition, action, model, keys, exclude:, visible_to:, effect:, row: {})
          if action == :remove
            if model.is_a?(::String)
              return Phlex::Reactive::Streamable.broadcast_raw(
                definition.item, :remove, model, nil, keys, exclude:, visible_to:
              )
            end

            return Phlex::Reactive::Streamable.broadcast_component(
              definition.item, :remove, model, definition.item.send(:build, model, row), keys,
              morph: false, target: nil, exclude:, visible_to:, effect:
            )
          end

          Phlex::Reactive::Streamable.broadcast_component(
            definition.item, action, model, definition.item.send(:build, model, row), keys,
            morph: false, target: definition.container, exclude:, visible_to:, effect:
          )
        end

        # The AGGREGATE leg: the count companion and the empty-state toggle,
        # both idempotent replaces of stable targets — so both carry `coalesce:`.
        def broadcast_collection_aggregates(definition, container, action, keys, exclude:, visible_to:, coalesce:)
          delta = action == :remove ? :remove : :add
          # Resolve the size ONCE (it is usually a DB count) and hand the same
          # value to both decisions — see Collections.size_of.
          size = Phlex::Reactive::Collections.size_of(definition, container)

          if (refresh = Phlex::Reactive::Collections.count_refresh(definition, container, size))
            # NOT `target, size = refresh` — that would rebind `size` to the
            # count's STRING form and hand a String to empty_toggle below.
            count_target, count_html = refresh
            Phlex::Reactive::Streamable.broadcast_raw(
              self, :update, count_target, count_html, keys, exclude:, visible_to:, coalesce:
            )
          end

          case Phlex::Reactive::Collections.empty_toggle(definition, container, delta, size)
          when :clear
            Phlex::Reactive::Streamable.broadcast_component(
              definition.empty, :remove, nil, definition.empty.new, keys,
              morph: false, target: nil, exclude:, visible_to:, coalesce:
            )
          when :restore
            Phlex::Reactive::Streamable.broadcast_component(
              definition.empty, :append, nil, definition.empty.new, keys,
              morph: false, target: definition.container, exclude:, visible_to:, coalesce:
            )
          end
        end

        # Coerce a verb payload into a built component: a Phlex component passes
        # through (issue #185 — built payloads); a Hash is init kwargs verbatim (no
        # **options collision); anything else is the record built via
        # model_param_name. nil builds argument-free (a state-backed default).
        def coerce_broadcast_payload(payload)
          case payload
          when ::Phlex::SGML then payload
          when Hash then new(**payload)
          else build(payload, {})
          end
        end

        # Wrap a broadcast_*_to body in a broadcast.phlex_reactive event (issue
        # #107) AND thread the pgbus transport opts (issue #187). Payload: the
        # component NAME, the Turbo stream action, and the streamables COUNT —
        # never the model/state. Fires on both transports because it wraps the
        # shared class-method body. Returns the block's value (the broadcast
        # result) so callers are unaffected.
        #
        # exclude:/visible_to: (issue #187): pgbus reads these from thread-locals
        # (Thread.current[:pgbus_broadcast_exclude]/_visible_to), which its
        # Turbo::StreamsChannel#broadcast_stream_to patch consults — NOT from the
        # broadcast_*_to kwargs (turbo-rails swallows unknown kwargs into its
        # render locals, so passing exclude: as a kwarg to StreamsChannel silently
        # drops it: the actor-echo suppression never fired on pgbus). We set the
        # thread-locals around the broadcast (capability-gated on pgbus_streams?)
        # and clear them in ensure. On Action Cable there is no such thread-local
        # reader, so this is a no-op there — pgbus optionality preserved.
        # (issue #185: instrument_broadcast + the class-level with_pgbus_broadcast_opts
        # were folded into the shared Streamable.broadcast_component — ONE
        # instrumentation + pgbus-threading path for the class-level and module-level
        # broadcast_to, so the transport logic has exactly one spelling.)

        def build(model, options)
          new(**(model ? component_args(model, options) : options))
        end

        # The TagBuilder (the .replace class builder + to_stream_morph) takes
        # `method: :morph` to emit the `method="morph"` attribute. Pass it ONLY
        # when morphing, so the default call produces today's plain replace.
        def morph_method(morph)
          morph ? { method: :morph } : {}
        end

        # (The broadcast path's extra-attribute wire lives in
        # Streamable.broadcast_wire — the single compiler both the class-level
        # and module-level broadcast_to share; issue #185, extended #215.)

        def renderer
          Phlex::Reactive.renderer
        end

        def thread_view_context_cache
          store = (Thread.current[:phlex_reactive_view_contexts] ||= {})
          current = renderer
          generation = turbo_view_context_generation
          cached = store[self]

          unless cached && cached.renderer.equal?(current) && cached.generation == generation
            view_context = Phlex::Reactive.request_bound_view_context(current)
            cached = ThreadViewContext.new(
              view_context,
              ::Turbo::Streams::TagBuilder.new(view_context),
              current,
              generation
            )
            store[self] = cached
          end
          cached
        end
      end

      # The stable DOM id used as the Turbo Stream target. It MUST match the id
      # set on the component's root element in `view_template`.
      #
      # Record-backed components (Component's `reactive_record :x`) get a
      # default for free: dom_id(record) — the id virtually every such
      # component wrote by hand (issue #81). An explicit `def id` always wins
      # via normal method lookup. Everything else (state-backed, a bare
      # Streamable) still raises: a class-name default would silently collide
      # the moment two instances render on one page. Two DIFFERENT component
      # classes rendering the SAME record on one page also collide on the
      # default — give one a prefixed id: `def id = dom_id(@todo, "rich")`.
      #
      # Called on every render/stream build, so the default stays lean: a
      # respond_to? (reactive_record_key is Component API — a bare Streamable
      # keeps raising) plus ivar reads via the memoized reactive_record_ivar.
      def id
        klass = self.class
        if klass.respond_to?(:reactive_record_key) && (record_ivar = klass.reactive_record_ivar) &&
           (record = instance_variable_get(record_ivar))
          return dom_id(record)
        end

        raise NotImplementedError,
          "#{klass} must implement #id (the stable DOM id Turbo Streams target) — add e.g. " \
          "`def id = \"my-thing\"`. Record-backed components (reactive_record :x) get " \
          "`dom_id(record)` as the default automatically."
      end

      # Render-context-free dom_id, safe to use inside `#id`. The streamable
      # machinery calls `#id` BEFORE rendering, so Phlex's render-time `dom_id`
      # helper would raise HelpersCalledBeforeRenderError. This delegates to
      # ActionView::RecordIdentifier, which works anywhere — so
      # `def id = dom_id(@todo)` is safe.
      def dom_id(record, prefix = nil)
        ::ActionView::RecordIdentifier.dom_id(record, prefix)
      end

      # Render THIS already-built instance as a replace stream (used by the
      # reactive action endpoint after an action mutated state). Wrapped in a
      # Phlex::Reactive::Stream (issue #114) so the endpoint reads the action /
      # target / token-ness structurally instead of regexing the markup; the wire
      # bytes are byte-identical.
      # `morph: true` emits `<turbo-stream action="replace" method="morph">`
      # (issue #28): Turbo 8's bundled Idiomorph morphs the subtree in place —
      # preserving the focused <input> + caret across the re-render — while still
      # carrying the root's fresh data-reactive-token-value (so the signed token
      # refreshes). Default (morph: false) is the plain outerHTML replace,
      # byte-identical to before. Used by reply.replace / reply.morph. The morph:
      # kwarg replaces the deleted to_stream_morph (issue #185).
      # `effect:` (issue #215) — the per-call effect override on the actor's
      # own reply stream, same wire as the class builders (nil = untouched).
      def to_stream_replace(morph: false, effect: nil)
        builder = self.class.turbo_stream_builder
        html = self.class.render_component(self)
        rendered = morph ? builder.replace(id, html:, method: :morph) : builder.replace(id, html:)
        rendered = Phlex::Reactive::Effects.annotate(rendered, effect)
        Phlex::Reactive::Stream.wrap(rendered, action: "replace", target: id, renders_root: true)
      end

      # Issue #185: to_stream_morph is removed — the morph flag is a kwarg now.
      # Guided error → to_stream_replace(morph: true).
      def to_stream_morph
        raise NoMethodError,
          "to_stream_morph was removed in issue #185 — use to_stream_replace(morph: true)"
      end

      # `morph: true` emits `<turbo-stream action="update" method="morph">`
      # (issue #113) so Turbo 8 morphs the inner HTML in place, preserving a
      # focused <input> + caret across a per-field update. Default (morph:
      # false) is the unchanged plain update. Passing `method: :morph` inline
      # (as #to_stream_morph does) keeps the plain call's wire byte-identical.
      # Used by reply.update.
      def to_stream_update(morph: false, effect: nil)
        builder = self.class.turbo_stream_builder
        html = self.class.render_component(self)
        rendered = morph ? builder.update(id, html:, method: :morph) : builder.update(id, html:)
        rendered = Phlex::Reactive::Effects.annotate(rendered, effect)
        Phlex::Reactive::Stream.wrap(rendered, action: "update", target: id, renders_root: true)
      end

      # Render a TOKEN-ONLY refresh stream (issue #30): a tiny
      # `<turbo-stream action="reactive:token">` carrying the component's fresh
      # signed token, with NO rendered body. It lets an action update only PART
      # of a component (its own hand-built streams) while still rolling the
      # signed identity token forward — the client reads the next token from this
      # attribute (#extractToken) and an inert client action writes it onto the
      # root (a pure attribute set, so a focused <input> + caret survive). Unlike
      # to_stream_replace, it does NOT re-render the children, so a live input
      # the user is typing into is never torn down. Used by reply.streams.
      #
      # The component carries its token via Component#reactive_token; a Streamable
      # that isn't a Component (no token) simply has nothing to refresh — guarded
      # by respond_to? so the primitive stays usable on a bare Streamable.
      #
      # respond_to? MUST include private methods (the `true` arg): Component
      # defines `reactive_token` as PRIVATE, so a plain `respond_to?(:reactive_token)`
      # is false for every Component and the stream silently carries an EMPTY token —
      # which makes any non-self-rendering reply (reply.streams #30, reply.append /
      # reply.remove #35) add-once-only: the first action works, then the stale (here
      # empty) token is rejected on the next dispatch (cosmos#1939). A bare Streamable
      # has no reactive_token method at all, so it still returns false correctly.
      def to_stream_token
        token = respond_to?(:reactive_token, true) ? reactive_token : nil
        html = %(<turbo-stream action="reactive:token" target="#{ERB::Util.html_escape(id)}" data-reactive-token-value="#{ERB::Util.html_escape(token)}"></turbo-stream>)
        # Both interpolations are ERB::Util.html_escape'd, so .html_safe is a
        # byte-identical relabel. renders_root: true — reactive:token IS a
        # self-render for token purposes (it's in SELF_RENDER_ACTIONS) — unifies
        # the actor's own token stream onto the structural path (issue #114).
        Phlex::Reactive::Stream.wrap(html.html_safe, action: "reactive:token", target: id, renders_root: true)
      end

      # Render THIS instance as a remove stream. The component already knows its
      # own #id, so no record/class reconstruction is needed (works for record-
      # and state-backed components alike). Used by reply.remove.
      def to_stream_remove(effect: nil)
        Phlex::Reactive::Stream.wrap(
          Phlex::Reactive::Effects.annotate(self.class.turbo_stream_builder.remove(id), effect),
          action: "remove", target: id, renders_root: false
        )
      end
    end
  end
end
