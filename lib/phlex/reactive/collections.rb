# frozen_string_literal: true

module Phlex
  module Reactive
    # The reactive_collection bookkeeping (issue #35), extracted from Response's
    # privates so MORE THAN ONE caller can run it (issue #248).
    #
    # A collection row is never just a row: adding one must also refresh the
    # count companion and clear the empty-state at the 0->1 boundary; removing
    # one must refresh the count and restore the empty-state at the 1->0
    # boundary. That arithmetic used to live inside Response, reachable only
    # from `reply.*` — so a JOB that finished background work had to re-derive
    # it by hand and got the boundary subtly wrong.
    #
    # Three callers now share this module:
    #
    #   * Response.build_collection_{append,prepend,remove} — the actor's reply
    #   * Phlex::Reactive::Settle — the job-side settle (issue #248)
    #   * Streamable.broadcast_collection_to — the peers' broadcast (issue #248)
    #
    # The reply/settle paths build <turbo-stream> STRINGS; the broadcast path
    # hands pieces to Turbo::StreamsChannel, which builds its own tags. They
    # therefore cannot share the rendering — so what they share is the layer
    # that actually drifts: the DECISIONS (#count_refresh and #empty_toggle,
    # the 0<->1 boundary). Every renderer below reads those two.
    #
    # The module is stateless: every method takes the CollectionDefinition plus
    # the bound container instance (the size resolver is `instance_exec`d
    # against it, so it reads the container's ivars/association).
    module Collections
      class << self
        # Resolve a declared collection off the container's class. A typo'd name
        # must fail LOUDLY here, not silently emit an empty stream list.
        def definition!(container, name)
          container.class.reactive_collections[name.to_sym] ||
            raise(Phlex::Reactive::Error,
              "undeclared reactive_collection :#{name} on #{container.class}")
        end

        # --- The two shared DECISIONS -------------------------------------

        # [count_target, size_string] when a count companion AND a size resolver
        # are both declared and the resolver returned a number; nil otherwise
        # (the count stream is simply omitted — a list with just rows works).
        def count_refresh(definition, container)
          return nil unless definition.count

          size = definition.size_for(container)
          return nil if size.nil?

          [definition.count, size.to_s]
        end

        # What the empty-state must do for this delta, or nil for "nothing":
        #   :clear   — the list just crossed 0->1, remove the empty-state
        #   :restore — the list just emptied, append the empty-state back
        # Both are edge-triggered off the LIVE size (the resolver runs after the
        # mutation), never off a client-side increment.
        def empty_toggle(definition, container, delta)
          return nil unless definition.empty

          size = definition.size_for(container)
          case delta
          when :add then :clear if size == 1
          else :restore if size&.zero?
          end
        end

        # --- The reply/settle renderer (turbo-stream strings) --------------

        # Row add (append/prepend) + count + empty-state clear.
        #
        # row_kwargs (issue #186) thread to the row component's init via the
        # class stream builder's **options passthrough (ItemRow.new(model:,
        # **row_kwargs)). `effect:` (issue #215) stamps the ROW stream only —
        # the count companion and the empty-state toggle are bookkeeping, not
        # the thing entering/leaving.
        def add_streams(definition, container, model, action, row_kwargs = {}, effect: nil)
          streams = [
            definition.item.public_send(action, target: definition.container, model:, effect:, **row_kwargs)
          ]
          streams.concat(count_streams(definition, container))
          streams << definition.empty.new.to_stream_remove if empty_toggle(definition, container, :add) == :clear
          streams
        end

        # Row remove + count + empty-state restore. The empty-state is appended
        # back INTO the container (not its own id) when the list just emptied —
        # restoring "No items yet" after the last row went. model: nil builds it
        # argument-free (an empty-state is a static view).
        def remove_streams(definition, container, model, effect: nil)
          streams = [row_remove_stream(definition, model, effect)]
          streams.concat(count_streams(definition, container))
          if empty_toggle(definition, container, :remove) == :restore
            streams << definition.empty.append(target: definition.container, model: nil)
          end
          streams
        end

        # The count companion's update stream, or [] when there is nothing to
        # refresh. Its own method (rather than an inline append) because the
        # settle path refreshes the count WITHOUT a row delta — a job that
        # neither added nor removed a row can still have changed the size.
        def count_streams(definition, container)
          target, size = count_refresh(definition, container)
          return [] unless target

          [Phlex::Reactive::Response.update_stream(target, size)]
        end

        # Remove the row by its DOM id. Accepts the record (so dom_id is
        # derived) or an already-built dom-id string (e.g. the value the row
        # used as its #id).
        def row_remove_stream(definition, model, effect = nil)
          if model.is_a?(String)
            Phlex::Reactive::Effects.annotate(Phlex::Reactive.stream_builder.remove(model), effect)
          else
            definition.item.remove(model, effect:)
          end
        end

        # Re-render ONE row in place (a settle that neither added nor removed —
        # the work ran and the row is simply different now). No count/empty
        # streams: a replace cannot change the size.
        def replace_streams(definition, model, effect: nil, **row_kwargs)
          [definition.item.replace(model, effect:, **row_kwargs)]
        end
      end
    end
  end
end
