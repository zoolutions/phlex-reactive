# frozen_string_literal: true

module Phlex
  module Reactive
    # A page-level keyboard shortcut (issue #357), the value behind
    # `on(..., shortcut:)` and `on_client(:keydown, ..., shortcut:)`.
    #
    #   Shortcut.parse("mod+z")                          # String form
    #   Shortcut.parse({ keys: "esc", in_editable: true }) # Hash form
    #
    # `mod` is meta on Apple platforms and ctrl elsewhere. Stimulus has no
    # "either" modifier (its key filter compares all four modifier flags
    # exactly), so a `mod` chord renders TWO descriptors, a meta twin and a ctrl
    # twin, and the client runs only the twin for its platform. Stimulus keeps
    # the key filtering; the client adds the platform check, the editable-target
    # guard and preventDefault.
    #
    # Validation is loud, at render: Stimulus reports an unknown key token by
    # throwing at keypress time, which is too late to notice.
    class Shortcut
      MODIFIERS = %w[mod meta ctrl alt shift].freeze
      # Stimulus's default keyMappings: the named keys plus a-z and 0-9.
      NAMED_KEYS = %w[enter tab esc space up down left right home end page_up page_down].freeze
      HASH_KEYS = %i[keys in_editable].freeze

      private_constant :MODIFIERS, :NAMED_KEYS, :HASH_KEYS

      attr_reader :keys

      def self.parse(spec)
        case spec
        when String then new(spec, in_editable: false)
        when Hash then from_hash(spec)
        else
          raise ArgumentError,
            "shortcut: takes a String (\"mod+z\") or a Hash ({ keys: \"esc\", in_editable: true }), " \
            "got #{spec.inspect}"
        end
      end

      def self.from_hash(spec)
        keys = spec[:keys]
        in_editable = spec.fetch(:in_editable, false)
        unless (spec.keys - HASH_KEYS).empty? && keys.is_a?(String)
          raise ArgumentError,
            "shortcut: as a Hash takes keys: (a String, e.g. \"esc\") and an optional " \
            "in_editable: (true/false), got #{spec.inspect}"
        end
        unless [true, false].include?(in_editable)
          raise ArgumentError, "shortcut: in_editable: is true or false, got #{in_editable.inspect}"
        end

        new(keys, in_editable:)
      end
      private_class_method :from_hash

      def initialize(keys, in_editable:)
        tokens = keys.downcase.split("+").map(&:strip)
        @in_editable = in_editable
        @keys = canonical(keys, tokens)
        freeze
      end

      # The Stimulus key filters to bind: the meta and ctrl twins for a `mod`
      # chord, else the chord itself.
      def filters
        return [@keys] unless @keys.start_with?("mod+")

        %w[meta ctrl].map { @keys.sub("mod", it) }
      end

      # The wire form the client reads (data-reactive-shortcut-param, or the
      # on_client record's "shortcut"): the canonical String, or the Hash form
      # when the shortcut also fires inside editable targets.
      def param = @in_editable ? { "keys" => @keys, "inEditable" => true } : @keys

      private

      def canonical(source, tokens)
        mods = tokens.select { MODIFIERS.include?(it) }
        key = tokens - MODIFIERS
        validate!(source, mods, key)
        [*MODIFIERS.select { mods.include?(it) }, key.first].join("+")
      end

      def validate!(source, mods, key)
        raise ArgumentError, "shortcut: #{source.inspect} must name exactly one key (e.g. \"mod+z\")" unless key.size == 1
        raise ArgumentError, "shortcut: #{source.inspect} repeats a modifier" unless mods.uniq.size == mods.size
        if mods.include?("mod") && mods.intersect?(%w[meta ctrl])
          raise ArgumentError,
            "shortcut: #{source.inspect} combines mod with meta/ctrl — mod already is meta on Apple " \
            "platforms and ctrl elsewhere"
        end
        return if known_key?(key.first)

        raise ArgumentError,
          "shortcut: #{source.inspect} has an unknown key #{key.first.inspect} — use a letter, a digit, " \
          "or one of #{NAMED_KEYS.join(", ")} (Stimulus's default key map; custom keyMappings are not " \
          "known on the server, bind those with event: and window: instead)"
      end

      def known_key?(key) = NAMED_KEYS.include?(key) || key.match?(/\A[a-z0-9]\z/)
    end
  end
end
