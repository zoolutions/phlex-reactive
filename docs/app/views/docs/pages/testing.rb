# frozen_string_literal: true

module Views
  module Docs
    module Pages
      class Testing < DocsUI::Page
        title 'Testing reactive components'
        eyebrow 'Guide'
        description 'Test reactive Phlex components in Rails across three layers: fast unit tests for actions and signed identity, endpoint integration, and browser system tests'

        def lead
          'Reactive components are plain Ruby objects with a few extra class methods, so most testing is ' \
            'fast unit testing — three layers, cheapest first.'
        end

        def content
          setup
          unit_actions
          unit_driver
          unit_identity
          integration_endpoint
          system_browser
          system_helpers
          client_unit
          troubleshooting
        end

        private

        def setup
          DocsUI::Section('Setup: the public test helpers') do
            DocsUI::Prose() do
              p do
                plain 'Mix in '
                code { 'Phlex::Reactive::TestHelpers' }
                plain ' once. It ships token minting ('
                code { 'reactive_token_for' }
                plain '), the no-HTTP action driver ('
                code { 'run_reactive' }
                plain '), request helpers ('
                code { 'post_reactive_action' }
                plain '/'
                code { 'post_reactive_multipart' }
                plain '), and the '
                code { 'have_reactive_*' }
                plain ' matchers — so you never reach for a private method or hand-roll a POST.'
              end
            end
            DocsUI::Code(<<~RUBY, lexer: :ruby)
              # spec/rails_helper.rb (RSpec)
              RSpec.configure do |c|
                c.include Phlex::Reactive::TestHelpers                  # driver + matchers everywhere
                c.include Phlex::Reactive::TestHelpers, type: :request  # + the HTTP helpers
              end
            RUBY
            DocsUI::Prose() do
              p do
                strong { 'Note' }
                plain ' — '
                code { 'verbose_errors' }
                plain ' defaults ON in test (it only changes an error BODY, never a status). If you '
                plain 'assert an empty failure body, set '
                code { 'Phlex::Reactive.verbose_errors = false' }
                plain ' in your setup.'
              end
            end
          end
        end

        def unit_actions
          DocsUI::Section('1. Unit: actions are just methods') do
            DocsUI::Prose() do
              p { plain 'Build the component, call the action, assert the state changed. No HTTP, no browser.' }
            end
            DocsUI::Code(<<~RUBY, lexer: :ruby)
              test "toggle flips done" do
                todo = todos(:write_docs)         # done: false
                component = Todos::Item.new(todo:)
                component.toggle
                assert todo.reload.done?
              end
            RUBY
          end
        end

        def unit_driver
          DocsUI::Section('2. Unit: run_reactive drives the action through the security contract') do
            DocsUI::Prose() do
              p do
                plain 'Calling the method directly (above) skips what the real endpoint enforces. '
                code { 'run_reactive' }
                plain ' runs the action through the SAME contract — default-deny, the signed identity '
                plain 'round-trip (the record is re-found), schema coercion — with no HTTP, and returns a '
                code { 'Result' }
                plain ' you assert on. So a unit test can\'t pass on a component that would fail a real click.'
              end
            end
            DocsUI::Code(<<~RUBY, lexer: :ruby)
              test "set coerces the :integer param and replaces the component" do
                # The client sends strings; the schema declares count: :integer.
                result = run_reactive(Counter.new(count: 0), :set, count: "42")

                expect(result).to have_reactive_replace("counter")
                expect(result.component.instance_variable_get(:@count)).to eq(42) # cast, not "42"
              end

              test "an undeclared action is denied (default-deny)" do
                expect { run_reactive(Counter.new(count: 0), :drop_table) }
                  .to raise_error(Phlex::Reactive::TestHelpers::UndeclaredReactiveAction)
              end

              test "a deleted record surfaces as RecordNotFound (the endpoint's 404)" do
                item = Todos::Item.new(todo:)
                todo.destroy!
                expect { run_reactive(item, :toggle) }.to raise_error(ActiveRecord::RecordNotFound)
              end

              test "archive removes the row (and carries no replace)" do
                result = run_reactive(Todos::Item.new(todo:), :archive)
                expect(result).to have_reactive_remove(Todos::Item.new(todo:))
              end
            RUBY
            DocsUI::Prose() do
              p do
                plain 'The '
                code { 'Result' }
                plain ' exposes '
                code { 'replace?' }
                plain '/'
                code { 'remove?' }
                plain '/'
                code { 'redirect?' }
                plain '/'
                code { 'redirect_url' }
                plain '/'
                code { 'streams' }
                plain '/'
                code { 'response' }
                plain ', plus '
                code { 'component' }
                plain ' — the instance REBUILT from identity, the one the action actually ran against. '
                plain 'A registered authorization error RAISES (the endpoint maps it to 403); assert with '
                code { 'raise_error' }
                plain '.'
              end
            end
          end
        end

        def unit_identity
          DocsUI::Section('3. Unit: the identity token round-trips') do
            DocsUI::Prose() do
              p do
                plain 'Verify the signed token rebuilds the same component (and that tampering fails). '
                code { 'reactive_token_for' }
                plain ' mints the token the component would — no private '
                code { 'send' }
                plain '.'
              end
            end
            DocsUI::Code(<<~RUBY, lexer: :ruby)
              test "record-backed identity round-trips" do
                todo = todos(:write_docs)
                token = reactive_token_for(Todos::Item.new(todo:))

                payload = Phlex::Reactive.verify(token)
                assert_equal "Todos::Item", payload["c"]

                rebuilt = Todos::Item.from_identity(payload)
                assert_equal todo, rebuilt.instance_variable_get(:@todo)
              end

              test "tampered token is rejected" do
                token = reactive_token_for(Counter.new(count: 1))
                assert_nil Phlex::Reactive.verify(token + "x")
              end
            RUBY
          end
        end

        def integration_endpoint
          DocsUI::Section('4. Integration: the action endpoint') do
            DocsUI::Prose() do
              p do
                plain 'When you want the FULL HTTP round trip (routing, CSRF, the real status codes), '
                code { 'post_reactive_action' }
                plain ' posts a signed token to '
                code { 'Phlex::Reactive.action_path' }
                plain ' the way the client does — pass a component instance (or a class + '
                code { 'payload:' }
                plain ') and assert the turbo-stream response.'
              end
            end
            DocsUI::Code(<<~RUBY, lexer: :ruby)
              test "increment action returns a turbo-stream replace" do
                post_reactive_action(Counter.new(count: 1), :increment)

                assert_response :success
                assert_match %r{<turbo-stream action="replace" target="counter">}, response.body
                assert_match %r{>2<}, response.body   # count incremented 1 -> 2
              end

              test "undeclared action is forbidden" do
                post_reactive_action(Counter.new(count: 1), :drop_table)
                assert_response :forbidden
              end
            RUBY
            DocsUI::Prose() do
              p do
                plain 'For authorization, stub the current user / policy and assert '
                code { ':forbidden' }
                plain ' when the action\'s '
                code { 'authorize!' }
                plain ' should deny.'
              end
              p do
                plain 'When an action returns a '
                code { 'reply.<verb>' }
                plain ', assert on the streams it produces:'
              end
            end
            DocsUI::Code(<<~RUBY, lexer: :ruby)
              test "failed update keeps the replace and appends a flash" do
                # POST a save action with invalid input
                assert_response :success
                assert_match %r{<turbo-stream action="replace" target="counter">}, response.body  # token refreshes
                assert_match %r{<turbo-stream action="append" target="flash">}, response.body     # flash appended
              end

              test "remove action emits a remove and no replace" do
                assert_response :success
                assert_match %r{<turbo-stream action="remove" target="todo_42">}, response.body
                refute_match %r{action="replace"}, response.body   # render_self? is false for remove
              end

              test "redirect rides a 200 reactive:visit, not a 3xx" do
                assert_response :success            # NOT :redirect — the client bails on response.redirected
                assert_match %r{<turbo-stream action="reactive:visit" data-url=".*/articles/}, response.body
              end
            RUBY
            DocsUI::Prose() do
              p do
                code { 'reply.<verb>' }
                plain ' is a plain value object — unit-test it with no HTTP: '
                code { 'c.reply.remove.render_self?' }
                plain ' is '
                code { 'false' }
                plain '; '
                code { 'c.reply.replace.flash(:x, "hi").streams.size' }
                plain ' is '
                code { '2' }
                plain '.'
              end
            end
          end
        end

        def system_browser
          DocsUI::Section('5. System / browser: the full loop & broadcasts') do
            DocsUI::Prose() do
              p do
                plain 'Use a system test (Capybara) or a browser-automation CLI for the end-to-end loop ' \
                      'and cross-tab broadcasts. The key assertions:'
              end
              ul do
                li do
                  plain 'Clicking a trigger updates the component '
                  strong { 'without a full page reload' }
                  plain ' (assert a value set on '
                  code { 'window' }
                  plain ' survives the interaction).'
                end
                li { plain 'A change in one session appears in another subscribed session.' }
              end
            end
            DocsUI::Code(<<~RUBY, lexer: :ruby)
              # system test sketch
              test "counter increments without reload" do
                visit counter_path
                page.execute_script("window.__marker = 'alive'")
                click_button "+"
                assert_selector "#counter .value", text: "1"
                assert_equal "alive", page.evaluate_script("window.__marker")  # no reload
              end
            RUBY
            DocsUI::Prose() do
              p do
                plain 'For cross-tab, open two sessions (two '
                code { 'Capybara::Session' }
                plain 's or two browser contexts), act in one, and assert the morph appears in the other. ' \
                      'Allow a beat for the SSE round trip.'
              end
              p do
                strong { 'The transport matrix.' }
                plain ' The gem is transport-agnostic — a reactive round trip must work on ' \
                      'Action Cable AND pgbus. Its own CI proves this by running the browser suite ' \
                      'across '
                code { 'server × transport' }
                plain ' (Puma/Falcon × cable/pgbus). The '
                code { 'cable' }
                plain ' cells run on SQLite; the '
                code { 'pgbus' }
                plain ' cells add a plain '
                code { 'postgres:18' }
                plain ' (pgbus vendors the PGMQ schema via its own migrations — no extension image) ' \
                      'and set '
                code { 'TRANSPORT=pgbus' }
                plain ', so the same specs run over real Postgres-backed SSE. A handful of '
                code { ':pgbus' }
                plain '-tagged specs additionally prove real cross-tab delivery and actor-echo ' \
                      'exclusion (the '
                code { 'exclude: reactive_connection_id' }
                plain ' contract) end to end.'
              end
            end
            DocsUI::Code(<<~BASH, lexer: :shell)
              # both servers, Action Cable (the default local sweep)
              bundle exec rake spec:system_servers

              # the full matrix: puma/falcon × cable/pgbus (needs local Postgres;
              # the pgbus cells skip with a note when Postgres isn't reachable)
              bundle exec rake spec:system_matrix

              # one pgbus cell by hand
              bundle exec rake pgbus:prepare_test_db          # once, sets up the DB
              TRANSPORT=pgbus CAPYBARA_SERVER=falcon bundle exec rspec spec/system
            BASH
          end
        end

        def system_helpers
          DocsUI::Section('6. System helpers: wait on the reactive layer, re-resolve by id') do
            DocsUI::Prose() do
              p do
                plain 'A reactive morph, a '
                code { 'reactive_compute' }
                plain ' re-seed, or an in-flight round trip can replace DOM nodes '
                strong { 'after' }
                plain ' the triggering action returns — so a Capybara node held by '
                code { 'find' }
                plain ' detaches ('
                code { 'StaleReferenceError' }
                plain ') and '
                code { 'have_field(with:)' }
                plain ' can read a transient blank before the value settles. '
                code { 'wait_for_turbo' }
                plain ' does not help — it watches the Turbo progress bar, not a reactive morph.'
              end
              p do
                plain 'The client exposes a '
                strong { 'global activity signal' }
                plain ' for exactly this: a '
                code { 'data-reactive-active' }
                plain ' marker on '
                code { '<html>' }
                plain ' (present while any dispatch or deferred render is in flight) plus '
                code { 'reactive:busy' }
                plain ' / '
                code { 'reactive:idle' }
                plain ' events on '
                code { 'document' }
                plain '. '
                code { 'Phlex::Reactive::TestHelpers::System' }
                plain ' — loaded only when Capybara is present — waits on it:'
              end
              ul do
                li do
                  code { 'wait_for_reactive' }
                  plain ' — block until the whole layer is idle (every round trip AND deferred render settled). The system twin of '
                  code { 'wait_for_turbo' }
                  plain '.'
                end
                li do
                  code { 'have_reactive_value(id, value)' }
                  plain ' — assert a field by RE-RESOLVING it every poll (by id or name) and reading its live '
                  code { '.value' }
                  strong { ' property' }
                  plain ', not the value attribute. A '
                  code { 'reactive_compute' }
                  plain ' reducer paints a computed output with '
                  code { 'el.value = …' }
                  plain '; for a '
                  strong { 'disabled' }
                  plain ' output the attribute never reflects that, so an attribute matcher reads blank — the property read sees it. Immune to a morph detaching the node.'
                end
                li do
                  code { 'have_reactive_text(id, value)' }
                  plain ' — the mirror/recap twin for a text sink (textContent), re-resolving by id each poll.'
                end
                li do
                  code { 'have_reactive_requests(n, kind: nil)' }
                  plain ' — assert exactly '
                  code { 'n' }
                  plain ' reactive requests ('
                  code { ':action' }
                  plain ', '
                  code { ':defer' }
                  plain ', or any kind) since the last '
                  code { 'reset_reactive_requests!' }
                  plain ', waiting until nothing is in flight. '
                  code { 'reactive_request_count' }
                  plain ' returns the totals ('
                  code { '{ action: 1, defer: 0 }' }
                  plain '). The client keeps them on '
                  code { '<html data-reactive-requests>' }
                  plain ' only under the verbose gate (on in dev/test), so production writes nothing. '
                  plain 'No fetch spy: requests made before the spec looks are counted, and unrelated fetches are not.'
                end
              end
            end
            DocsUI::Code(<<~RUBY, lexer: :ruby)
              # rails_helper.rb — mix into system examples (Capybara-gated)
              RSpec.configure do |c|
                c.include Phlex::Reactive::TestHelpers::System, type: :system
              end

              # spec/system/…_spec.rb
              it "settles the deferred total, no stale read" do
                visit "/order"
                find("[data-testid='bump']").click

                wait_for_reactive                          # round trip + defer settled
                expect(page).to have_reactive_value("total", "6")   # re-resolves by id
                expect(page).to have_reactive_text("recap", "6 items")
              end

              it "loads the panel once" do
                visit "/"
                reset_reactive_requests!                   # baseline (also after a Turbo visit)
                find("#open-panel").click
                expect(page).to have_reactive_requests(1)  # waits, then exact count
                find("#close-panel").click
                find("#open-panel").click
                expect(page).to have_reactive_requests(1)  # still one: reused
                expect(page).to have_reactive_requests(0, kind: :defer)
              end
            RUBY
          end
        end

        def client_unit
          DocsUI::Section('7. Client unit tests (bun)') do
            DocsUI::Prose() do
              p do
                plain 'Some client-runtime contracts are timing-sensitive and a full browser can mask them — ' \
                      'e.g. a '
                code { 'submit' }
                plain ' trigger must '
                code { 'preventDefault()' }
                plain ' '
                strong { 'synchronously' }
                plain ' during the event, which a system test in a minimal app can\'t reliably reproduce. ' \
                      'Those are covered by fast bun unit tests against the controller in isolation:'
              end
            end
            DocsUI::Code('bun test spec/javascript     # or: bun run test', lexer: :shell)
            DocsUI::Prose() do
              p do
                plain 'They stub '
                code { '@hotwired/stimulus' }
                plain ' and assert behavior directly (e.g. '
                code { 'dispatch()' }
                plain ' calls '
                code { 'preventDefault()' }
                plain ' before its queued work). CI runs them in the System job, which already has bun set up. ' \
                      'The system suite drives a '
                strong { 'vendored copy' }
                plain ' of the controller ('
                code { 'spec/dummy/public/vendor/reactive_controller.js' }
                plain '); a guard spec keeps it byte-identical to source, so edit the source and re-sync, ' \
                      'never the copy.'
              end
            end
          end
        end

        def troubleshooting
          DocsUI::Section('Troubleshooting') do
            DocsUI::Prose() do
              ul do
                li do
                  strong { 'Click does nothing, count stays 0' }
                  plain ' — the controller lazy-loaded and you clicked before connect. Register '
                  code { 'reactive' }
                  plain ' '
                  strong { 'eagerly' }
                  plain '.'
                end
                li do
                  strong { 'Click reloads the whole page' }
                  plain ' — a bare '
                  code { '<button>' }
                  plain ' defaulted to '
                  code { 'type=submit' }
                  plain ' in a form. '
                  code { 'on(:click)' }
                  plain ' already sets '
                  code { 'type=button' }
                  plain '; ensure you spread it.'
                end
                li do
                  strong { '403 from the endpoint' }
                  plain ' — undeclared action, or '
                  code { 'authorize!' }
                  plain ' denied. Declare the '
                  code { 'action' }
                  plain '; check the policy.'
                end
                li do
                  strong { '400 from the endpoint' }
                  plain ' — token tampered, or the '
                  code { 'action' }
                  plain ' key collided. Use the '
                  code { 'act' }
                  plain ' wire key (the gem does); don\'t rename it.'
                end
                li do
                  strong { 'Rapid clicks lose updates' }
                  plain ' — (shouldn\'t happen) a stale-token race. The runtime queues + threads tokens; ' \
                        'file a bug with a repro.'
                end
                li do
                  strong { 'Cross-tab not syncing' }
                  plain ' — subscriber/broadcaster stream keys differ. Pass the '
                  strong { 'same raw *streamables' }
                  plain ' to '
                  code { 'turbo_stream_from' }
                  plain ' and '
                  code { 'broadcast_to' }
                  plain '.'
                end
                li do
                  strong { 'Action POST redirected to /sign_in' }
                  plain ' — an auth filter on a public component. '
                  code { 'skip_before_action :authenticate' }
                  plain ' on the endpoint, or keep it state-backed.'
                end
              end
            end
          end
        end
      end
    end
  end
end
