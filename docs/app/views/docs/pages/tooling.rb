# frozen_string_literal: true

module Views
  module Docs
    module Pages
      # The debugging & tooling guide (issue #168): the four-surface toolkit —
      # doctor, the server inventory (rake + MCP), the browser inspector, and the
      # verify_authorized guard — plus the by-name server↔client mapping that ties
      # them together.
      class Tooling < DocsUI::Page
        title 'Debugging & tooling'
        eyebrow 'Guide'
        description 'Debug phlex-reactive: the doctor install validator, the action inventory (rake tasks + MCP server), ' \
                    'the on-demand browser inspector, and the fail-closed verify_authorized guard.'

        def lead
          'When a reactive click "does nothing," the failure is almost always at one of the RPC seams. ' \
            'phlex-reactive ships four introspection surfaces to name it fast — and one guard that turns a ' \
            'forgotten authorize! into a loud error instead of a silent hole.'
        end

        def content
          overview
          doctor
          inventory
          inspector
          mapping
          verify_authorized
          mcp
          skill
          failure_table
        end

        private

        def overview
          DocsUI::Section('The four surfaces') do
            md <<~MD
              Work top-down — validate the install, inventory the server, find the
              specific component, scan the live page — and stop as soon as a step
              names the problem.

              | Surface | Command | Answers |
              |---|---|---|
              | **Doctor** | `bin/rails phlex_reactive:doctor` | is the install wired correctly? |
              | **Inventory** | `bin/rails phlex_reactive:actions` / `find` | what actions exist, where, authorized? |
              | **Browser inspector** | `import("phlex/reactive/inspect")` | what's reactive on THIS page? |
              | **MCP server** | `bin/rails phlex_reactive:mcp` | all of the above, queryable in your editor |

              Everything is **read-only** and reports **names, paths, and declared
              schemas only** — never a token, a secret, or runtime state.
            MD
          end
        end

        def doctor
          DocsUI::Section('Doctor — validate the install') do
            md <<~MD
              The first thing to run. `phlex_reactive:doctor` prints a ✓/✗/? line
              for every seam and a fix for each failure:
            MD
            DocsUI::Code(<<~SHELL, lexer: :shell)
              bin/rails phlex_reactive:doctor
            SHELL
            md <<~MD
              It checks that `POST /reactive/actions` routes to the gem (a host
              catch-all route shadows it otherwise), the generic `reactive`
              Stimulus controller is registered, the identity verifier round-trips,
              every declared `action :name` has a public method, every component
              resolves a stable `#id`, and — **advisory only** — whether each
              mutating action appears to authorize. Most "nothing happens" reports
              are a red ✗ here.

              With dormant roots (`reactive_dormant`) it also looks for
              `import "phlex/reactive/early"` in app JavaScript and in inline
              module scripts under `app/views` and `app/components`, and names
              the file. Each import map that lacks the `phlex/reactive/early`
              pin gets an advisory `?` line: `Rails.application.importmap` is
              checked by default, and
              `Phlex::Reactive.importmaps = -> { { "landing" => landing_map } }`
              adds the maps you keep elsewhere.

              It fails when Falcon serves the app and
              `config.active_support.isolation_level` is still `:thread`: Falcon
              runs each request as a fiber on one thread, so thread-keyed state is
              shared between requests (the fix is `:fiber`, see
              [Running under Falcon](/docs/installation#running-under-falcon)).
              It reads the bundle without loading a server; when Falcon is bundled
              beside another server and Falcon itself is not loaded, the line is
              advisory.
            MD
          end
        end

        def inventory
          DocsUI::Section('Inventory — what actions exist (server side)') do
            md <<~MD
              Answer "what reactive actions exist in this app, where are they
              defined, and is each authorized?" without grepping:
            MD
            DocsUI::Code(<<~SHELL, lexer: :shell)
              bin/rails phlex_reactive:actions             # component | action | params | file:line | auth
              bin/rails phlex_reactive:actions FORMAT=json # machine-readable
              bin/rails phlex_reactive:actions UNVERIFIED=1 # only the unverified rows (the review queue)
              bin/rails "phlex_reactive:find[counter]"     # fuzzy-find one; prints each action's method source
            SHELL
            md <<~MD
              `actions` is a table across the whole app; `find` fuzzy-matches one
              component (exact > prefix > substring > subsequence) and prints each
              action's **method-definition source** (extracted with Prism). The
              `auth` column has four labels for three states (`skipped` is spelled
              two ways). `authorized*` means an
              authorization call was detected in the body (a **heuristic** — a
              helper may still authorize indirectly, so it's a hint, not a
              verdict). `skipped` means the action is declared with
              `skip_verify_authorized :name`; `skipped (class)` means a bare
              `skip_verify_authorized` (own or inherited) covers every action.
              `unverified` means neither — the rows worth reviewing, which
              `UNVERIFIED=1` isolates. JSON adds `authorization`
              (`detected` / `skipped` / `none`) and `authorization_skip`
              (`class` / `action` / `null`) next to `authorization_call_detected`.
            MD
          end
        end

        def inspector
          DocsUI::Section('Inspector — what is reactive on this page (browser side)') do
            md <<~MD
              A standalone, on-demand module (no cost until you import it — it does
              not touch the hot-path controller). In the browser console on the
              affected page:
            MD
            DocsUI::Code(<<~JS, lexer: :javascript)
              (await import("phlex/reactive/inspect")).report()
            JS
            md <<~MD
              `report()` prints a `console.table` of every reactive root on the
              page — its `id`, decoded token payload (**component class**, gid,
              state keys, token version), status (error/busy/dirty), the bound
              **triggers** (action + event + params + debounce/confirm),
              client-only ops, computes, and the `name`d fields a dispatch would
              send. `scan()` returns the same data as a value.

              A token that can't be decoded (an older Marshal-serialized payload)
              shows as `(opaque token)` rather than throwing — the scanner is
              pure read and never breaks the page.
            MD
          end
        end

        def mapping
          DocsUI::Section('The server↔client mapping is by name') do
            md <<~MD
              This is the payoff of the two inventories. The `component` and each
              trigger's `action` that `report()` shows in the browser are **exactly
              the same identifiers** `phlex_reactive:actions` lists on the server.
              So a bug localizes to a mismatch:

              - Does the button on the page carry the **action** you expect?
              - Does its **component** match the class you think renders here?
              - Is a root showing an `(opaque token)` where it should decode?

              You never have to guess which server method a DOM control POSTs to —
              the name is the join key across both tools.
            MD
          end
        end

        def verify_authorized
          DocsUI::Section('verify_authorized — the fail-closed guard') do
            md <<~MD
              phlex-reactive's security model says *you* authorize inside the
              action. `verify_authorized` (**ON by default**) enforces it: an action
              that completes **without any authorization call** raises
              `Phlex::Reactive::AuthorizationNotVerified` **inside the transaction**,
              so the mutation **rolls back** — fail-closed, stronger than Pundit's
              after-the-fact `verify_authorized` (which runs post-commit).

              The guard detects a call to any configured authorization method **or**
              `mark_authorized!`, made anywhere during the action (a helper the
              action calls counts too). Three ways to satisfy it:
            MD
            DocsUI::Code(<<~RUBY, lexer: :ruby)
              # 1. Call your authorization method (the interceptor detects it):
              def rename(title:)
                authorize! @todo, :update?
                @todo.update!(title:)
              end

              # 2. mark_authorized! after a bespoke check the interceptor can't see:
              def publish
                raise NotAllowed unless @post.author == Current.user
                mark_authorized!
                @post.update!(published: true)
              end

              # 3. skip_verify_authorized for a genuinely public action:
              class PublicCounter < ApplicationComponent
                include Phlex::Reactive::Component
                skip_verify_authorized              # whole component
                # skip_verify_authorized :filter    # …or just these actions
              end
            RUBY
            md <<~MD
              Configure the method names your library uses, or turn the guard off
              entirely (not recommended — you lose the fail-closed net):
            MD
            DocsUI::Code(<<~RUBY, lexer: :ruby, filename: 'config/initializers/phlex_reactive.rb')
              # Pundit / CanCanCan / ActionPolicy — the default set:
              Phlex::Reactive.authorization_methods = %i[authorize! authorize allowed_to?]
              # Phlex::Reactive.verify_authorized = false
            RUBY
            DocsUI::Callout(:warning, title: 'It raises a 500, on purpose') do
              md <<~MD
                `AuthorizationNotVerified` is a **developer error** (a forgotten
                `authorize!`), not a client fault — it bubbles as a 500 so your error
                tracker fires, and it is never masked into a 4xx. The
                `action.phlex_reactive` instrumentation event tags the outcome
                `:unverified`. Authorizing inside a custom `around_action` (which
                runs *outside* the tracking window) triggers a spurious raise — call
                `mark_authorized!` inside the action instead.
              MD
            end
          end
        end

        def mcp
          DocsUI::Section('MCP server — introspect the running app from your editor') do
            md <<~MD
              For live-app introspection inside Claude Code, run the read-only MCP
              server (needs the optional `mcp` gem — `gem "mcp"`). Add it to
              `.mcp.json`:
            MD
            DocsUI::Code(<<~JSON, lexer: :json, filename: '.mcp.json')
              { "mcpServers": { "phlex-reactive": { "command": "bin/rails", "args": ["phlex_reactive:mcp"] } } }
            JSON
            md <<~MD
              It exposes five read-only tools — `phlex_reactive_doctor`,
              `phlex_reactive_components`, `phlex_reactive_actions` (optional
              `component:` filter), `phlex_reactive_find`, and
              `phlex_reactive_config` (a redacted summary that never emits the
              verifier or `secret_key_base`) — the same data as the rake tasks,
              queryable in conversation.

              Entry point is a rake task (not an exe) because introspection needs
              the booted Rails app. **Constraint:** stdio MCP needs a clean stdout,
              so an initializer that `puts` breaks the transport.
            MD
          end
        end

        def skill
          DocsUI::Section('The installable Claude skill') do
            md <<~MD
              One command installs the debugging runbook as a Claude Code skill and
              wires the MCP server:
            MD
            DocsUI::Code(<<~SHELL, lexer: :shell)
              rails g phlex:reactive:claude
            SHELL
            md <<~MD
              It copies the `phlex-reactive-debugging` skill into
              `.claude/skills/` (teaching the doctor → inventory → find → browser
              `report()` → MCP workflow) and creates `.mcp.json` with the server
              entry — but only when it's absent; it never rewrites an existing
              `.mcp.json`, it prints the snippet instead.

              For **reference** documentation (how a feature works), point tools at
              the hosted docs MCP — `https://phlex-reactive.zoolutions.llc/llms.txt`.
              The local MCP server is for **live-app** introspection.
            MD
          end
        end

        def failure_table
          DocsUI::Section('Failure table') do
            md <<~MD
              The endpoint's failure modes and what each means:

              | Symptom | Cause | Fix |
              |---|---|---|
              | **400** | Tampered / stale token — from before a deploy, a `secret_key_base` mismatch, or a `reply.with(...)` stream that skipped the token refresh | Reload for a fresh token; confirm `secret_key_base`; refresh the token in custom streams |
              | **403** | The action isn't declared, OR your authorizer raised (registered in `authorization_errors`) | Declare the action — or the 403 is correct |
              | **`AuthorizationNotVerified` (500)** | `verify_authorized` is on and the action authorized nothing | `authorize!`, `mark_authorized!`, or `skip_verify_authorized` |
              | **404** | The record was deleted while a page still showed it | Expected for a stale page — remove the row or reload |
              | **Nothing on click** | The `reactive` controller isn't registered, or a catch-all route shadows the endpoint | `phlex_reactive:doctor` names both |
              | **Renders but never updates** | `id` and `data-controller="reactive"` landed on different elements | Spread `**reactive_root` (binds both to one element) |
            MD
          end
        end
      end
    end
  end
end
