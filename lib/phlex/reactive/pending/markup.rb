# frozen_string_literal: true

module Phlex
  module Reactive
    module Pending
      # The opt-in pending MARKUP hook (issue #249). The #248 markers dim a live
      # row; some apps want the pending state to be honest markup instead — a
      # real "Queued" badge, a button that is genuinely gone. A row component
      # opts in by defining `pending_template` (private is fine), and
      # reply.pending then ALSO replaces the row with that markup:
      #
      #   class TransferRow < ApplicationComponent
      #     def view_template = li(id:, **reactive_attrs) { ...; button(**on(:retry)) { "Retry" } }
      #
      #     private
      #
      #     def pending_template = li(id:, **reactive_attrs) { ...; span(class: "badge") { "Queued" } }
      #   end
      #
      # It is a TEMPLATE method, not a content method like `deferred_placeholder`
      # (#165): there the gem owns the shell div and the component supplies what
      # goes inside; here the row's own root is swapped, so the hook renders it.
      #
      # ## Why a subclass
      #
      # Phlex 2 compiles templates per class, so the swap cannot be a per-instance
      # method. Each opted-in row class gets ONE memoized anonymous subclass whose
      # view_template is the pending template. Two contracts make that safe:
      #
      #   * The variant's `.name` is the PARENT's. A row that includes Component
      #     signs its class name into its token; an anonymous name cannot
      #     constantize, so the row's next action would 400.
      #   * The memo holds classes derived from reloadable ones, so the engine
      #     resets it on Rails code reload (config.to_prepare), exactly like the
      #     view-context and stream-builder memos.
      #
      # ## Un-pending is the settle's job
      #
      # The markers are attributes, so any settle can strip them. Swapped markup
      # is not: only a settle that REPLACES or REMOVES the row puts it back. A
      # flash-only settle, `finish: true` or a failed job clears the markers but
      # leaves the pending markup in place.
      module Markup
        HOOK = :pending_template

        # Keyed weakly on the row class (the Streamable registry's shape), so a
        # class Zeitwerk replaced is not pinned between resets.
        @variants = ObjectSpace::WeakMap.new
        @mutex = Mutex.new

        class << self
          # The row's pending markup as HTML, or nil when the row has no hook
          # (or the target is a bare DOM id String — there is no component to
          # render). Rendered through the PARENT's render_component: the variant
          # is never registered with Streamable, so this reuses the parent's
          # memoized, reload-reset view context and its instrumentation name.
          def render(row)
            return nil unless row.is_a?(Phlex::Reactive::Streamable) && row.respond_to?(HOOK, true)

            html = row.class.render_component(variant_instance(row))
            assert_keeps_id!(row, html)
            html
          end

          # The replace stream that swaps one row to its pending markup.
          def stream(target_id, html)
            Phlex::Reactive::Stream.wrap(
              Phlex::Reactive.stream_builder.replace(target_id, html: html.html_safe),
              action: "replace", target: target_id, renders_root: true
            )
          end

          def variant_for(row_class)
            @mutex.synchronize { @variants[row_class] ||= build_variant(row_class) }
          end

          # Called from the engine's config.to_prepare (Rails code reload).
          def reset!
            @mutex.synchronize { @variants = ObjectSpace::WeakMap.new }
          end

          private

          def build_variant(row_class)
            Class.new(row_class) do
              def self.name = superclass.name

              def view_template = pending_template
            end
          end

          # A variant instance carrying the built row's state. allocate + copy
          # rather than re-running initialize: the row may have been handed to
          # reply.pending already built, with arguments the gem never saw.
          def variant_instance(row)
            variant = variant_for(row.class).allocate
            row.instance_variables.each { variant.instance_variable_set(it, row.instance_variable_get(it)) }
            variant
          end

          # A pending template that drops the row's id leaves the settle nothing
          # to target: its replace/remove would miss and the row would say
          # "Queued" forever. Fail at the action, before anything is enqueued.
          def assert_keeps_id!(row, html)
            return if html.include?(%(id="#{ERB::Util.html_escape(row.id)}"))

            raise Phlex::Reactive::Error,
              "#{row.class.name}#pending_template must render the row's root with its id " \
              "(id=\"#{row.id}\") — the settle targets that id to replace or remove the row. " \
              "Render the root as in view_template, e.g. li(id:, **reactive_attrs) { ... }."
          end
        end
      end
    end
  end
end
