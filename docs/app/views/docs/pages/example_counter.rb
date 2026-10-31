# frozen_string_literal: true

module Views
  module Docs
    module Pages
      class ExampleCounter < DocsUI::Page
        title 'Example: counter (the smallest reactive component)'
        eyebrow 'Examples'
        description 'Build the smallest reactive Phlex counter in Rails: signed reactive_state, a typed param schema, default-deny actions, and rapid-click concurrency handled'

        def lead
          'A record-less counter — the minimal thing that demonstrates ' \
            'client → server → re-render. Use this to sanity-check your install.'
        end

        def content
          live
          component
          rendering
          notes
        end

        private

        def live
          DocsUI::Section('Try it') do
            md <<~MD
              This is a **real** reactive component rendered right here — not a
              screenshot. Click the buttons; each click POSTs to
              `/reactive/actions`, the server rebuilds the component from its
              signed token, runs the action, and re-renders in place.
            MD
            render CounterComponent.new(count: 0)
          end
        end

        def component
          DocsUI::Section('The component') do
            md <<~MD
              One `include` is the whole setup: `include Phlex::Reactive::Component`
              pulls in `Streamable` automatically. Sign the count into the DOM with
              `reactive_state`, and declare the actions a click may invoke.
            MD
            DocsUI::Code(component_source, lexer: :ruby, filename: 'app/components/counter.rb')
          end
        end

        def rendering
          DocsUI::Section('Render it anywhere') do
            DocsUI::Code('render Counter.new(count: 0)', lexer: :ruby)
          end
        end

        def notes
          DocsUI::Section('Notes') do
            md <<~MD
              - `reactive_state :count` signs the count into the DOM token. On each
                action the server rebuilds `Counter.new(count: <verified>)`, runs
                the method, and re-renders. The new count is signed into the next
                token automatically.
              - `on(:set, count: 0)` passes an explicit param. Explicit params win
                over any collected form fields.
              - `action :set, params: { count: :integer }` declares a **typed**
                param. The schema is compiled once, at class load — so a typo'd type
                symbol (`{ count: :interger }`) raises
                `Phlex::Reactive::UnknownParamType` immediately, not silently at
                click time. `:integer` casts with `to_i`, so a blank value arrives
                as `0` and `"12abc"` as `12`. Declare `:strict_integer` to drop both
                instead, so the keyword default applies.
              - Actions are **default-deny** — only methods declared with `action`
                are invokable. In development and test (`verbose_errors`), an
                undeclared or typo'd action (`on(:increement)`) fails loudly at
                **render** time, listing the declared actions, instead of surfacing
                as an opaque HTTP 403 at click time.
              - **Concurrency is handled.** Click `+` five times fast and you get
                `5` — the client serializes requests per component and threads the
                fresh token through, so rapid clicks don't clobber each other.
            MD
            DocsUI::Callout(:tip) do
              md <<~MD
                This is record-less on purpose. For anything backed by data, prefer
                `reactive_record` so state lives in the DB.
              MD
            end
          end
        end

        def component_source
          <<~RUBY
            # app/components/counter.rb
            class Counter < ApplicationComponent
              include Phlex::Reactive::Component            # pulls in Streamable too

              reactive_state :count                       # signed state (no DB row)
              action :increment
              action :decrement
              action :set, params: { count: :integer }    # action with a typed param

              def initialize(count: 0) = @count = count
              def id = "counter"

              def increment = @count += 1
              def decrement = @count -= 1
              def set(count:) = @count = count

              def view_template
                div(**reactive_root(class: "counter")) do
                  button(**on(:decrement)) { "−" }
                  span(class: "value") { @count }
                  button(**on(:increment)) { "+" }
                  button(**on(:set, count: 0)) { "reset" }   # explicit param via on(...)
                end
              end
            end
          RUBY
        end
      end
    end
  end
end
