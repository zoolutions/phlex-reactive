# frozen_string_literal: true

module Phlex
  module Reactive
    module Component
      # The reactive_subscribe macro (issue #474). Not named `Subscribe`: this
      # module is in every reactive component's constant lookup, where a bare
      # noun would shadow a host app's kit component of that name (the #233
      # rule). The behaviour it adds lives in Phlex::Reactive::Subscribe.
      module SubscribeDeclaration
        extend ActiveSupport::Concern

        # A subscribe name is the stream name's last part: one identifier, no
        # colon (the stream-name separator), no spaces.
        SUBSCRIBE_NAME = /\A[a-z][a-z0-9_]*\z/

        class_methods do
          # Subscribe every rendered root of this component to a broadcast
          # stream, for as long as the root is on the page:
          #
          #   reactive_record :item
          #   reactive_subscribe :widget                     # [item, :widget]
          #   reactive_subscribe key: -> { [@item.list, :items] }   # parts, run on the component
          #   reactive_subscribe key: [:lobby, :feed]        # parts, fixed
          #
          # A name or key:, not both. One stream per component (a subclass may
          # declare its own). broadcast_self broadcasts to it.
          def reactive_subscribe(name = nil, key: nil)
            declaration = build_subscribe_declaration(name, key)
            refuse_dormant_subscribe! if reactive_dormant?
            Registry.write_scalar(self, :subscribe, declaration)
            include Phlex::Reactive::Subscribe::ComponentMethods

            declaration
          end

          # The Phlex::Reactive::Subscribe::Declaration, or nil.
          def reactive_subscribe_declaration
            Registry.resolve_scalar(self, :subscribe, :reactive_subscribe_declaration)
          end

          # broadcast_to on the declared stream, so the broadcaster need not
          # repeat the key:
          #
          #   Widget.broadcast_self(replace: item)                 # the key from the Widget built for item
          #   Widget.broadcast_self(item, js: js.add_class(...))   # js: has no component: name its subject
          #
          # The key resolves on a component of this class: `subject` (a record,
          # an init-kwargs Hash or a built component), else the verb's payload
          # (built once: the same component is what gets rendered). Every other
          # keyword is broadcast_to's, except each: (the stream is the
          # declared one).
          def broadcast_self(subject = nil, **opts)
            unless reactive_subscribe_declaration
              raise ArgumentError, "#{name}.broadcast_self needs a reactive_subscribe declaration"
            end
            if opts.key?(:each)
              raise ArgumentError, "#{name}.broadcast_self broadcasts to the declared stream: it takes no each: " \
                                   "(use broadcast_to(each: ...) to fan out)"
            end

            verb = opts.slice(*Phlex::Reactive::Streamable::BROADCAST_VERBS.keys).keys.first
            # No subject: the verb's payload is it — built here, and handed on
            # built, so broadcast_to does not build it a second time.
            if subject.nil? && verb && verb != :js
              component = subscribe_component(opts[verb])
              opts = opts.merge(verb => component)
            else
              component = subscribe_component(subject, javascript: verb == :js && subject.nil?)
            end

            broadcast_to(*component.reactive_subscribe_parts, **opts)
          end

          private

          def subscribe_component(subject, javascript: false)
            if javascript
              raise ArgumentError,
                "#{name}.broadcast_self(js: ...) has no component to read the stream key from: pass its " \
                "subject first, e.g. broadcast_self(record, js: ...)"
            end

            component = subject.is_a?(::Phlex::SGML) ? subject : send(:coerce_broadcast_payload, subject)
            return component if component.is_a?(self)

            raise ArgumentError,
              "#{name}.broadcast_self reads the stream key from a #{name}, got a #{component.class.name}: " \
              "pass the subject first, e.g. broadcast_self(record, replace: other_component)"
          end

          def build_subscribe_declaration(name, key)
            if name.nil? == key.nil?
              raise ArgumentError, "#{self.name}: reactive_subscribe takes a stream name or key:, exactly one"
            end
            return Phlex::Reactive::Subscribe::Declaration.new(name: nil, key: subscribe_key(key)) if key

            name = name.to_s
            unless SUBSCRIBE_NAME.match?(name)
              raise ArgumentError,
                "#{self.name}: reactive_subscribe name must be a lowercase identifier (it ends the stream " \
                "name), got #{name.inspect}"
            end

            Phlex::Reactive::Subscribe::Declaration.new(name: name.to_sym, key: nil)
          end

          def subscribe_key(key)
            return key if key.respond_to?(:call)
            return key.dup.freeze if key.is_a?(Array) && !key.empty?

            raise ArgumentError,
              "#{name}: reactive_subscribe key: must be the stream's parts (a non-empty Array) or a " \
              "callable that returns them, got #{key.inspect}"
          end

          def refuse_dormant_subscribe!
            raise ArgumentError,
              "#{name}: reactive_subscribe cannot be dormant — a dormant root never connects, so it would " \
              "never subscribe. Drop reactive_dormant on this component."
          end
        end

        # ActiveSupport::Concern's bookkeeping on this module, sealed now that
        # the body has loaded (zoolutions/phlex-reactive#364).
        Phlex::Reactive::Shareable.seal_concern(self)
      end
    end
  end
end
