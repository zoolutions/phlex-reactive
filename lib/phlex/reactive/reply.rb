# frozen_string_literal: true

module Phlex
  module Reactive
    # The ONE door for building an action's reply (issue #182). Component#reply
    # returns one, so an action writes
    #
    #   reply.replace.flash(:error, msg)
    #
    # There is no constant to qualify (reply is a method, resolved on the
    # component — so a namespaced component needs no `Response = …` alias) and no
    # `self` to thread (the component is bound).
    #
    # Reply is NOT a Response and does NOT subclass one: each verb calls the
    # Response `build_*` class method, supplying the bound component as the
    # subject, and returns the real, frozen Response value the endpoint honors. So
    # immutability, chaining (.flash/.stream/.also/.js/.defer), and render_self?
    # come from the Response value object untouched — the chain is plain Response
    # all the way down.
    #
    # Response remains the value object the endpoint reads; you never construct it
    # directly (its former public class verbs raise a guided rewrite).
    class Reply
      def initialize(component)
        @component = component
      end

      # Self-targeting builders — the bound component is supplied implicitly.

      # Re-render in place. `morph: true` morphs the subtree (preserves the
      # focused input + caret) instead of an outerHTML swap — see #morph.
      # `effect:` (issue #215) — the per-call effect override for this one
      # stream (a built-in name, :random, false to suppress, or #186 legs);
      # same kwarg on every verb below.
      def replace(morph: false, effect: nil)
        Response.build_replace(@component, morph:, effect:)
      end

      # Re-render in place via Idiomorph (method="morph") — keeps focus + caret.
      def morph(effect: nil)
        Response.build_morph(@component, effect:)
      end

      # Update only inner HTML (preserves the root element + its token attr).
      # `morph: true` morphs the inner HTML in place (issue #113) so a
      # cross-tab/per-field update keeps a focused input's caret.
      def update(morph: false, effect: nil)
        Response.build_update(@component, morph:, effect:)
      end

      # Reactive collections (issue #35) — add/remove a row in a declared
      # reactive_collection, emitting the row stream + the count companion +
      # the empty-state toggle as ONE Response. The bound component is the
      # container (it carries the declaration + size resolver). The collection is
      # named by the `to:`/`from:` keyword (issue #182 — reads as Ruby, and a
      # `to:` present unambiguously means "a collection row"):
      #
      #   def add_item(...)    = (item = @list.items.create!(...); reply.append(item, to: :items))
      #   def remove_item(id:) = (@list.items.find(id).destroy!;   reply.remove(id, from: :items))
      #
      # `model` is the row's record; remove also accepts the row's dom-id string.
      # Extra kwargs (issue #186) thread to the row component's new(model:, **row_kwargs)
      # — e.g. reply.append(item, to: :items, autofocus: true) → ItemRow.new(item:,
      # autofocus: true). Additive: a no-kwarg call is byte-identical to before.
      # `effect:` (issue #215) is reserved as the row's per-call effect — it is
      # NOT forwarded to the row component's init like the other row_kwargs.
      def append(model = UNSET_ARG, legacy_model = UNSET_ARG, to: UNSET_ARG, effect: nil, **row_kwargs)
        collection_build!(:build_collection_append, :append, model, legacy_model, to, effect, row_kwargs)
      end

      def prepend(model = UNSET_ARG, legacy_model = UNSET_ARG, to: UNSET_ARG, effect: nil, **row_kwargs)
        collection_build!(:build_collection_prepend, :prepend, model, legacy_model, to, effect, row_kwargs)
      end

      # Two forms, dispatched on the PRESENCE of `from:` (issue #182 — no sentinel
      # overload): bare `reply.remove` removes the bound component's own element;
      # `reply.remove(model, from: :items)` removes a collection row + count +
      # empty-state. `model` may be the record or the row's dom-id string.
      #
      #   reply.remove                       # remove the bound component's element
      #   reply.remove(model, from: :items)  # remove a collection row
      def remove(model = UNSET_ARG, legacy_model = UNSET_ARG, from: UNSET_ARG, effect: nil)
        reject_legacy_form!(:remove, model, legacy_model)
        # Bare `reply.remove` (no positional, no from:) removes self.
        return Response.build_remove(@component, effect:) if from.equal?(UNSET_ARG) && model.equal?(UNSET_ARG)

        if from.equal?(UNSET_ARG)
          raise ArgumentError,
            "reply.remove(model, …) needs a source collection — reply.remove(model, from: :name)"
        end
        reject_symbol_first!(:remove, model, :from, from)
        Response.build_collection_remove(@component, from, resolve_row_arg(model), effect:)
      end

      # Subject-free builders — pass straight through so they read naturally.

      # Client-side full navigation (Turbo.visit). Pass a *_url.
      def redirect(url)
        Response.build_redirect(url)
      end

      # Escape hatch / multi-stream root: zero or more raw turbo-stream strings.
      def with(*strings)
        Response.build_with(*strings)
      end

      # Self-targeting again: emit exactly these streams with a TOKEN-ONLY refresh
      # (issue #30) — partial/per-field update, NO full-self replace, so the
      # component's live inputs survive. The bound component supplies the token.
      def streams(*strings)
        Response.build_streams(@component, *strings)
      end

      # Defer an expensive segment (issue #165): `reply.defer(Totals.new(...))`.
      #
      # With NO prior verb, the bound component's token is refreshed via a tiny
      # token-only stream (reply.streams), NOT a full self-replace: a full
      # replace would re-render the acting component SYNCHRONOUSLY on the request
      # thread — and if you defer your OWN subject (`reply.defer(self)`), that is
      # the very render you meant to move OFF the critical path, so the defer
      # would be silently defeated (a double render). The token-only refresh
      # rolls the signed identity forward without any synchronous render; the
      # deferred segment's directive rides alongside. Chain off a verb when you
      # DO want a synchronous piece too:
      #
      #   reply.streams(volume_cell).defer(SessionTotals.new(workout: @workout))
      #   reply.replace.defer(Totals.new(order: @order))   # explicit self re-render
      def defer(component, placeholder: nil, morph: false)
        Response.build_streams(@component).defer(component, placeholder:, morph:)
      end

      # Mark targets PENDING and let the app's own job settle them (issue #248).
      # For an action that ENQUEUES the work rather than doing it: the endpoint
      # renders the reply inside the transaction while the queue publishes on
      # commit, so a `reply.morph` after an enqueue is guaranteed to draw the
      # pre-job world. This replies truthfully instead.
      #
      #   def re_execute(transfer_id:)
      #     transfer = @bulk_payment.transfers.re_executable.find(transfer_id)
      #     reply.pending(transfer, in: :unreconcilable, job: ReExecuteJob, args: [transfer.id])
      #   end
      #
      #   def restore_all                       # the enqueue lives in a service
      #     count = 0
      #     reply.pending(restorable, in: :declined) { count = BatchRestoreService.call(...) }
      #       .flash(:notice, "Putting #{count} back…")
      #   end
      #
      # `records` is one record, an enumerable of them, or Streamable component
      # instances. `in:` names the reactive_collection they live in (required
      # for records — it is how their row DOM ids and the count/empty-state
      # bookkeeping are resolved). The enqueue is a BLOCK (anything ActiveJob
      # enqueued inside it captures the settle handle — including from a service
      # object) or the `job:`/`args:` sugar. `peers: true` also broadcasts each
      # settle to the container's record stream, so a second operator watching
      # the same batch sees it; the default is actor-only, matching reply.defer.
      #
      # The bound component is the CONTAINER: it owns the collection declaration,
      # the size resolver, and the subscription anchor. Its token is refreshed
      # but it is NOT re-rendered.
      #
      # See Phlex::Reactive::Settles for the job side.
      def pending(records, peers: false, job: nil, args: nil, **opts, &enqueue)
        Response.build_pending(
          @component, records, collection: Response.pending_collection!(opts), peers:, job:, args:, enqueue:
        )
      end

      private

      # Sentinel distinguishing "keyword omitted" from an explicit nil value, so
      # `reply.remove(nil, from: :items)` (remove a row whose id resolves to nil)
      # stays distinct from bare `reply.remove` (remove self). Reused for the
      # positional model too, so the Symbol-first misuse can be caught precisely.
      UNSET_ARG = Object.new
      private_constant :UNSET_ARG

      # Shared append/prepend build: catch the old two-positional form, require the
      # `to:` keyword, reject a Symbol-first model, then delegate to the Response
      # builder (name first, model second — its internal order).
      def collection_build!(builder, verb, model, legacy_model, to, effect, row_kwargs)
        # Old form `reply.append(:name, model)` passes a SECOND positional — the
        # arity would just error, so intercept it with the guided rewrite.
        reject_legacy_form!(verb, model, legacy_model)
        if to.equal?(UNSET_ARG)
          raise ArgumentError,
            "reply.#{verb} needs a target collection — reply.#{verb}(model, to: :name)"
        end
        reject_symbol_first!(verb, model, :to, to)
        Response.public_send(builder, @component, to, resolve_row_arg(model), effect:, **row_kwargs)
      end

      # The pre-#182 call `reply.<verb>(:name, model)` — a Symbol name first, the
      # model second. Detect it by the presence of the second positional and print
      # the exact keyword rewrite.
      def reject_legacy_form!(verb, model, legacy_model)
        return if legacy_model.equal?(UNSET_ARG)

        keyword = verb == :remove ? :from : :to
        raise ArgumentError,
          "reply.#{verb}(#{model.inspect}, …) — the collection name moved to a keyword " \
          "(issue #182): reply.#{verb}(model, #{keyword}: #{model.inspect})"
      end

      # Issue #182 removed the Symbol-first form (`reply.append(:items, model)`).
      # A Symbol in the model position is almost certainly that old call shape, so
      # raise the exact keyword rewrite instead of trying to build a row from a
      # Symbol "record".
      def reject_symbol_first!(verb, model, keyword, name)
        return unless model.is_a?(Symbol)

        raise ArgumentError,
          "reply.#{verb}(#{model.inspect}, …) — the collection name moved to a keyword " \
          "(issue #182): reply.#{verb}(model, #{keyword}: #{name.inspect})"
      end

      # A row build needs a real model/dom-id — never the omitted sentinel.
      def resolve_row_arg(model)
        raise ArgumentError, "reply collection verbs need a model or dom-id as the first argument" if model.equal?(UNSET_ARG)

        model
      end
    end
  end
end
