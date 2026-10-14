# frozen_string_literal: true

module Phlex
  module Reactive
    module ShowConditions
      # The Hash-valued terms that are not a count: `same:` (issue #395) — a
      # field equal to ANOTHER owned field. Compiled and evaluated here; the
      # client mirrors both in features/bindings.js, and the shared fixture
      # (spec/fixtures/show_predicate_vectors.json) holds them to agreement.
      #
      # A negated term (under unless:) keeps its shape and carries
      # "negate" => true, the way unless: turns equals into not.
      module CompareTerms
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
