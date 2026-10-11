# frozen_string_literal: true

module Phlex
  module Reactive
    # A presence stream changed (issue #358): a tab joined, left, or expired.
    # Re-render the roster as the table is when the job runs — not the change
    # it was enqueued for — and morph it into every viewer's tab. A page
    # reload (a leave, then a join within milliseconds) therefore renders the
    # seat present, and coalescing folds the pair into one morph.
    #
    # Enqueued by Phlex::Reactive::Presence.changed, the transport's change
    # hook, which runs on the SSE dispatcher thread: rendering there would hold
    # it up. On defer_job_queue, like the push lane's render job.
    #
    # NOT eager-loaded (see the loader config in phlex/reactive.rb): the class
    # body needs ActiveJob::Base, which isn't a gem dependency — the constant
    # is only referenced behind Phlex::Reactive::Presence.capable?.
    class PresenceRenderJob < ::ActiveJob::Base
      queue_as { Phlex::Reactive.defer_job_queue }

      def perform(stream_name)
        Phlex::Reactive::Presence.render_roster(stream_name)
      end
    end
  end
end
