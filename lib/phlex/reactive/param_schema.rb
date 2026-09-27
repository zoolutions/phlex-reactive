# frozen_string_literal: true

require "date"
require "time"
require "bigdecimal"
require "active_model"
require "active_model/type"

module Phlex
  module Reactive
    # A COMPILED param schema (issue #109). The coerce family used to live inline
    # in ActionsController; here it's a standalone unit built ONCE at declaration
    # (Component.action -> ParamSchema.compile) so:
    #
    #   * an unknown type symbol raises Phlex::Reactive::UnknownParamType at class
    #     load instead of silently `to_s`-ing at request time, and
    #   * the drop-don't-fabricate coercion is unit-testable without a booted
    #     request spec.
    #
    # The behavior is byte-for-byte what the controller did: the built-ins keep
    # their exact semantics ("abc".to_i => 0, not DROP; :file duck-type DROP; the
    # array/hash DROP rules), the bracket-expansion/deep-merge matrix (#16/#21/
    # #24/#39) is UNCHANGED, and the verbose_errors dropped-param collector (#82/
    # #87) threads through unchanged — a nil collector is the zero-cost prod path.
    #
    # A type is one of:
    #   * a scalar symbol           (:string/:integer/:float/:boolean/:file/:date/
    #                                :datetime/:decimal, or an app-registered type)
    #   * a Hash schema             ({ id: :integer, ... })   — nested object
    #   * a one-element Array       ([:integer] / [{ ... }])  — array of that
    class ParamSchema
      # Sentinel: a declared key whose value can't be coerced to its type is
      # DROPPED (not assigned), so the method's keyword default applies — exactly
      # as if the client had omitted the key. Distinct from a coerced nil/[]. A
      # custom param_type callable returns this to reject a value while keeping
      # the drop-don't-fabricate contract, so it is PUBLIC.
      DROP = Object.new
      DROP.freeze

      class << self
        # Validate `schema` recursively against the param-type registry and
        # return a compiled ParamSchema. Raises UnknownParamType at the FIRST
        # unknown type symbol (naming the full bracketed path), so a typo fails
        # loudly at declaration. A blank schema compiles to an empty schema (the
        # action drops everything the client posts).
        def compile(schema)
          schema = {} if schema.nil?
          validate!(schema, nil)
          new(schema)
        end

        # The frozen-semantics built-in registry, rebuilt on demand (the module
        # dups it so app registration doesn't mutate this template). Each entry
        # is a callable(value) -> coerced | DROP. The scalar casts here are the
        # EXACT ones the controller ran, so the existing request-spec matrix is
        # unchanged.
        # rubocop:disable Style/ItBlockParameter, Style/SymbolProc
        # Explicit `(value)` params, NOT `it` or `&:to_s`: the date/datetime/decimal
        # casters wrap an INNER `parse_or_drop { ... }` block, and `it` there would
        # bind to that inner block's (absent) param, not the caster's value — the
        # #109 autocorrect trap. Keep the WHOLE family explicit so it reads
        # uniformly and no caster can be collapsed to a zero-arity lambda.
        def built_in_types
          {
            string: ->(value) { value.to_s },
            integer: ->(value) { value.to_i },
            float: ->(value) { value.to_f },
            boolean: ->(value) { BOOLEAN_TYPE.cast(value) },
            # :file and the composite types (Hash/Array) are handled structurally
            # in #coerce, not via a scalar callable — the registry entry exists so
            # compile-time validation recognizes the symbol. A nil callable means
            # "handled structurally"; #coerce never dispatches it here.
            file: nil,
            date: ->(value) { parse_or_drop { Date.iso8601(value.to_s) } },
            datetime: ->(value) { parse_or_drop { DateTime.iso8601(value.to_s) } },
            decimal: ->(value) { parse_or_drop { BigDecimal(value.to_s) } }
          }
        end
        # rubocop:enable Style/ItBlockParameter, Style/SymbolProc

        private

        # Run a parse that raises on bad input (Date/DateTime iso8601, BigDecimal)
        # and turn the failure into DROP — the keyword default then applies rather
        # than a fabricated value. ::ArgumentError covers BigDecimal("abc") and a
        # blank/garbage string; ::Date::Error (an ArgumentError subclass) covers
        # the iso8601 parsers; ::TypeError covers a nil slipping through.
        #
        # MUST be top-level-qualified (::): the phlex gem defines Phlex::Argument
        # Error (a subclass of the stdlib one), and this file is nested under
        # Phlex::Reactive, so a bare `ArgumentError` resolves LEXICALLY to
        # Phlex::ArgumentError — which would NOT catch a stdlib Date::Error and the
        # parse failure would escape as a 500.
        def parse_or_drop
          yield
        rescue ::ArgumentError, ::TypeError
          DROP
        end

        # Walk the schema, validating each type symbol against the registry and
        # recursing into nested hashes and array element types. `path` is the
        # bracketed name for a helpful error message.
        def validate!(schema, path)
          schema.each do |key, type|
            validate_type!(type, join(path, key))
          end
        end

        def validate_type!(type, path)
          case type
          when Array
            unless type.length == 1
              raise UnknownParamType, "#{path}: an array type must wrap exactly one element type, " \
                                      "got #{type.inspect}"
            end

            validate_type!(type.first, "#{path}[]")
          when Hash
            validate!(type, path)
          when Symbol
            unless Phlex::Reactive.param_type?(type)
              raise UnknownParamType, "#{path}: unknown param type #{type.inspect}. Known types: " \
                                      "#{Phlex::Reactive.param_types.keys.sort.join(", ")}. " \
                                      "Register a custom type with Phlex::Reactive.param_type(#{type.inspect}) { |v| ... }."
            end
          else
            raise UnknownParamType, "#{path}: a param type must be a Symbol, a Hash schema, or a " \
                                    "one-element Array, got #{type.inspect}"
          end
        end

        def join(path, key)
          path ? "#{path}[#{key}]" : key.to_s
        end
      end

      # ActiveModel's Boolean type, instantiated once — the exact caster the
      # controller used (an unrecognized value casts to nil, which is KEPT, not
      # dropped).
      BOOLEAN_TYPE = ActiveModel::Type::Boolean.new
      private_constant :BOOLEAN_TYPE

      attr_reader :schema

      def initialize(schema)
        @schema = schema
      end

      # Coerce client params against this schema. Anything not in the schema is
      # dropped — no raw mass assignment reaches the component. The top-level
      # params (an ActionController::Parameters or a plain Hash) coerce against
      # the hash schema (same recursion as nested hashes).
      #
      # `dropped` is the verbose_errors diagnostics collector: an Array that
      # accumulates [bracketed_path, :undeclared|:uncoercible] entries. Pass nil
      # (the production path) and every diagnostic branch early-returns — zero
      # extra work.
      def coerce(params, dropped = nil)
        # A schema-less action drops EVERYTHING the client posted. Under a
        # verbose collector, record every posted key as :undeclared (forgetting
        # `params:` entirely is the loudest silent drop — #87); otherwise it's a
        # cost-free {} return on the production path.
        if @schema.empty?
          collect_undeclared(dropped, to_param_hash(params), {}, nil) if dropped
          return {}
        end

        # The TOP-LEVEL params container is the request's `params[:params]` — a
        # coerced-away malformed top level (a stray non-hash) is normalized back
        # to {} here, never DROP: the whole point of the top level is to hold the
        # coerced kwargs, so a bad container yields "no params", not a dropped
        # action argument. Nested malformed hashes DO drop (see coerce_hash).
        coerced = coerce_hash(params, @schema, dropped, nil)
        coerced.equal?(DROP) ? {} : coerced
      end

      # The key this DECLARATION holds for `name` if it declares it as an ARRAY
      # param, else nil. Reads the declaration, never the incoming params, so the
      # endpoint's empty-group announcement (issue #258) can only ever fill
      # something the action asked for.
      #
      # A key that is neither a String nor a Symbol stays unresolved on purpose:
      # `compile` accepts `{ 0 => [:string] }`, but `coerce_hash` raises on
      # `0.to_sym` the moment that key is PRESENT, and the announcement is what
      # would make it present. Resolving it would turn a request that answers 200
      # and fills nothing into a 500.
      def array_param(name)
        name = name.to_s
        key, type = @schema.find { |k, _| (k.is_a?(String) || k.is_a?(Symbol)) && k.to_s == name }
        key if type.is_a?(Array)
      end

      private

      # Coerce a value against a declared type. Arrays accept both a real JSON
      # array and a Rails-style index hash ({ "0" => ..., "1" => ... }), so a
      # fields_for collection works either way.
      def coerce_value(value, type, dropped, path)
        case type
        when Array
          coerce_array(value, type.first, dropped, path)
        when Hash
          coerce_hash(value, type, dropped, path)
        when :file
          coerce_file(value)
        else
          coerce_scalar(value, type)
        end
      end

      # Dispatch a scalar through the registry callable. The symbol is known
      # (compile validated it), so the lookup always hits.
      def coerce_scalar(value, type)
        Phlex::Reactive.param_types.fetch(type).call(value)
      end

      # An uploaded file (issue #34) passes through UNTOUCHED — never .to_s'd,
      # which would corrupt it. Anything that isn't an uploaded file returns DROP
      # (the keyword default applies). Duck-types on UploadedFile's interface
      # rather than naming a class, so a Rack::Test upload, an ActionDispatch
      # upload, and a Falcon multipart body all qualify.
      def coerce_file(value)
        uploaded_file?(value) ? value : DROP
      end

      def uploaded_file?(value)
        value.respond_to?(:original_filename) && value.respond_to?(:read)
      end

      # A real array (or Rails index hash) coerces element-wise. A malformed
      # present-but-non-array value returns DROP rather than [] — coercing a stray
      # scalar to an empty array would let a bad payload read as an explicit
      # "clear everything". An ELEMENT that coerces to DROP is rejected; an array
      # whose every element drops returns DROP (keyword default applies), but a
      # genuinely empty input array stays [].
      def coerce_array(value, element_type, dropped, path)
        values = array_values(value)
        return DROP if values.nil?
        return [] if values.empty?

        coerced =
          if dropped
            values.map.with_index do |element, i|
              element_path = "#{path}[#{i}]"
              result = coerce_value(element, element_type, dropped, element_path)
              dropped << [element_path, :uncoercible] if result.equal?(DROP)
              result
            end
          else
            values.map { coerce_value(it, element_type, nil, nil) }
          end
        coerced.reject! { it.equal?(DROP) }
        coerced.empty? ? DROP : coerced
      end

      # Keep declared keys only (drop undeclared — no mass assignment), recursing
      # for nested hash/array element types. Symbolizes keys to splat as kwargs.
      # A key whose value coerces to DROP is skipped (keyword default applies).
      #
      # A present-but-malformed value (a nested `invoice: null` / `invoice: "x"`
      # for a hash schema) returns DROP rather than fabricating {} — the same
      # drop-don't-fabricate rule coerce_array applies to a non-array, so a bad
      # payload can't read as an explicit empty object on update!(nested:). The
      # top-level entry (coerce) normalizes that DROP back to {}. A genuinely
      # empty hash ({} / an empty index form) stays {}.
      def coerce_hash(value, schema, dropped, path)
        return DROP unless hash_like?(value)

        hash = to_param_hash(value)
        collect_undeclared(dropped, hash, schema, path) if dropped
        schema.each_with_object({}) do |(key, type), out|
          key_name = key.to_s
          next unless hash.key?(key_name)

          key_path = dropped && join_path(path, key_name)
          coerced = coerce_value(hash[key_name], type, dropped, key_path)
          if coerced.equal?(DROP)
            dropped << [key_path, :uncoercible] if dropped
            next
          end

          out[key.to_sym] = coerced
        end
      end

      # ---- verbose_errors dropped-param diagnostics ----------------------
      # Everything below runs ONLY when the collector exists (flag on); the
      # production path never reaches these methods.

      def join_path(path, key)
        path ? "#{path}[#{key}]" : key
      end

      # Record every input key this schema level doesn't declare. A hash value
      # expands to its leaf paths so the log shows the full bracketed name the
      # client posted (invoice[date], not just invoice).
      def collect_undeclared(dropped, hash, schema, path)
        declared = schema.keys.map(&:to_s)
        hash.each do |key, value|
          next if declared.include?(key)

          record_undeclared(dropped, join_path(path, key), value)
        end
      end

      def record_undeclared(dropped, path, value)
        if value.is_a?(Hash) && value.any?
          value.each { |key, child| record_undeclared(dropped, "#{path}[#{key}]", child) }
        else
          dropped << [path, :undeclared]
        end
      end

      # ---- end verbose_errors diagnostics --------------------------------

      # Normalize an array param: a real array passes through; a Rails index hash
      # ({ "0" => ..., "1" => ... }) becomes its values in index order. Anything
      # else (a stray scalar, nil) is malformed => nil, so the caller drops the
      # param rather than fabricating an empty array.
      def array_values(value)
        return value.to_a if value.is_a?(Array)

        return unless value.respond_to?(:to_unsafe_h) || value.is_a?(Hash)

        to_param_hash(value).sort_by { |k, _| k.to_i }.map(&:last)
      end

      # True when `value` is a Hash or an ActionController::Parameters — i.e. a
      # value to_param_hash unwraps to real keys rather than {}. A nested hash
      # schema fed anything else (nil, a scalar) is malformed and drops. The
      # SAME acceptance test to_param_hash uses, kept as a guard so a malformed
      # input is dropped BEFORE to_param_hash flattens it to a fabricated {}.
      def hash_like?(value)
        value.is_a?(Hash) || value.respond_to?(:to_unsafe_h)
      end

      # Unwrap ActionController::Parameters (or a plain Hash) to a string-keyed
      # Hash so coercion can index it uniformly, then expand bracket notation so
      # a model-scoped Rails form's flat keys nest (issue #21).
      def to_param_hash(value)
        flat =
          if value.respond_to?(:to_unsafe_h)
            value.to_unsafe_h.stringify_keys
          elsif value.is_a?(Hash)
            value.stringify_keys
          else
            return {}
          end

        expand_bracket_keys(flat)
      end

      # The client's #collectFields keeps a form input's name verbatim, so a
      # Rails Form(model: @invoice) posts FLAT bracketed keys like
      # "invoice[date]". Coercion does exact-key matching, so without this a
      # nested schema (params: { invoice: { date: … } }) never finds "invoice"
      # and drops everything. Expand "invoice[date]" => "2026-01-02" into
      # { "invoice" => { "date" => "2026-01-02" } } — and "items[0][qty]" into
      # the Rails index-hash form coerce_array already understands — deep-merging
      # so sibling keys (invoice[date], invoice[status]) coalesce. Keys WITHOUT
      # brackets and already-nested values pass through untouched.
      def expand_bracket_keys(flat)
        flat.each_with_object({}) do |(key, value), out|
          deep_assign(out, bracket_path(key), value)
        end
      end

      # Matches each bracket segment in "items_attributes][0][qty]" — the part
      # after the first "[". Hoisted to a frozen constant so coercing a bracketed
      # key doesn't recompile the pattern per key on every request.
      BRACKET_SEGMENT = /[^\[\]]+/
      private_constant :BRACKET_SEGMENT

      # "invoice[items_attributes][0][qty]" => ["invoice", "items_attributes",
      # "0", "qty"]. A key with no brackets is a single-element path.
      def bracket_path(key)
        return [key] unless key.include?("[")

        head, rest = key.split("[", 2)
        [head, *rest.scan(BRACKET_SEGMENT)]
      end

      # Walk/create nested hashes along `path`, then merge `value` at the leaf so
      # a bracket key and a sibling pre-nested object coalesce regardless of which
      # arrives first. #merge_value deep-merges hash/hash collisions and otherwise
      # lets the later value win.
      def deep_assign(hash, path, value)
        *parents, leaf = path
        node = parents.reduce(hash) do |acc, segment|
          acc[segment] = {} unless acc[segment].is_a?(Hash)
          acc[segment]
        end
        node[leaf] = merge_value(node[leaf], value)
      end

      # Combine an existing leaf value with a new one. Two hashes deep-merge (so
      # bracket-expanded fields and a pre-nested object for the same key both
      # survive); any other collision takes the new value.
      def merge_value(existing, value)
        return value unless existing.is_a?(Hash) && value.is_a?(Hash)

        existing.merge(value.stringify_keys) { |_k, old, new| merge_value(old, new) }
      end
    end
  end
end
