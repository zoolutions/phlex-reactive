# frozen_string_literal: true

module Phlex
  module Reactive
    module ShowConditions
      # The Hash-valued terms that are not a count: `same:` (issue #395) — a
      # field equal to ANOTHER owned field — and `digits:` (issue #396) — a
      # closed format: ASCII digits only, an exact count or an Integer Range,
      # and an optional digit prefix (`starts_with:`). Compiled and evaluated
      # here; the client mirrors both in features/bindings.js, and the shared
      # fixture (spec/fixtures/show_predicate_vectors.json) holds them to
      # agreement.
      #
      # A negated term (under unless:) keeps its shape and carries
      # "negate" => true, the way unless: turns equals into not.
      module CompareTerms
        # The digit-count wire keys: the count suffixes length: uses.
        DIGITS_KEYS = %w[digits_eq digits_gte digits_lt digits_lte].freeze
        DIGIT_STRING = /\A[0-9]*\z/
        PREFIX = /\A[0-9]+\z/

        # { digits: 10, starts_with: "9" } -> ONE term (a Range's bounds sit in
        # the same term, so unless: can negate the whole format at once).
        def digits_term(name, hash, negate:)
          options = hash.transform_keys(&:to_sym)
          if (extra = options.keys - %i[digits starts_with]).any?
            raise ArgumentError, "reactive_show: #{name.inspect} digits: takes only starts_with: (got #{extra.inspect})"
          end
          unless options.key?(:digits)
            raise ArgumentError, "reactive_show: #{name.inspect} starts_with: needs digits: (e.g. digits: 10)"
          end

          term = { "field" => name }.merge(digits_bounds(name, options[:digits]))
          term["prefix"] = digits_prefix!(name, options[:starts_with]) if options.key?(:starts_with)
          term["negate"] = true if negate
          term
        end

        # digits: — every character is 0-9, the count fits every bound, and the
        # value starts with the prefix; negate flips it. A malformed literal
        # (a hand-built term) is false either way, like the client's skip.
        def digits_matches?(term, value)
          keys = DIGITS_KEYS.select { term.key?(it) }
          return false unless keys.all? { term[it].is_a?(Integer) } && (term["prefix"].nil? || term["prefix"].is_a?(String))

          text = value.to_s
          ok = text.match?(DIGIT_STRING) &&
               keys.all? { count_matches?(it, term[it], text.length) } &&
               (term["prefix"].nil? || text.start_with?(term["prefix"]))
          ok != (term["negate"] == true)
        end

        # { same: :other, case: :fold } -> one term comparing this field's
        # value with another owned field's, both read as strings. The other
        # name is a bare field like any show field (the client applies
        # reactive_scope).
        def same_term(name, hash, negate:)
          options = hash.transform_keys(&:to_sym)
          if (extra = options.keys - %i[same case]).any?
            raise ArgumentError, "reactive_show: #{name.inspect} same: takes only case: (got #{extra.inspect})"
          end

          term = { "field" => name, "same" => same_field!(name, options[:same]) }
          term["fold"] = true if same_case!(name, options[:case])
          term["negate"] = true if negate
          term
        end

        # same: — this field's value against the other field's (an absent
        # field is ""), folded when the term says so; negate flips it.
        def same_matches?(term, value, values)
          left = value.to_s
          right = values.fetch(term["same"], "").to_s
          if term["fold"] == true
            left = ascii_fold(left)
            right = ascii_fold(right)
          end
          (left == right) != (term["negate"] == true)
        end

        # The ASCII-only fold both evaluators apply: A-Z to a-z and nothing
        # else (never downcase, which folds letters the client would not).
        def ascii_fold(value)
          value.tr("A-Z", "a-z")
        end

        private

        def digits_bounds(name, digits)
          case digits
          when Integer
            return { "digits_eq" => digits } if digits >= 0
          when Range
            first = digits.begin
            last = digits.end
            if [first, last].compact.any? && [first, last].compact.all? { it.is_a?(Integer) && it >= 0 }
              bounds = {}
              bounds["digits_gte"] = first unless first.nil?
              bounds[digits.exclude_end? ? "digits_lt" : "digits_lte"] = last unless last.nil?
              return bounds
            end
          end

          raise ArgumentError,
            "reactive_show: #{name.inspect} digits: takes a non-negative Integer or an Integer Range " \
            "(a digit count), got #{digits.inspect}"
        end

        def digits_prefix!(name, prefix)
          return prefix if prefix.is_a?(String) && prefix.match?(PREFIX)

          raise ArgumentError,
            "reactive_show: #{name.inspect} starts_with: takes a String of digits (0-9), got #{prefix.inspect}"
        end

        def same_field!(name, other)
          field = other.to_s if other.is_a?(Symbol) || other.is_a?(String)
          return field unless field.nil? || field.strip.empty?

          raise ArgumentError,
            "reactive_show: #{name.inspect} same: needs the other field's name (e.g. same: :email), " \
            "got #{other.inspect}"
        end

        # case: is absent (an exact compare) or :fold. Anything else raises:
        # there is no locale-aware fold to ask for.
        def same_case!(name, value)
          return false if value.nil?
          return true if (value.is_a?(Symbol) || value.is_a?(String)) && value.to_s == "fold"

          raise ArgumentError, "reactive_show: #{name.inspect} case: takes only :fold, got #{value.inspect}"
        end
      end
    end
  end
end
