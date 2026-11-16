# frozen_string_literal: true

module Phlex
  module Reactive
    # A component that subscribes to its own broadcast stream (issue #474).
    #
    #   class Widget < ApplicationComponent
    #     include Phlex::Reactive::Component
    #
    #     reactive_record :item
    #     reactive_subscribe :widget          # the stream [item, :widget]
    #
    #     def view_template = div(**reactive_root) { @item.state }
    #   end
    #
    #   # A job, later:
    #   Widget.broadcast_self(replace: item)  # = Widget.broadcast_to(item, :widget, replace: item)
    #
    # Rendering puts the stream's signed SSE src on the root
    # (data-reactive-subscribe); the client's subscribe feature opens one
    # <pgbus-stream-source> for it while the root is on the page and closes it
    # when the root goes. The key lives in one place, the declaration, for the
    # subscriber and the broadcaster.
    #
    # pgbus only: the src is a pgbus signed stream name, the one
    # pgbus_stream_from (and turbo_stream_from under pgbus) renders. Without
    # pgbus (Action Cable) a subscribing root raises ConfigurationError at
    # render, naming turbo_stream_from as the alternative. There is no replay:
    # a broadcast sent before the source connects is missed (pgbus streams are
    # ephemeral by default), as with any live subscription.
    module Subscribe
      # What reactive_subscribe declared: the stream name's last part (nil
      # with key:), and key: — the stream's parts as an Array, or a callable
      # the component instance_execs to get them (nil with a name).
      Declaration = Data.define(:name, :key)

      class << self
        # Streams-capable pgbus that signs stream names: what the src needs.
        # Signatures only, no query.
        def capable?
          Phlex::Reactive.pgbus_streams? && defined?(::Pgbus::Streams::SignedName) == "constant"
        end

        # Raise unless pgbus can carry the subscription — at render of a
        # subscribing root, naming the alternative.
        def require_capable!(klass)
          return if capable?

          raise Phlex::Reactive::ConfigurationError,
            "#{klass.name} declares reactive_subscribe, which needs pgbus with reactive Streams (a signed " \
            "<pgbus-stream-source> per root). On Action Cable, render turbo_stream_from with the same key " \
            "next to the component instead."
        end

        # The stream name broadcast_to(*parts) publishes to — Turbo's and
        # pgbus's name_from — refused when it overflows pgbus's queue-name
        # budget (pgbus would raise on the broadcast too, and the subscription
        # could never match it).
        def stream_name(klass, parts)
          name = ::Pgbus::Streams::Stream.name_from(parts)
          budget = ::Pgbus.stream_name_budget if ::Pgbus.respond_to?(:stream_name_budget)
          return name if budget.nil? || name.length <= budget

          raise Phlex::Reactive::ConfigurationError,
            "#{klass.name}: the reactive_subscribe stream #{name.inspect} is #{name.length} chars, over " \
            "pgbus's stream-name budget of #{budget}. Declare shorter parts with key: (for a record, " \
            "Pgbus.stream_key(record) is a fixed-length key) and broadcast with broadcast_self."
        end

        # The signed SSE URL a <pgbus-stream-source> subscribes with.
        def source_src(stream_name) = Phlex::Reactive::Defer.stream_src(stream_name)
      end

      # What reactive_subscribe adds to a component's instances. Included only
      # by a class that declares it.
      module ComponentMethods
        # The stream's parts: [record, name], or key: (an Array, or a callable
        # run against this component).
        def reactive_subscribe_parts
          declaration = self.class.reactive_subscribe_declaration
          key = declaration.key
          parts =
            if key.respond_to?(:call) then instance_exec(&key)
            elsif key then key
            else [reactive_subscribe_record, declaration.name]
            end
          parts = Array(parts)
          return parts unless parts.empty? || parts.any?(&:nil?)

          # A nil part would put every such root on one shared stream.
          raise ArgumentError,
            "#{self.class.name}: reactive_subscribe key: gave #{parts.inspect}; the stream's parts must be " \
            "non-empty and none of them nil"
        end

        # The root's subscription marker (reactive_attrs): the signed src the
        # client mints its <pgbus-stream-source> from.
        def reactive_subscribe_data
          Subscribe.require_capable!(self.class)
          name = Subscribe.stream_name(self.class, reactive_subscribe_parts)
          { reactive_subscribe: Subscribe.source_src(name) }
        end

        private

        def reactive_subscribe_record
          record_key = self.class.reactive_record_key
          unless record_key
            raise ArgumentError,
              "#{self.class.name}: reactive_subscribe :#{self.class.reactive_subscribe_declaration.name} " \
              "needs reactive_record (the stream is the record's), or declare key: (the stream's parts)"
          end

          record = instance_variable_get(:"@#{record_key}")
          # A nil record would subscribe every such root to one shared ":name"
          # stream.
          return record unless record.nil?

          raise ArgumentError, "#{self.class.name}: reactive_subscribe needs @#{record_key} (it is nil)"
        end
      end
    end
  end
end
