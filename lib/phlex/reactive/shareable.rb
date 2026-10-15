# frozen_string_literal: true

module Phlex
  module Reactive
    # Ractor-shareable values for the state the gem keeps on its modules and
    # classes (zoolutions/phlex-reactive#364): a non-main Ractor can read a
    # module instance variable or a constant only when its value is
    # Ractor-shareable.
    module Shareable
      module_function

      # A Ractor-shareable version of value when one can be made, else value
      # itself (frozen when it is a collection). Never freezes or copies
      # anything the caller still holds behind its back:
      #
      #   * plain data (Strings, Arrays, Hashes, Symbols, Integers, classes...)
      #     comes back as a deep-frozen COPY, so the app's own objects stay
      #     mutable;
      #   * a Proc comes back as a shareable COPY, which works only when its
      #     self and everything it captures are shareable already (a lambda
      #     written in a module body). Ruby never freezes what a Proc captures:
      #     a block from an initializer (self is `main`) is kept as is, and
      #     works on the main Ractor only;
      #   * a Hash keeps its default value or default proc and its
      #     compare_by_identity;
      #   * any other object (a MessageVerifier, an APM adapter, an app object)
      #     is kept as is.
      #
      # Engines without Ractor get the value back unchanged.
      def share(value)
        return value unless defined?(::Ractor)
        return value if ::Ractor.shareable?(value)

        case value
        when ::Proc then share_proc(value.dup) || value
        when ::Array then seal(value.map { share(it) })
        when ::Hash then share_hash(value)
        when ::String then value.dup.freeze
        else value
        end
      end

      # Is value shareable (and so readable from any Ractor)? True on an engine
      # without Ractor, where there is only one.
      def shareable?(value) = defined?(::Ractor) ? ::Ractor.shareable?(value) : true

      # ActiveSupport::Concern keeps its bookkeeping in instance variables of
      # the concern module itself: @_dependencies (the concerns it includes)
      # and the included/prepended block. They are written while the module
      # body loads and only read when a class includes the concern, so they
      # are sealed at the end of the body: the list frozen, the block (whose
      # self is the module, capturing nothing) made shareable.
      def seal_concern(mod)
        dependencies = mod.instance_variable_get(:@_dependencies) if mod.instance_variable_defined?(:@_dependencies)
        dependencies&.freeze
        %i[@_included_block @_prepended_block].each do
          share_proc(mod.instance_variable_get(it)) if mod.instance_variable_defined?(it)
        end
        mod
      end

      # The Proc made shareable in place, or nil when it cannot be (or there
      # is no Ractor).
      def share_proc(callable)
        return unless defined?(::Ractor)

        ::Ractor.make_shareable(callable)
      rescue ::Ractor::Error
        nil
      end

      # A plain Hash copy with every key and value shared, keeping the
      # default (value or proc) and compare_by_identity.
      def share_hash(hash)
        copy = hash.compare_by_identity? ? {}.compare_by_identity : {}
        hash.default_proc ? copy.default_proc = hash.default_proc : copy.default = share(hash.default)
        hash.each { |key, value| copy[share(key)] = share(value) }
        seal(copy)
      end

      # Frozen; shareable as well when everything inside it is.
      def seal(collection) = collection.freeze

      private_class_method :share_proc, :share_hash, :seal
    end
  end
end
