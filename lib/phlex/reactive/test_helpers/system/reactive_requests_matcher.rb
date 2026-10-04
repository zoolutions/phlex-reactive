# frozen_string_literal: true

require "json"

module Phlex
  module Reactive
    module TestHelpers
      module System
        # The waiting matcher behind have_reactive_requests (issue #279). Reads the
        # client's per-kind request totals (<html data-reactive-requests>, JSON)
        # AND the in-flight marker in ONE evaluate_script per poll, and holds once
        # the selected total equals `expected` with the layer idle, so a request
        # still in flight is never counted early. It cannot see a request that has
        # not STARTED yet (a debounced trigger, or the defer an action's reply is
        # about to start): barrier on the UI outcome first for those.
        #
        # Totals only grow until reset_reactive_requests!, so a total ABOVE the
        # expectation is terminal: the matcher fails at once instead of waiting out
        # the budget. A plain class (no RSpec::Matchers.define), like
        # ReactiveValueMatcher, so System stays loadable under Capybara alone.
        class ReactiveRequestsMatcher
          KINDS = %i[action defer].freeze

          def initialize(expected, kind: nil, wait: nil)
            unless kind.nil? || KINDS.include?(kind)
              raise ArgumentError, "unknown reactive request kind #{kind.inspect} (expected one of #{KINDS.inspect} or nil)"
            end

            @expected = Integer(expected)
            @kind = kind
            @wait = wait
          end

          def matches?(page)
            @page = page
            poll_until do
              read_state
              break false if selected > @expected

              selected == @expected && !@active
            end
          end

          # RSpec's required negated-matcher protocol name, not a predicate we pick.
          # rubocop:disable-next Naming/PredicatePrefix
          def does_not_match?(page)
            @page = page
            poll_until do
              read_state
              selected != @expected && !@active
            end
          end

          def failure_message
            message = "expected #{@expected} reactive #{noun} (#{scope}), got #{selected} — totals #{totals_str}"
            return message if @verbose

            "#{message}. The verbose gate is closed, so the client is not counting: it writes " \
              "<html #{REQUESTS_ATTR}> only under Phlex::Reactive.verbose_errors (on in dev/test " \
              "by default) or data-reactive-verbose on <html>"
          end

          def failure_message_when_negated
            "expected the reactive request count (#{scope}) NOT to be #{@expected}, but it was — totals #{totals_str}"
          end

          private

          def read_state
            raw = @page.evaluate_script(<<~JS)
              (() => {
                const html = document.documentElement
                return {
                  requests: html.getAttribute(#{REQUESTS_ATTR.to_json}),
                  active: html.hasAttribute(#{ACTIVE_MARKER.to_json}),
                  verbose: html.hasAttribute("data-reactive-verbose") ||
                    !!document.querySelector('[data-reactive-verbose="true"]'),
                }
              })()
            JS
            raw = {} unless raw.is_a?(::Hash)
            @verbose = raw["verbose"] == true
            @totals = System.parse_reactive_requests(raw["requests"])
            @active = raw["active"] == true
          end

          def selected = @kind ? @totals[@kind] : @totals.values.sum

          def scope = @kind ? "kind: #{@kind.inspect}" : "any kind"

          def noun = @expected == 1 ? "request" : "requests"

          def totals_str = "{#{@totals.map { |k, v| "#{k}: #{v}" }.join(", ")}}"

          # Same bounded, monotonic-clock poll as ReactiveValueMatcher. A `break
          # false` inside the block ends the poll early (a terminal mismatch).
          def poll_until
            deadline = now + (@wait || ::Capybara.default_max_wait_time)
            loop do
              return true if yield
              return false if now >= deadline

              sleep 0.05
            end
          end

          def now = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
        end
      end
    end
  end
end
