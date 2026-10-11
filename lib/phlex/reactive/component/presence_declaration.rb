# frozen_string_literal: true

module Phlex
  module Reactive
    module Component
      # The reactive_presence macro (issue #358). Not named `Presence`: this
      # module is in every reactive component's constant lookup, where a bare
      # noun would shadow a host app's kit component of that name (the #233
      # rule). The behaviour it adds lives in Phlex::Reactive::Presence.
      module PresenceDeclaration
        extend ActiveSupport::Concern

        # A presence name is the last part of the stream name, so it is one
        # identifier: no colon (the stream-name separator), no spaces.
        PRESENCE_NAME = /\A[a-z][a-z0-9_]*\z/

        class_methods do
          # Declare this component the roster of a presence stream:
          # [record, :presence, name], or [*key, :presence, name] for a
          # record-less component.
          #
          #   reactive_record :board
          #   reactive_presence :viewers, state: { selected: :integer }, ttl: 45
          #
          # `state:` is each tab's ephemeral state, typed with the same table as
          # action params; undeclared keys are dropped. `ttl:` is how many
          # seconds a silent tab survives. Adds the presence_set action (what
          # js.presence sends) and `presence` (the roster) to the component.
          def reactive_presence(name, state: {}, ttl: Phlex::Reactive::Presence::DEFAULT_TTL, key: nil)
            require_server_actions!(:reactive_presence)
            declaration = build_presence_declaration(name, state, ttl, key)
            refuse_dormant_presence! if reactive_dormant?

            # The generated action. Exempt from verify_authorized: the signed
            # token already proves the actor rendered this root, and the write
            # is typed, default-deny, ephemeral and lands only on the actor's own
            # row (keyed by its secret SSE connection id). A component that needs
            # a check defines authorize_presence_state!(**state); the action runs
            # it first.
            action :presence_set, params: declaration.state
            skip_verify_authorized :presence_set
            Registry.write_scalar(self, :presence, declaration)
            include Phlex::Reactive::Presence::ComponentMethods

            # Class load runs before a database exists: the signatures alone gate it.
            transport = Phlex::Reactive::Presence::Transport
            transport.register_ttl(declaration.name, ttl) if transport.wired?
            declaration
          end

          # The Phlex::Reactive::Presence::Declaration, or nil.
          def reactive_presence_declaration
            Registry.resolve_scalar(self, :presence, :reactive_presence_declaration)
          end

          private

          def build_presence_declaration(name, state, ttl, key)
            name = name.to_s
            unless PRESENCE_NAME.match?(name)
              raise ArgumentError,
                "#{self.name}: reactive_presence name must be a lowercase identifier (it ends the stream " \
                "name), got #{name.inspect}"
            end
            unless ttl.is_a?(Integer) && ttl.positive?
              raise ArgumentError, "#{self.name}: reactive_presence ttl: must be a positive Integer (seconds), " \
                                   "got #{ttl.inspect}"
            end
            refuse_ttl_within_heartbeat!(ttl)

            state = state.transform_keys(&:to_sym)
            if state.key?(Phlex::Reactive::Presence::NOTE_KEY.to_sym)
              raise ArgumentError,
                "#{self.name}: reactive_presence state key #{Phlex::Reactive::Presence::NOTE_KEY} is reserved"
            end

            Phlex::Reactive::Presence::Declaration.new(
              name: name.to_sym, state: state.freeze, ttl:, key: key && Array(key).freeze
            )
          end

          # A ttl at or below the heartbeat would expire a live tab between two
          # beats: its row would vanish and come back on the next one.
          def refuse_ttl_within_heartbeat!(ttl)
            heartbeat = Phlex::Reactive::Presence::Transport.heartbeat_interval
            return if ttl > heartbeat

            raise ArgumentError,
              "#{name}: reactive_presence ttl: #{ttl} is at or below the transport's heartbeat interval " \
              "(#{heartbeat} s), so a live tab would expire between two beats. Use more than #{heartbeat} " \
              "(two missed beats is a good floor)."
          end

          def refuse_dormant_presence!
            raise ArgumentError,
              "#{name}: reactive_presence cannot be dormant — a dormant root never connects, so its tab " \
              "would never join the stream. Drop reactive_dormant on this component."
          end
        end
      end
    end
  end
end
