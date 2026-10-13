# frozen_string_literal: true

module Phlex
  module Reactive
    module Component
      # The signed-identity half of Component (issue #115): reactive_token —
      # the payload signed into the DOM root on EVERY render — plus the
      # class-level ivar precomputation that keeps that render path
      # allocation-free.
      #
      # THE token hot path. Both memos below are bare defined?/||= fast paths
      # ON PURPOSE: a render must never pay a per-read generation compare
      # (issue #115 invariant, .claude/rules/performance.md). Coherence comes
      # from the WRITE side instead — Component::Registry.bump! sweeps these
      # memos off the declaring class and all its descendants whenever any
      # registry declaration lands (class-load-shaped, rare), so they can't go
      # stale even when an ancestor re-declares after a subclass memoized.
      module Identity
        extend ActiveSupport::Concern

        # Whether the installed GlobalID gives a class its own app
        # (global_id_app, then GlobalID.app — rails/globalid after 1.4).
        # Read once: it is a fact about the loaded gem.
        def self.per_class_gid_app?
          return @per_class_gid_app if defined?(@per_class_gid_app)

          @per_class_gid_app = ::GlobalID::Identification.const_defined?(:ClassMethods, false) &&
                               ::GlobalID::Identification::ClassMethods.method_defined?(:global_id_app)
        end

        class_methods do
          # The record's instance-variable symbol (e.g. :@todo), computed once.
          # reactive_token reads it on every render; interpolating :"@#{key}" each
          # time would allocate a symbol per render. Nil when record-less.
          def reactive_record_ivar
            return @reactive_record_ivar if defined?(@reactive_record_ivar)

            @reactive_record_ivar = reactive_record_key ? :"@#{reactive_record_key}" : nil
          end

          # [string_key, ivar_symbol] pairs for the signed state, computed once.
          # reactive_token walks these every render; precomputing the "count"/:@count
          # forms avoids a String + Symbol allocation per key per render.
          def reactive_state_ivars
            @reactive_state_ivars ||= reactive_state_keys.map { [it.to_s, :"@#{it}"] }
          end
        end

        private

        # Signed identity payload: the class name plus whichever identity pieces
        # the component declares — a record GlobalID (`gid`), signed state (`s`),
        # or both. Keeping them in ONE MessageVerifier payload makes the state
        # (e.g. which column an inline_edit may write) tamper-proof alongside the
        # record. Record-only ({c, gid}) and state-only ({c, s}) shapes are
        # unchanged.
        #
        # A record that is NOT YET PERSISTED (new_record?) has no id → no GlobalID
        # (to_gid raises MissingModelIdError). A record-backed component may render
        # such a draft (an unsaved order the user is building): we OMIT gid and rely
        # on the declared state (reactive_state) as the draft seed, so the token
        # still signs cleanly and the client controller mounts. The draft is then
        # driven client-side (reactive_compute) until it's saved; once persisted, a
        # re-render signs the gid as usual. If the record is unsaved AND no state is
        # declared, the token carries just {c} — enough to mount, but with no
        # identity to round-trip, so declare reactive_state for a draft you sync.
        def reactive_token
          Phlex::Reactive.sign(reactive_identity_payload)
        end

        # The UNSIGNED identity payload — extracted from reactive_token (issue
        # #165) so the defer machinery mints its purpose-scoped defer tokens
        # from the exact same shape and the two token families can never drift.
        # Still THE hot path (reactive_token calls it on every render); the
        # split adds one method dispatch, verified flat by the token bench.
        def reactive_identity_payload
          klass = self.class
          payload = { "c" => klass.name }

          # Sign the gid ONLY for a present, persisted record. An unsaved draft
          # (persisted? == false) has no GlobalID — omit gid and let the signed
          # state seed it (the tokenless-draft seam documented above); a nil
          # ivar likewise carries no identity to sign, and must short-circuit
          # before to_gid (nil.to_gid would raise).
          if (record_ivar = klass.reactive_record_ivar) &&
             (record = instance_variable_get(record_ivar)) && signable_gid?(record)
            payload["gid"] = reactive_gid(record)
          end

          state_ivars = klass.reactive_state_ivars
          unless state_ivars.empty?
            state = {}
            state_ivars.each { |key, ivar| state[key] = instance_variable_get(ivar).as_json }
            payload["s"] = state
          end

          payload
        end

        # A record's gid is signable unless it is an unsaved AR-like draft
        # (responds to persisted? and is not persisted) — a new_record has no
        # id and to_gid would raise MissingModelIdError. A record that doesn't
        # respond to persisted? (a plain GlobalID-able object) is treated as
        # signable, matching the pre-existing contract.
        def signable_gid?(record)
          !(record.respond_to?(:persisted?) && !record.persisted?)
        end

        # record.to_gid.to_s, without the URI. For a record whose to_gid is
        # GlobalID's own (not overridden on its class or on itself) and whose
        # id is an Integer, GlobalID's string is exactly
        # "gid://<GlobalID.app>/<class name>/<id>": an Integer needs no
        # escaping and there are no params. Building it directly skips a
        # validated URI::GID (~37 objects, about half a record token's cost),
        # once per record-backed row per render. Anything else goes through
        # to_gid unchanged, its errors included.
        def reactive_gid(record)
          if record.is_a?(::GlobalID::Identification) &&
             record.method(:to_gid).owner.equal?(::GlobalID::Identification) &&
             (id = record.id).is_a?(Integer) && (app = reactive_gid_app(record.class)) && (name = record.class.name)
            "gid://#{app}/#{name}/#{id}"
          else
            record.to_gid.to_s
          end
        end

        # The app to_gid would use: the class's own where GlobalID has one.
        def reactive_gid_app(klass)
          (Identity.per_class_gid_app? && klass.global_id_app) || ::GlobalID.app
        end
      end
    end
  end
end
