# frozen_string_literal: true

# System/browser test helpers for reactive components (issue #201). Loaded lazily
# by Phlex::Reactive::TestHelpers ONLY when Capybara is present (the pgbus/mcp
# optional-require precedent), so the gem never hard depends on Capybara and this
# module stays out of the request/unit path.
#
# Mix it into your system examples from rails_helper:
#
#   RSpec.configure do |c|
#     c.include Phlex::Reactive::TestHelpers::System, type: :system
#   end
#
# It is built on the GLOBAL reactive-activity signal the client runtime exposes:
# a <html data-reactive-active> marker present while ANY reactive operation (a
# dispatch round trip OR a deferred render) is in flight, cleared when the whole
# layer settles. That is the clean primitive to wait on — instead of each spec
# scraping the union of per-root busy/pending/seed selectors, or holding a node
# that a morph detaches (StaleReferenceError).
#
#   wait_for_reactive                       # block until the layer is idle
#   expect(page).to have_reactive_value("total", "6")  # a field, re-resolved each poll
#   expect(page).to have_reactive_text("recap", "6 items") # a mirror node, re-resolved
#
# All three re-resolve the DOM every poll cycle (Capybara's waiting behavior), so
# a compute re-seed / morph / in-flight round trip that REPLACES the node after
# the triggering action returns can never surface a StaleReferenceError or read a
# transient blank — the matcher waits for the value to SETTLE.
module Phlex
  module Reactive
    module TestHelpers
      module System
        # The <html> marker the client sets while the reactive layer is busy. Kept
        # in lockstep with reactive_controller.js's ACTIVE_ATTR — the ONE selector
        # every wait keys off. A [data-reactive-active] presence check is the system
        # twin of wait_for_turbo watching the Turbo progress bar.
        ACTIVE_MARKER = "data-reactive-active"

        # The <html> attribute the client keeps its per-kind request totals in
        # (issue #279), as JSON ({"action":1,"defer":0}). Lockstep with
        # reactive_controller.js REQUESTS_ATTR. Written only under the verbose
        # gate (dev/test by default).
        REQUESTS_ATTR = "data-reactive-requests"

        # Parse the attribute value into { action:, defer: } Integers — zeros for
        # an absent or garbled value. Shared by the helpers and
        # ReactiveRequestsMatcher.
        def self.parse_reactive_requests(raw)
          parsed = raw.is_a?(::String) ? ::JSON.parse(raw) : {}
          parsed = {} unless parsed.is_a?(::Hash)
          { action: reactive_request_total(parsed["action"]), defer: reactive_request_total(parsed["defer"]) }
        rescue ::JSON::ParserError
          { action: 0, defer: 0 }
        end

        # One total as an Integer. Only a number or a numeric string counts; any
        # other JSON value (array, object, boolean, null) is garbled, so zero.
        def self.reactive_request_total(value)
          value.is_a?(::Numeric) || value.is_a?(::String) ? value.to_i : 0
        end
        private_class_method :reactive_request_total

        # Block until the reactive layer is IDLE — every dispatch round trip and
        # deferred render has settled and the <html data-reactive-active> marker is
        # gone. The system-test twin of wait_for_turbo (which watches the Turbo
        # progress bar, NOT a reactive morph/seed, so it can't cover this).
        #
        # Implemented as a Capybara WAITING assertion (have_no_css on the document
        # element with the default max wait), so it re-checks the live DOM each poll
        # and raises a readable Capybara::ElementNotFound-style error if the layer
        # never settles inside `timeout` — never a bare sleep, never a stale read.
        #
        # `timeout:` overrides Capybara.default_max_wait_time for a slow operation
        # (a deferred render behind a real job). Returns nil; call it as a barrier
        # BEFORE asserting a settled value if you are not already using one of the
        # waiting matchers below.
        def wait_for_reactive(timeout: nil)
          # Scope the check to <html> via the :xpath "/html" so the marker is read
          # on the document element the client writes it to — not a descendant.
          # assert_no_selector WAITS (retries) until the marker clears or the wait
          # budget elapses; a persistent marker fails LOUDLY with Capybara's own
          # timeout error rather than a silent pass. Called on `page` (the current
          # session) so it works regardless of whether the example group mixed in
          # Capybara::DSL.
          page.assert_no_selector(:xpath, "/html[@#{ACTIVE_MARKER}]", **wait_option(timeout))
          nil
        end

        # Assert (waiting) that the field with DOM id `id` has value `value`,
        # RE-RESOLVING the field by its id on every poll and reading its live
        # `.value` PROPERTY (issue #204) — NOT the value attribute. A
        # reactive_compute reducer paints a computed output with `el.value = …`
        # (the property); for a DISABLED / read-only output the value attribute
        # never reflects that, so an attribute-based matcher reads "" and fails.
        # Reading the property covers enabled AND disabled/computed fields — the
        # exact case this matcher was built for — and keeps the morph-immunity
        # (each poll re-finds the node by id, so a re-seed/morph that replaces the
        # input can't surface a stale node or a transient blank).
        #
        #   expect(page).to have_reactive_value("total", "6")
        #
        # `timeout:` (or `wait:`) overrides Capybara's default max wait. The
        # `have_` prefix is Capybara-matcher convention (have_field/have_css), NOT
        # a predicate — hence the PredicatePrefix disable, mirroring matchers.rb.
        # rubocop:disable Naming/PredicatePrefix
        def have_reactive_value(id, value, timeout: nil, wait: nil)
          ReactiveValueMatcher.new(id, value, wait: timeout || wait)
        end

        # Assert (waiting) that the node with DOM id `id` has TEXT `value`,
        # re-resolving by id each poll — the mirror/recap twin of
        # have_reactive_value for a text sink (a reactive_compute `text:`/mirror
        # target, a recap node) rather than a form field.
        #
        #   expect(page).to have_reactive_text("recap", "6 items")
        def have_reactive_text(id, value, **)
          have_css("##{id}", text: value, **)
        end

        # How many reactive requests the page has made since the last
        # reset_reactive_requests! (or since the page loaded), per kind (issue
        # #279):
        #
        #   reactive_request_count # => { action: 1, defer: 0 }
        #
        # A snapshot, not a wait — barrier on wait_for_reactive (or use
        # have_reactive_requests) before reading it after a gesture.
        def reactive_request_count
          System.parse_reactive_requests(
            page.evaluate_script("document.documentElement.getAttribute(#{REQUESTS_ATTR.to_json})")
          )
        end

        # Baseline the request totals to zero. The attribute IS the client's
        # store, so writing zeros re-baselines it — including after a Turbo Drive
        # visit, where the <html> element (and its totals) survives navigation.
        def reset_reactive_requests!
          zeros = { action: 0, defer: 0 }.to_json
          page.execute_script("document.documentElement.setAttribute(#{REQUESTS_ATTR.to_json}, '#{zeros}')")
          nil
        end

        # Assert (waiting) that exactly `count` reactive requests were made — of
        # `kind` (:action or :defer), or of any kind — since the last reset, AND
        # that nothing is still in flight. Fails at once if the count overshoots
        # (totals only grow until a reset).
        #
        #   reset_reactive_requests!
        #   find("#open-panel").click
        #   expect(page).to have_reactive_requests(1)
        #   expect(page).to have_reactive_requests(0, kind: :defer)
        def have_reactive_requests(count, kind: nil, timeout: nil, wait: nil)
          ReactiveRequestsMatcher.new(count, kind:, wait: timeout || wait)
        end
        # rubocop:enable Naming/PredicatePrefix

        # A waiting matcher that asserts a field's live `.value` PROPERTY (issue
        # #204), read by id via evaluate_script so it sees a value a reducer set
        # on a DISABLED output (where the value attribute stays blank). Polls until
        # the property equals the expected value or the wait budget elapses,
        # re-resolving the node by id every cycle (morph-immune). Supports negation
        # (`not_to`) the Capybara way: the negative holds as soon as the property
        # differs from the expected value (an absent field reads nil, which never
        # equals a String expectation — so a missing field satisfies `not_to`).
        #
        # A plain class (not RSpec::Matchers.define) so it needs no RSpec at load
        # time beyond the duck-typed matcher protocol RSpec calls (matches?,
        # does_not_match?, failure_message*), keeping System loadable under Capybara
        # alone. The expected value is stringified because a DOM `.value` is always
        # a JS string on the wire (a numeric literal like 6 compares as "6").
        class ReactiveValueMatcher
          def initialize(id, value, wait: nil)
            @id = id
            @expected = value.to_s
            @wait = wait
          end

          def matches?(page)
            @page = page
            poll_until { current_value == @expected }
          end

          # does_not_match? is RSpec's REQUIRED negated-matcher protocol method — its
          # name is fixed by RSpec, not a predicate we get to rename.
          # rubocop:disable-next Naming/PredicatePrefix
          def does_not_match?(page)
            @page = page
            # The negative is satisfied the moment the property is NOT the expected
            # value (or the field is absent → nil). poll_until returns true as soon
            # as that holds, false if it stayed equal for the whole budget.
            poll_until { current_value != @expected }
          end

          def failure_message
            "expected ##{@id} to have value #{@expected.inspect} (its .value property), " \
              "but after waiting it was #{current_value.inspect}"
          end

          def failure_message_when_negated
            "expected ##{@id} NOT to have value #{@expected.inspect} (its .value property), but it did"
          end

          private

          # The field's live `.value` property, re-resolved each call. The
          # identifier is matched by DOM id OR name (mirroring Capybara's
          # have_field, which matches id/name/label) — reactive_field emits a
          # `name`, not an `id`, so an id-only lookup would find nothing. Returns
          # the String value, or nil when the field is absent (Playwright serializes
          # a JS null as an empty Hash, so a non-String result is normalized to nil
          # — the matcher then treats it as "not settled yet" and keeps polling
          # rather than comparing a Hash to the expected String).
          def current_value
            raw = @page.evaluate_script(<<~JS)
              (() => {
                const k = #{@id.to_json}
                const el = document.getElementById(k) || document.getElementsByName(k)[0]
                return el ? el.value : null
              })()
            JS
            raw.is_a?(::String) ? raw : nil
          end

          # Bounded poll on a JS-property condition Capybara can't express as a
          # built-in waiting matcher. Uses the monotonic clock and the configured
          # (or overridden) Capybara max wait — the same shape the system specs'
          # hand-rolled wait_for used, now lifted into the helper.
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

        private

        # Fold an explicit `timeout:` into Capybara's `wait:` option, or omit it so
        # Capybara's configured default applies. Kept tiny so every waiter shares
        # one timeout convention.
        def wait_option(timeout)
          timeout.nil? ? {} : { wait: timeout }
        end
      end
    end
  end
end

require "phlex/reactive/test_helpers/system/reactive_requests_matcher"
