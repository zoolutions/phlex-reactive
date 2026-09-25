# frozen_string_literal: true

module Phlex
  module Reactive
    # Public test helpers for downstream apps (issue #110). Livewire ships
    # `Livewire::test(...)`; this is the phlex-reactive equivalent — a public
    # surface so an app never reaches for the PRIVATE `component.send(:reactive_token)`
    # or hand-rolls the POST headers the docs used to teach.
    #
    # Mix it in from your rails_helper:
    #
    #   RSpec.configure do |c|
    #     c.include Phlex::Reactive::TestHelpers, type: :request  # HTTP helpers
    #     c.include Phlex::Reactive::TestHelpers                   # + the no-HTTP driver
    #   end
    #
    # The HTTP helpers (post_reactive_action/post_reactive_multipart) need Rails'
    # integration `post`, so they belong in `type: :request` examples. The no-HTTP
    # driver (run_reactive) and token minting work anywhere.
    #
    # The driver goes THROUGH the endpoint's security contract on purpose —
    # default-deny, signed identity round-trip (record re-find), schema coercion,
    # the same transaction wrapper. A helper that skipped it would teach users to
    # test a component that would fail at the real endpoint.
    #
    # NB: `verbose_errors` defaults ON in the test env (Rails.env.local? — issue
    # #82). It only changes an endpoint FAILURE body (never a status), so it does
    # not affect these helpers' happy path; a downstream app asserting an empty
    # failure body may want `Phlex::Reactive.verbose_errors = false` in its setup.
    module TestHelpers
      # Raised by run_reactive when the action is not declared with `action
      # :name`. The endpoint answers this with a 403 (default-deny); the driver
      # raises so a unit test asserts the contract directly. A dedicated class
      # (not a bare ArgumentError) so `raise_error(UndeclaredReactiveAction)` is
      # unambiguous.
      class UndeclaredReactiveAction < Phlex::Reactive::Error; end

      # Mint an identity token exactly as a component would.
      #   * CLASS form  — the already-public sign path: Phlex::Reactive.sign(
      #     payload.merge("c" => klass.name)). Pass the identity pieces yourself
      #     ("gid" => record.to_gid.to_s, "s" => {...}) when you need them.
      #   * INSTANCE form — wraps the component's PRIVATE #reactive_token, so the
      #     token carries the instance's live record/state with no hand-assembly.
      def reactive_token_for(component_or_class, payload = {})
        if component_or_class.is_a?(::Class)
          Phlex::Reactive.sign(payload.merge("c" => component_or_class.name))
        else
          component_or_class.send(:reactive_token)
        end
      end

      # POST a reactive action as the client's JSON body (token + act + params) to
      # Phlex::Reactive.action_path — NEVER a hardcoded "/reactive/actions", so a
      # remounted path (the gem warns about shadowed paths) is honored. Accepts a
      # component INSTANCE or a CLASS + explicit `payload:` (the identity pieces).
      def post_reactive_action(component_or_class, act, params: {}, payload: {})
        token = reactive_action_token(component_or_class, payload)
        post Phlex::Reactive.action_path,
          params: { token:, act:, params: }.to_json,
          headers: { "Content-Type" => "application/json", "Accept" => "text/vnd.turbo-stream.html" }
      end

      # POST a reactive action as multipart FormData (the client's encoding when a
      # `:file` param is present, issue #34): token + act flat, params bracketed.
      # No JSON Content-Type — Rails' test `post` builds the multipart body from
      # the nested Hash (files ride as UploadedFile values).
      #
      # `empty_groups:` names the `[]` groups the client cleared (issue #258). A
      # form body cannot carry an empty array, so the client leaves those keys
      # out and announces them in a field of its own; passing the names here is
      # how a spec reproduces that request. Omit it and the body is exactly what
      # it was before the field existed.
      def post_reactive_multipart(component_or_class, act, params: {}, payload: {}, empty_groups: [])
        token = reactive_action_token(component_or_class, payload)
        body = { token:, act:, params: }
        body[:empty_groups] = empty_groups if empty_groups.present?
        post Phlex::Reactive.action_path, params: body,
          headers: { "Accept" => "text/vnd.turbo-stream.html" }
      end

      # The no-HTTP unit driver. Runs `action` on `component` through the SAME
      # security contract the endpoint enforces, and returns a Result:
      #
      #   1. default-deny — an undeclared action raises UndeclaredReactiveAction.
      #   2. identity round-trip — signs the instance's token, verifies it, and
      #      rebuilds the component via from_identity (re-finding a record-backed
      #      component's row; a stale gid raises ActiveRecord::RecordNotFound, the
      #      endpoint's 404 equivalent). So the action runs against the rebuilt
      #      instance, exactly as it would after a real POST.
      #   3. coercion — params pass through the action's compiled ParamSchema
      #      (issue #109); undeclared keys are dropped, declared ones cast.
      #   4. transaction — run inside the endpoint's transaction wrapper so
      #      after_commit broadcasts behave.
      #   5. authorization — a registered authorization error RAISES (the endpoint
      #      maps it to 403; a unit test asserts the real exception).
      def run_reactive(component, action, **params)
        klass = component.class
        action_def = klass.reactive_actions[action.to_sym] || raise_undeclared(klass, action)

        rebuilt = rebuild_from_identity(component, klass)
        coerced = action_def.schema.coerce(stringify_params(params))

        returned = run_reactive_action(rebuilt, action_def, coerced)
        Result.new(returned:, component: rebuilt)
      end

      private

      # A component instance mints its own token; a class needs the caller's
      # explicit identity payload merged under "c".
      def reactive_action_token(component_or_class, payload)
        if component_or_class.is_a?(::Class)
          reactive_token_for(component_or_class, payload)
        else
          reactive_token_for(component_or_class)
        end
      end

      def raise_undeclared(klass, action)
        declared = klass.reactive_actions.keys.join(", ")
        raise UndeclaredReactiveAction,
          "action :#{action} is not declared on #{klass.name} — declared actions: #{declared}"
      end

      # Round-trip the identity: sign the instance's identity, verify it, rebuild
      # via from_identity — so the driver re-finds a record-backed component's row
      # exactly like the endpoint (and a stale gid raises RecordNotFound).
      #
      # The token captures identity AS OF RENDER TIME: a record-backed component
      # holding a row that was deleted AFTER the page rendered still carries that
      # row's gid — the real stale-token case (the page showed it, then it was
      # destroyed, then the action fired). So we sign the gid from the record's id
      # even when it's already destroyed, then from_identity's GlobalID lookup
      # returns nil and raises RecordNotFound — the endpoint's 404 equivalent.
      # A genuinely NEW (never-persisted) record has no id → no gid, matching
      # reactive_token's own draft contract.
      def rebuild_from_identity(component, klass)
        payload = Phlex::Reactive.verify(reactive_token_for(component))
        klass.from_identity(inject_destroyed_gid(payload, component, klass))
      end

      # Reproduce the stale-token case. #reactive_token omits the gid for a
      # non-persisted record — correct for a live draft, but a DESTROYED record is
      # also non-persisted, and there the page rendered a real gid (while the row
      # lived) that only went stale on deletion. So when the component holds a
      # record that was persisted (has an id) but is now destroyed, inject its gid
      # into the verified payload; from_identity's GlobalID lookup then returns nil
      # and raises RecordNotFound — the endpoint's 404 equivalent. A genuinely NEW
      # record (no id) is untouched.
      def inject_destroyed_gid(payload, component, klass)
        return payload unless payload.is_a?(::Hash) && !payload.key?("gid")

        record_ivar = klass.respond_to?(:reactive_record_ivar) && klass.reactive_record_ivar
        record = record_ivar && component.instance_variable_get(record_ivar)
        return payload unless record.respond_to?(:destroyed?) && record.destroyed? && record.id

        payload.merge("gid" => record.to_gid.to_s)
      end

      # Coerce the caller's kwargs the way the client's params arrive — every value
      # is a string on the wire, so a `:integer` param really is cast, not passed
      # through as a live Integer. Keys are stringified (the schema keys on
      # strings), values deep-stringified so nested/array params coerce too, but
      # UploadedFiles (issue #34) and nil pass through untouched.
      def stringify_params(params)
        params.each_with_object({}) { |(k, v), h| h[k.to_s] = stringify_param_value(v) }
      end

      def stringify_param_value(value)
        case value
        when ::Hash then value.each_with_object({}) { |(k, v), h| h[k.to_s] = stringify_param_value(v) }
        when ::Array then value.map { stringify_param_value(it) }
        when nil then nil
        when ::String, ::Numeric, true, false then value.to_s
        else value # UploadedFile and any other rich object rides through as-is
        end
      end

      # Run inside the endpoint's transaction wrapper. `coerced` already has
      # symbol keys (ParamSchema#coerce symbolizes to splat as kwargs), so we
      # splat it exactly as the endpoint does. Kept tiny and dependency tolerant:
      # no ActiveRecord (a state-only component in a bare app) just yields.
      def run_reactive_action(component, action_def, coerced)
        transaction_wrapper do
          if coerced.any?
            component.public_send(action_def.name, **coerced)
          else
            component.public_send(action_def.name)
          end
        end
      end

      def transaction_wrapper(&)
        if defined?(::ActiveRecord::Base)
          ::ActiveRecord::Base.transaction(&)
        else
          yield
        end
      end

      # The action's outcome, in the same terms the endpoint reasons about.
      # Wraps the action's RETURN VALUE:
      #   * a Phlex::Reactive::Response — honored explicitly (replace/remove/
      #     redirect derived from it, exposed via #response).
      #   * anything else — the legacy contract (return value ignored by the
      #     endpoint, which falls back to the single self-replace). So a legacy
      #     action reports replace? true and #response nil.
      #
      # #streams reproduces the endpoint's actor streams (issue #110) — including
      # the token-refresh injection response_streams performs — so a matcher can
      # assert on exactly what the client would receive.
      class Result
        # The Response the action returned, or nil when it returned a legacy
        # (non-Response) value.
        attr_reader :response

        # The component the action actually ran against — the instance REBUILT
        # from the round-tripped identity, NOT the one passed to run_reactive (the
        # endpoint always acts on a rebuilt instance). Read its ivars to assert
        # state-backed changes: `run_reactive(c, :set, count: "42").component`.
        attr_reader :component

        # A stream re-renders `component`'s root (so its fresh token counts as the
        # refresh) iff its action is one of these — never append/prepend, which
        # insert children carrying their OWN token (issue #44). Same set the
        # endpoint's carries_token_for? uses.
        SELF_RENDER_ACTIONS = %w[replace update reactive:token].freeze

        def initialize(returned:, component:)
          @returned = returned
          @component = component
          @response = returned if returned.is_a?(Phlex::Reactive::Response)
        end

        # A legacy return (no Response) is the implicit single self-replace. A
        # Response replaces unless it removes or redirects (render_self? is false
        # for those, and for a .streams/.with that opts out).
        def replace?
          return true if @response.nil?

          @response.render_self?
        end

        def remove?
          return false if @response.nil?

          # Check the OPENING <turbo-stream> tag, not the whole string: a rendered
          # body that happens to contain the literal `action="remove"` (a quoted
          # code sample, say) must not false-positive. Same parse the token check
          # and the matchers use.
          @response.streams.any? do
            open_tag = it[/<turbo-stream\b[^>]*>/] || ""
            open_tag.include?(%(action="remove"))
          end
        end

        def redirect?
          !@response.nil? && @response.redirect?
        end

        def redirect_url
          @response&.redirect_url
        end

        # The actor's turbo-stream strings, exactly as the endpoint would render
        # them (response_streams) — a legacy return is the single self-replace; a
        # Response is honored, with the same token-refresh streams appended.
        def streams
          @streams ||= build_streams
        end

        private

        # Mirrors ActionsController#response_streams. Kept in lockstep with the
        # endpoint so the driver's streams match the real reply (issue #110).
        def build_streams
          return [@component.to_stream_replace] unless @response.is_a?(Phlex::Reactive::Response)
          return [redirect_stream(@response.redirect_url)] if @response.redirect?

          streams = @response.streams
          if @response.refresh_token? && !carries_token_for?(streams, @response.token_component)
            return [*streams, @response.token_component.to_stream_token]
          end

          if @response.render_self? && streams.none? { it.include?("data-reactive-token-value") }
            # Mirror the endpoint (issue #180): a self-render reply gets the full
            # replace; a companion-only reply.with (no subject_component) gets a
            # token-only refresh instead.
            streams =
              if @response.subject_component
                [@component.to_stream_replace, *streams]
              else
                [*streams, @component.to_stream_token]
              end
          end
          streams
        end

        def redirect_stream(url)
          %(<turbo-stream action="reactive:visit" data-url="#{ERB::Util.html_escape(url)}"></turbo-stream>)
        end

        # A stream already carries `component`'s fresh token iff it re-renders that
        # component's root at its own id AND carries a token — same test the
        # endpoint uses to avoid doubling the token (issue #44).
        def carries_token_for?(streams, component)
          target = %(target="#{ERB::Util.html_escape(component.id)}")
          streams.any? do
            next false unless it.include?("data-reactive-token-value") && it.include?(target)

            open_tag = it[/<turbo-stream\b[^>]*>/]
            open_tag&.include?(target) && SELF_RENDER_ACTIONS.include?(open_tag[/\baction="([^"]+)"/, 1])
          end
        end
      end
    end
  end
end

# The RSpec matchers (have_reactive_replace/remove/token_for) are optional: load
# them only when RSpec is present, so a Minitest app can mix in TestHelpers and
# assert on Result predicates directly with no RSpec dependency.
require "phlex/reactive/test_helpers/matchers" if defined?(RSpec::Matchers)

# The system/browser helpers (wait_for_reactive + the re-resolving value/text
# matchers, issue #201) are optional too: load them only when Capybara is present
# (a dev/test dependency), keeping them entirely out of the runtime path — the
# same optional-require gate as the matchers above and the engine below.
require "phlex/reactive/test_helpers/system" if defined?(Capybara)
