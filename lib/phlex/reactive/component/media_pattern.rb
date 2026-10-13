# frozen_string_literal: true

module Phlex
  module Reactive
    module Component
      # reactive_media's match: (issue #380) — a Ruby Regexp as the JavaScript
      # source the client anchors as ^(?:…)$ and compiles without flags. The
      # source is tokenized (an escape is one token, so an escaped backslash is
      # never mistaken for one): a leading \A and a trailing \z/\Z are dropped,
      # and anything JavaScript would read differently raises at render rather
      # than matching silently wrong in the browser.
      module MediaPattern
        # Escapes Ruby reads as an anchor or a class and JS reads as a letter,
        # plus \s/\S, whose JS class also holds Unicode spaces Ruby's does not.
        RUBY_ONLY_ESCAPES = %w[\A \z \Z \G \h \H \R \X \K \p \P \s \S].freeze
        # The group openers both engines read alike: (?: (?= (?! (?<= (?<! (?<name>
        SHARED_GROUPS = [":", "=", "!", "<"].freeze
        OPTIONS = Regexp::IGNORECASE | Regexp::EXTENDED | Regexp::MULTILINE

        module_function

        def to_js(match)
          unless match.is_a?(Regexp)
            raise ArgumentError,
              "reactive_media match: must be a Regexp (e.g. /\\A\\d{3}\\z/), got #{match.inspect}"
          end

          unless match.options.nobits?(OPTIONS)
            refuse!(match,
              "has options (i, m, x) the client would read differently — drop them")
          end

          tokens = match.source.scan(/\\.|./m)
          tokens.shift if tokens.first == "\\A"
          final = tokens.pop if %w[\z \Z].include?(tokens.last)
          check!(tokens, match)
          # Ruby's \Z also matches before one final newline.
          final == "\\Z" ? "#{tokens.join}\\n?" : tokens.join
        end

        def check!(tokens, match)
          in_class = false
          tokens.each_with_index do |token, i|
            if RUBY_ONLY_ESCAPES.include?(token)
              refuse!(match,
                "uses #{token}, which is Ruby-only (JavaScript reads it differently)")
            end
            refuse!(match, "has a character above U+FFFF (the client pattern has no u flag)") if token.ord > 0xFFFF
            if token == "\\u" && tokens[i + 1] == "{"
              refuse!(match,
                "uses \\u{…}, which JavaScript without the u flag reads as a repeated u")
            end
            if in_class
              in_class = false if token == "]"
              class_syntax!(tokens, i, match)
            elsif token == "["
              in_class = true
            elsif token == "(" && tokens[i + 1] == "?" && !SHARED_GROUPS.include?(tokens[i + 2])
              refuse!(match, "uses (?#{tokens[i + 2]}…), a group JavaScript does not read the same way")
            end
          end
        end

        # A [ inside a class (a nested class or a POSIX [:digit:]) and && (an
        # intersection) are Ruby-only: JavaScript reads them as literals.
        def class_syntax!(tokens, index, match)
          token = tokens[index]
          return unless token == "[" || (token == "&" && tokens[index + 1] == "&")

          refuse!(match, "has a nested character class, a POSIX [:class:] or && — JavaScript reads them literally")
        end

        def refuse!(match, why)
          raise ArgumentError, "reactive_media match: #{match.inspect} #{why}"
        end
      end
    end
  end
end
