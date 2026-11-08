# frozen_string_literal: true

module Phlex
  module Reactive
    module TestHelpers
      module System
        # Raised by wait_for_reactive when the busy window it waited on ended with
        # failures (issue #464): the client's <html data-reactive-errors> list.
        #
        #   reactive action "increment" failed (http 500) on #flaky-counter
        #
        # #errors is that list, each entry { action:, kind:, status:, root: }.
        class ReactiveReplyError < StandardError
          attr_reader :errors

          def initialize(errors)
            @errors = errors
            super(errors.map { describe(it) }.join("; "))
          end

          private

          def describe(error)
            subject = error[:action] ? %(action "#{error[:action]}") : error[:kind].to_s
            reason = [error[:kind], error[:status]].compact.join(" ")
            "reactive #{subject} failed (#{reason})#{" on ##{error[:root]}" if error[:root]}"
          end
        end
      end
    end
  end
end
