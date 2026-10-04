# frozen_string_literal: true

module Phlex
  module Reactive
    # Dormant roots (issue #274). A root declared dormant — `reactive_dormant`
    # on the class, or `reactive_root(dormant: true)` — renders
    # data-reactive-dormant="reactive" INSTEAD of data-controller="reactive":
    # the reactive controller is not mounted (and, when the app loads it lazily,
    # not even fetched) until one of the root's triggers fires. The client's
    # phlex/reactive/early module then moves the identifier into data-controller
    # and the trigger is replayed on connect.
    #
    # A render made for the ACTOR's own reply is AWAKE: the reply only exists
    # because that page's controller is loaded and connected, so a dormant
    # replacement would save nothing and cost one more wake. The endpoint runs
    # the action and its reply (and the defer render) inside Dormant.awake;
    # every other render — the page, a stream built outside a reactive request,
    # and a BROADCAST even when fired inside an action (Dormant.asleep) — stays
    # dormant, because its receivers may never have loaded the client.
    module Dormant
      AWAKE_KEY = :phlex_reactive_dormant_awake

      class << self
        def awake?
          Thread.current[AWAKE_KEY] ? true : false
        end

        # Render dormant roots awake inside the block (fiber-local, restored on
        # exit — a raise included).
        def awake
          previous = Thread.current[AWAKE_KEY]
          Thread.current[AWAKE_KEY] = true
          yield
        ensure
          Thread.current[AWAKE_KEY] = previous
        end

        # A reactive_lazy(on: :visible) shell (issue #276) has no trigger
        # descriptor — the CONTROLLER's IntersectionObserver materializes it —
        # so a dormant one could never wake. Refused where it is declared, and
        # (for the other declaration order) where the shell renders.
        def reject_visible_lazy!(klass)
          return unless klass.respond_to?(:reactive_lazy_trigger) && klass.reactive_lazy_trigger&.key?(:visible)

          raise ArgumentError,
            "#{klass}: reactive_dormant cannot be combined with reactive_lazy(on: :visible) — a dormant " \
            "root wakes on a trigger event, and a visibility shell has none (the controller's " \
            "IntersectionObserver loads it). Use reactive_lazy(on: \"an:event\"), or drop reactive_dormant."
        end

        # The inverse, for a render fired INSIDE an awake block that leaves the
        # actor's page — a broadcast. A plain yield when nothing is awake.
        def asleep
          return yield unless Thread.current[AWAKE_KEY]

          begin
            Thread.current[AWAKE_KEY] = nil
            yield
          ensure
            Thread.current[AWAKE_KEY] = true
          end
        end
      end
    end
  end
end
