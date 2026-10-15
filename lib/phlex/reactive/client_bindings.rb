# frozen_string_literal: true

module Phlex
  module Reactive
    # The blessed CLIENT-ONLY include (issue #180). A view that only shows/hides
    # (reactive_show), filters (reactive_filter), computes client-side
    # (reactive_compute), or runs zero-round-trip ops (on_client/js) — with NO
    # server actions and NO signed token — includes this instead of the full
    # Phlex::Reactive::Component.
    #
    # Why it exists: including the full Component pulls in Streamable, whose
    # class/instance methods (replace/update/append/prepend/remove,
    # to_stream_*) collide by NAME with an app's own Turbo-stream concern — so
    # adopters cherry-picked an internal module and hand-rolled a token-less root
    # (and defined a dummy #id "never read at render" just to keep
    # phlex_reactive:doctor quiet). ClientBindings is that missing seam, blessed:
    #
    #   class ExerciseFilter < ApplicationComponent
    #     include Phlex::Reactive::ClientBindings
    #
    #     reactive_scope :form
    #     def reactive_values = { role: @role }
    #
    #     def view_template
    #       div(**reactive_root) do              # token-less: no #id required
    #         select(name: "form[role]") { role_options }
    #         div(**reactive_show(if: { role: "individual" })) { demographics }
    #       end
    #     end
    #   end
    #
    # It includes the DECLARATION DSL and the view Helpers, but NOT Streamable
    # (nothing to clobber) or Identity (no token). So a ClientBindings class never
    # enters Streamable.registered_classes and is invisible to
    # phlex_reactive:doctor's #id check — no dummy #id, no nag.
    #
    # The client-only DSL macros (reactive_scope, reactive_compute) work; the
    # SERVER-ACTION macros (action, reactive_record, reactive_state) RAISE at
    # class-definition time — without Identity they could only silently no-op
    # (sign nothing, dispatch nowhere), so the guard fails loudly (the guard lives
    # in Component::DSL#require_server_actions!, keyed on Identity presence).
    #
    # Helpers is token-tolerant (issue #180): reactive_attrs emits a token only
    # when reactive_token is available, and reactive_root uses #id only when
    # defined — so the client-only view helpers work with no Identity/Streamable.
    #
    # The full Component includes ClientBindings too (ONE implementation of the
    # client-only surface), then layers Streamable + Identity on top — so a
    # token-bearing reactive_root is a SUPERSET, not a fork.
    module ClientBindings
      extend ActiveSupport::Concern

      include Component::DSL
      include Component::Helpers

      # ActiveSupport::Concern's bookkeeping on this module, sealed now that
      # the body has loaded (zoolutions/phlex-reactive#364).
      Phlex::Reactive::Shareable.seal_concern(self)
    end
  end
end
