# frozen_string_literal: true

module Phlex
  module Reactive
    # The ONE conditions language behind reactive_show / reactive_show_targets
    # (issue #180 Phase A). It compiles Ruby-native values into a DNF wire shape
    # and evaluates that shape in Ruby with semantics identical to the client —
    # so first-paint `hidden:` (server) and live toggling (client) can never
    # drift (the shared spec/fixtures/show_predicate_vectors.json proves it).
    #
    # THE VALUE LANGUAGE (used by every if:/if_any:/unless: term):
    #   String/Symbol/Integer/Float  -> equals (stringified)
    #   true / false                 -> equals "true"/"false" (checkbox state)
    #   nil                          -> equals "" (blank)
    #   Array                        -> in (each stringified; empty raises)
    #   (10..)                       -> gte 10
    #   (..10)                       -> lte 10
    #   (...10)                      -> lt 10
    #   (10..20)                     -> gte 10 AND lte 20 (two terms, one group)
    #   { length: 6 }                -> len_eq 6 (issue #226 — the value's
    #   { length: 6.. } / (4..8)        CODEPOINT count; Integer Ranges reuse
    #                                   the threshold vocabulary as len_*)
    #   { checked: 1.. } / { checked: 0 } -> checked_* (issue #319 — how many
    #                                   owned boxes of a checkbox GROUP are
    #                                   ticked; same Integer/Range shapes)
    # Under unless: each term is NEGATED (De Morgan):
    #   scalar -> not; Array -> ∉ (AND of nots); Range -> the complement
    #   predicate (¬gte→lt, ¬lte→gt, ¬lt→gte), and a BOUNDED range complements
    #   to a disjunction (x<a ∨ x>b) that splits the group.
    #
    # THE WIRE (DNF): an ARRAY OF GROUPS. Terms AND within a group; groups OR.
    #   [[{ "field"=>"a", "equals"=>"1" }], [{ "field"=>"b", "gte"=>10 }]]
    # A single if: compiles to one group; if_any: to one group per hash; unless:
    # distributes its negated terms into every group (multiplying groups when a
    # bounded-range complement splits). There is NO expression surface: every
    # term is a declared literal predicate — the pre-#180 default-deny posture.
    module ShowConditions
      # The length-predicate wire keys (issue #226) — the Ruby half; the client
      # mirrors them in SHOW_LENGTH_KEYS. Length is counted in CODEPOINTS
      # (String#length here, [...value].length there) so multibyte values agree
      # — the shared fixture's emoji vector proves it.
      LENGTH_KEYS = %w[len_eq len_gte len_gt len_lte len_lt].freeze

      # The checked-count wire keys (issue #319) — the client mirrors them in
      # SHOW_CHECKED_KEYS. They count the TICKED boxes of a checkbox group (an
      # Array value counts its entries; an Integer is the count itself).
      CHECKED_KEYS = %w[checked_eq checked_gte checked_gt checked_lte checked_lt].freeze

      # A Hash value's one key -> its wire-key prefix.
      COUNT_PREFIXES = { "length" => "len", "checked" => "checked" }.freeze

      module_function

      # Compile if:/if_any:/unless: into DNF groups. Loud validation at render
      # (the pre-#180 posture) — empty conditions, empty Array/group values, a
      # non-Numeric Range endpoint, and if:+if_any: together all raise here so a
      # dead binding fails at render, never silently in the browser.
      def normalize(**kwargs)
        positive = kwargs.slice(:if, :if_any)
        negative = kwargs[:unless]

        if positive.key?(:if) && positive.key?(:if_any)
          raise ArgumentError,
            "reactive_show: exactly one of if:/if_any: (unless: composes with either), " \
            "got both"
        end
        raise ArgumentError, "reactive_show needs if:, if_any:, or unless:" unless positive.any? || negative

        groups = base_groups(positive)
        groups = apply_unless(groups, negative) if negative
        groups
      end

      # Evaluate DNF groups against a { field => value(String) } map — true when
      # ANY group's EVERY term matches. Mirrors the client fold exactly; a
      # referenced field absent from `values` reads as "" (fail-closed, same as
      # a blank field).
      # rubocop:disable Style/ItBlockParameter -- nested blocks: `it` would shadow ambiguously
      def match?(groups, values)
        groups.any? { |group| group.all? { |term| term_matches?(term, values) } }
      end

      # Every field named across all groups/terms — drives reactive_values
      # coverage (server first paint only fires when every field is provided).
      def fields(groups)
        groups.flat_map { |group| group.map { |term| term.fetch("field") } }.uniq
      end
      # rubocop:enable Style/ItBlockParameter

      # --- normalization internals -------------------------------------------

      # The positive base: if: -> one group; if_any: -> a group per hash; neither
      # (unless: only) -> a single empty "all true" group that unless: negates
      # into.
      def base_groups(positive)
        if positive.key?(:if)
          [group_terms(:if, positive.fetch(:if))]
        elsif positive.key?(:if_any)
          any = positive.fetch(:if_any)
          unless any.is_a?(Array) && any.any?
            raise ArgumentError, "reactive_show if_any: needs at least one group (an Array of hashes)"
          end

          any.map { group_terms(:if_any, it) }
        else
          [[]] # unless: only — one empty group; unless distributes its nots in
        end
      end

      # One hash -> its ANDed positive terms.
      def group_terms(context, hash)
        unless hash.is_a?(Hash) && hash.any?
          label = context == :if_any ? "each if_any: group needs at least one field" : "if: needs at least one field"
          raise ArgumentError, "reactive_show: #{label} (a Hash of field => value), got #{hash.inspect}"
        end

        hash.flat_map { |field, value| positive_terms(field, value) }
      end

      # Distribute the negated unless: over every base group, obeying De Morgan.
      # `unless:` negates the AND of its whole hash — ¬(a ∧ b) = ¬a ∨ ¬b — so the
      # negation is a DISJUNCTION: the UNION of each field's alternative
      # term-lists, never their cartesian product. Each field contributes 1
      # alternative (a scalar `not`, or an Array's ∉ = AND-of-nots, or an endless
      # range complement) or 2 (a bounded range, itself a disjunction); those
      # alternatives OR across fields. Distributing that ORed set over the base
      # groups multiplies them: |base| × |alternatives| groups, each base group
      # ANDed with exactly one alternative.
      def apply_unless(groups, negative)
        unless negative.is_a?(Hash) && negative.any?
          raise ArgumentError, "reactive_show unless: needs a Hash of field => value, got #{negative.inspect}"
        end

        alternatives = negative.flat_map { |field, value| negative_alternatives(field, value) }
        # rubocop:disable-next Style/ItBlockParameter -- nested block: `it` would shadow `group`
        groups.flat_map do |group|
          alternatives.map { |extra| group + extra }
        end
      end

      # --- the value language (positive) -------------------------------------

      # A field => value under if:/if_any: -> a list of ANDed terms (one, or two
      # for a bounded range).
      def positive_terms(field, value)
        name = field.to_s
        case value
        when Range then range_terms(name, value)
        when Array then [membership_term(name, value)]
        when Hash then count_terms(name, value)
        else [{ "field" => name, "equals" => equals_literal(value) }]
        end
      end

      def equals_literal(value)
        return "" if value.nil?

        value.to_s
      end

      def membership_term(name, array)
        list = array.map(&:to_s)
        raise ArgumentError, "reactive_show: #{name.inspect} Array needs at least one value" if list.empty?

        { "field" => name, "in" => list }
      end

      # A Range -> gte / lte / lt terms. Endless -> one term; bounded -> two
      # (gte + lte/lt) in the SAME group. Endpoints must be numbers (a literal
      # numeric threshold, never an expression).
      def range_terms(name, range)
        first = range.begin
        last = range.end
        validate_range_endpoints!(name, first, last)

        terms = []
        terms << { "field" => name, "gte" => first } unless first.nil?
        if last
          terms << { "field" => name, (range.exclude_end? ? "lt" : "lte") => last }
        end
        terms
      end

      def validate_range_endpoints!(name, first, last)
        [first, last].compact.each do
          next if it.is_a?(Numeric)

          raise ArgumentError,
            "reactive_show: #{name.inspect} Range endpoints must be numbers " \
            "(an ordered threshold), got #{it.inspect}"
        end
      end

      # --- the count predicates: length: (#226) and checked: (#319) ---------

      # A Hash value names a STRUCTURAL predicate over a COUNT — length: (the
      # value's codepoints) or checked: (the ticked boxes of a checkbox group).
      # Exact Integer -> one *_eq term; an Integer Range -> *_gte/*_lte/*_lt
      # terms exactly like range_terms. A count is total (blank/absent -> 0),
      # so { length: 0 } / { checked: 0 } legitimately match a blank field.
      def count_terms(name, hash)
        kind, value = count_value!(name, hash)
        prefix = COUNT_PREFIXES.fetch(kind)
        case value
        when Integer
          validate_count_literal!(name, kind, value)
          [{ "field" => name, "#{prefix}_eq" => value }]
        when Range then count_range_terms(name, kind, value)
        else raise_count_kind(name, kind, value)
        end
      end

      def count_range_terms(name, kind, range)
        prefix = COUNT_PREFIXES.fetch(kind)
        first = range.begin
        last = range.end
        raise_count_kind(name, kind, range) if first.nil? && last.nil?
        [first, last].compact.each { validate_count_literal!(name, kind, it) }

        terms = []
        terms << { "field" => name, "#{prefix}_gte" => first } unless first.nil?
        if last
          terms << { "field" => name, "#{prefix}_#{range.exclude_end? ? "lt" : "lte"}" => last }
        end
        terms
      end

      # The complement of a count predicate, under unless:. An exact count
      # negates to the outside disjunction (n < x OR n > x) — two
      # alternatives, like a bounded numeric range; ranges complement each leg
      # (not-gte -> lt, not-lte -> gt, not-lt -> gte). A count is total, so
      # unlike the numeric complements there is no blank/NaN fail-closed
      # asymmetry — the complement is exact.
      def count_complement(name, hash)
        kind, value = count_value!(name, hash)
        prefix = COUNT_PREFIXES.fetch(kind)
        case value
        when Integer
          validate_count_literal!(name, kind, value)
          [[{ "field" => name, "#{prefix}_lt" => value }], [{ "field" => name, "#{prefix}_gt" => value }]]
        when Range
          first = value.begin
          last = value.end
          raise_count_kind(name, kind, value) if first.nil? && last.nil?
          [first, last].compact.each { validate_count_literal!(name, kind, it) }

          low = first.nil? ? nil : [{ "field" => name, "#{prefix}_lt" => first }]
          high =
            if last.nil? then nil
            elsif value.exclude_end? then [{ "field" => name, "#{prefix}_gte" => last }]
            else [{ "field" => name, "#{prefix}_gt" => last }]
            end
          [low, high].compact
        else raise_count_kind(name, kind, value)
        end
      end

      # The one Hash key must be length: or checked: — anything else is a
      # typo'd predicate that must fail at render, never silently in the
      # browser. Returns [kind, value].
      def count_value!(name, hash)
        kind = hash.keys.first.to_s if hash.size == 1
        unless COUNT_PREFIXES.key?(kind)
          raise ArgumentError,
            "reactive_show: #{name.inspect} Hash value supports only length: or checked: " \
            "(got #{hash.keys.inspect})"
        end

        [kind, hash.values.first]
      end

      def validate_count_literal!(name, kind, value)
        return if value.is_a?(Integer) && value >= 0

        raise ArgumentError,
          "reactive_show: #{name.inspect} #{kind}: takes a non-negative Integer " \
          "(a #{kind == "length" ? "codepoint" : "ticked-box"} count), got #{value.inspect}"
      end

      def raise_count_kind(name, kind, value)
        raise ArgumentError,
          "reactive_show: #{name.inspect} #{kind}: takes a non-negative Integer " \
          "or an Integer Range, got #{value.inspect}"
      end

      # --- the value language (negated, under unless:) -----------------------

      # A field => value under unless: -> a LIST of alternative term-lists.
      # Scalar/Array negate to a single conjunctive alternative (an Array is
      # ¬(x ∈ set) = AND of nots); a bounded Range complements to TWO
      # alternatives (the disjunction x<a ∨ x>b). An empty Array raises, exactly
      # like the positive membership path (a dead binding must fail at render).
      def negative_alternatives(field, value)
        name = field.to_s
        case value
        when Range then range_complement(name, value)
        when Hash then count_complement(name, value)
        when Array
          list = value.map(&:to_s)
          raise ArgumentError, "reactive_show: #{name.inspect} Array needs at least one value" if list.empty?

          [list.map { { "field" => name, "not" => it } }]
        else [[{ "field" => name, "not" => equals_literal(value) }]]
        end
      end

      # The complement of a range predicate. Endless ranges complement to a
      # single opposite threshold (¬gte→lt, ¬lte→gt, ¬lt→gte) — itself a positive
      # numeric predicate, so a blank/NaN field stays FALSE (fail-closed: the
      # complement never flips a blank to visible). A bounded range complements
      # to two alternatives.
      def range_complement(name, range)
        first = range.begin
        last = range.end
        validate_range_endpoints!(name, first, last)

        low = first.nil? ? nil : [{ "field" => name, "lt" => first }]
        high =
          if last.nil?
            nil
          elsif range.exclude_end?
            [{ "field" => name, "gte" => last }]
          else
            [{ "field" => name, "gt" => last }]
          end

        [low, high].compact
      end

      # --- evaluation (mirrors the client) -----------------------------------

      def term_matches?(term, values)
        field = term.fetch("field")
        value = values.fetch(field, "")

        if term.key?("equals") then value == term["equals"]
        elsif term.key?("not") then value != term["not"]
        elsif term.key?("in") then term["in"].include?(value)
        elsif (key = LENGTH_KEYS.find { term.key?(it) }) then count_matches?(key, term[key], value.to_s.length)
        elsif (key = CHECKED_KEYS.find { term.key?(it) }) then count_matches?(key, term[key], checked_count(value))
        else numeric_term_matches?(term, value)
        end
      end

      # len_* / checked_* — compare a count (the value's CODEPOINTS via
      # String#length, or the group's ticked boxes) against the Integer literal.
      # A count is total (blank/absent -> 0), so every value is decidable; a
      # malformed non-Integer literal (a hand-built term) is fail-closed,
      # mirroring the client's warn-skip.
      def count_matches?(key, literal, count)
        return false unless literal.is_a?(Integer)

        case key.delete_prefix("len_").delete_prefix("checked_")
        when "eq" then count == literal
        when "gte" then count >= literal
        when "gt" then count > literal
        when "lte" then count <= literal
        when "lt" then count < literal
        end
      end

      # How many boxes of a group are ticked, from the first-paint value: an
      # Array (the checked values) counts its entries, an Integer (or its
      # string) is the count, a lone checkbox's "true"/"false" is 1/0, and a
      # blank/absent group is 0 — the client counts the owned ticked boxes.
      def checked_count(value)
        return value.size if value.is_a?(Array)
        return 1 if value.to_s == "true"

        Integer(value.to_s, exception: false) || 0
      end

      # gte/gt/lte/lt — coerce the field value to a number; a blank/non-numeric
      # value is fail-closed (never matches). Mirrors the client's
      # numericPredicateMatches (blank/whitespace -> NaN -> false).
      def numeric_term_matches?(term, value)
        trimmed = value.to_s.strip
        return false if trimmed.empty?

        number = Float(trimmed, exception: false)
        return false if number.nil?

        if term.key?("gte") then number >= term["gte"]
        elsif term.key?("gt") then number > term["gt"]
        elsif term.key?("lte") then number <= term["lte"]
        elsif term.key?("lt") then number < term["lt"]
        else false
        end
      end
    end
  end
end
