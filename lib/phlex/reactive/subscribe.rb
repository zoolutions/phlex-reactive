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
    # render, naming turbo_stream_from as the alternative.
    #
    # Catching up (issue #478). A durable stream's root also carries the
    # stream's watermark at render (data-reactive-subscribe-since, read the
    # way pgbus_stream_from reads it), and its source replays from there: a
    # broadcast sent between the render and the connection still arrives. An
    # ephemeral stream (pgbus's default) has no archive to replay, so it gets
    # no watermark; the client dispatches reactive:subscribed on the root each
    # time its source connects, and a component that must not miss a change
    # refetches on it.
    module Subscribe
      # What reactive_subscribe declared: the stream name's last part (nil
      # with key:), and key: — the stream's parts as an Array, or a callable
      # the component instance_execs to get them (nil with a name).
      Declaration = Data.define(:name, :key)

      class << self
        # Streams-capable pgbus that signs stream names: what the src needs.
        # Signatures only, no query.
        def capable?
          Phlex::Reactive.pgbus_streams? && defined?(::Pgbus::Streams::SignedName) == "constant" &&
            ::Pgbus::Streams::SignedName.respond_to?(:sign)
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

        # The since-id the source replays from: a durable stream's watermark
        # (MAX msg_id, 0 for a stream nothing was published to yet), read live
        # like pgbus_stream_from reads it. nil for an ephemeral stream (no
        # archive to replay) or a pgbus that cannot tell. One query per render
        # of a durable subscribing root, never cached: pgbus's own cache is
        # cleared only between Rack requests, and a broadcast renders in a job.
        def since_id(stream_name)
          config = ::Pgbus.configuration if ::Pgbus.respond_to?(:configuration)
          return unless config.respond_to?(:stream_durable?) && config.stream_durable?(stream_name)

          stream = ::Pgbus.stream(stream_name)
          stream.current_msg_id if stream.respond_to?(:current_msg_id)
        end
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
        # client mints its <pgbus-stream-source> from, and for a durable stream
        # the watermark it replays from (issue #478).
        def reactive_subscribe_data
          Subscribe.require_capable!(self.class)
          name = Subscribe.stream_name(self.class, reactive_subscribe_parts)
          data = { reactive_subscribe: Subscribe.source_src(name) }
          since = Subscribe.since_id(name)
          data[:reactive_subscribe_since] = since unless since.nil?
          data
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
