# frozen_string_literal: true

module Views
  module Docs
    module Pages
      class Architecture < DocsUI::Page
        title 'Architecture'
        eyebrow 'Guide'
        description 'See how reactive Phlex components reduce every click, broadcast, and morph to one re-render unit over Turbo Streams, with signed identity, not state'

        def lead
          'A component owns a stable DOM id. Everything — a click, a form change, ' \
            'a background broadcast — reduces to “render this component into that id.” ' \
            'A click POSTs and gets a reply; a broadcast pushes the same render to other tabs; ' \
            'a morph re-renders in place without losing focus.'
        end

        def content
          mental_model
          request_reply
          morphing
          transport
          layers
          identity
        end

        private

        def mental_model
          DocsUI::Section('The mental model') do
            render Components::Diagrams::ArchitectureFlow.new
            DocsUI::Prose() do
              p do
                plain 'Client interactivity ('
                code { 'Component' }
                plain ') and server-pushed live updates ('
                code { 'Streamable' }
                plain ') converge on ONE re-render unit. A reactive component '
                plain 'self-targets by its stable '
                code { '#id' }
                plain ', so a click and a broadcast share the same destination.'
              end
              p do
                plain 'Record-backed components default '
                code { '#id' }
                plain ' to '
                code { 'dom_id(record)' }
                plain ' — the id nearly everyone wrote by hand. One '
                code { 'include Phlex::Reactive::Component' }
                plain ' pulls in '
                code { 'Streamable' }
                plain ' too.'
              end
            end
          end
        end

        def request_reply
          DocsUI::Section('The request/reply cycle') do
            DocsUI::Prose() do
              p do
                plain 'A click or form change POSTs '
                code { 'POST /reactive/actions' }
                plain ' with the signed token, the action name, and any params. The endpoint '
                plain 'verifies the token (no client state is trusted), rebuilds the component '
                plain '(re-finding the record from the DB), runs the whitelisted action, and streams '
                plain 'a reply back. Turbo applies it.'
              end
              p do
                plain 'The '
                strong { 'default reply' }
                plain ' is a '
                code { '<turbo-stream action="replace" target="#id">' }
                plain ' of the freshly rebuilt component — you never pick a target. To do more, '
                plain 'an action '
                strong { 'returns' }
                code { 'reply.<verb>' }
                plain '. Returning anything else keeps the default, so existing actions are unaffected.'
              end
            end
            DocsUI::Code(reply_source, lexer: :ruby, filename: 'app/components/todos/item.rb')
            DocsUI::Prose() do
              ul do
                li do
                  code { 'reply.replace' }
                  plain ' / '
                  code { 'reply.update' }
                  plain ' — re-render in place ('
                  code { 'replace' }
                  plain ' swaps outerHTML, '
                  code { 'update' }
                  plain ' swaps inner HTML; pass '
                  code { 'morph: true' }
                  plain ' to either to morph in place).'
                end
                li do
                  code { 'reply.morph' }
                  plain ' — re-render in place via Idiomorph; preserves the focused '
                  code { '<input>' }
                  plain ', its caret and what was typed in it, even when the render differs (see below; '
                  code { 'data-reactive-morph-value' }
                  plain ' on a field lets the morph overwrite it).'
                end
                li do
                  code { 'reply.remove' }
                  plain ' — remove the element.'
                end
                li do
                  code { 'reply.redirect(url)' }
                  plain ' — client-side '
                  code { 'Turbo.visit' }
                  plain ' (a slug changed); rides a stream, not an HTTP 3xx.'
                end
                li do
                  code { 'reply.streams(*streams)' }
                  plain ' — a partial update: emit exactly these streams plus a tiny token refresh, '
                  plain 'so live inputs the user is mid-typing in survive.'
                end
              end
            end
            DocsUI::Callout(:tip, title: 'The reply is the actor’s reply') do
              plain 'It governs only the clicking user’s HTTP response. Cross-tab updates still go '
              plain 'out via '
              code { 'broadcast_to' }
              plain ' — see The transport.'
            end
          end
        end

        def morphing
          DocsUI::Section('Morphing — re-render without losing focus') do
            DocsUI::Prose() do
              p do
                plain 'A plain '
                code { 'reply.replace' }
                plain ' swaps the element’s outerHTML — fine for a counter, but it '
                strong { 'tears down a focused field' }
                plain '. For per-field reactive editing (a “spreadsheet” grid where a debounced save '
                plain 'fires while the user is still typing), '
                code { 'reply.morph' }
                plain ' emits '
                code { 'method="morph"' }
                plain ' so Turbo 8’s bundled Idiomorph reconciles the subtree in place — the focused '
                code { '<input>' }
                plain ' and its caret survive the re-render.'
              end
              p do
                plain 'Under the hood '
                code { 'reply.morph' }
                plain ' calls '
                code { 'Streamable#to_stream_replace(morph: true)' }
                plain ', the morph variant of '
                code { 'to_stream_replace' }
                plain '. Broadcasts morph too: '
                code { 'broadcast_to(..., replace: model, morph: true)' }
                plain ' keeps a peer tab’s focus on the morphed row.'
              end
            end
            DocsUI::Code(morph_source, lexer: :ruby)
            DocsUI::Callout(:warning, title: 'Requires Turbo 8+') do
              plain 'Morphing is a Turbo 8 feature. On older Turbo, '
              code { 'reply.replace' }
              plain ' is the swap you get.'
            end
          end
        end

        def transport
          DocsUI::Section('The transport — reaching OTHER tabs') do
            DocsUI::Prose() do
              p do
                plain 'The reply above reaches only the actor. To update '
                strong { 'other tabs and other users' }
                plain ', a model change (or a job) calls a class-level '
                code { 'broadcast_to' }
                plain ' — the SAME render, pushed over the stream transport instead of returned as an HTTP reply.'
              end
              p do
                plain 'The transport is whatever turbo-rails is configured with: Action Cable, or '
                plain 'pgbus over Postgres SSE (transactional — no broadcast for a rolled-back change — '
                plain 'and reconnect-safe). Pass '
                code { 'exclude: reactive_connection_id' }
                plain ' to suppress the actor’s own echo — they already got the action’s reply.'
              end
            end
            DocsUI::Code(broadcast_source, lexer: :ruby)
            DocsUI::Prose() do
              p do
                plain 'A click and a broadcast produce the '
                strong { 'identical' }
                plain ' “replace #id with this render.” Live cross-tab updates are not a second '
                plain 'mechanism — they’re the same re-render unit, delivered over the transport.'
              end
            end
            DocsUI::Callout(:tip) do
              plain 'pgbus needs no Redis and no Action Cable — one Postgres, and your reactive code is identical.'
            end
          end
        end

        def layers
          DocsUI::Section('The layers') do
            DocsUI::Prose() do
              ul do
                li do
                  plain 'Client runtime — one generic Stimulus controller ' \
                        '(dispatch, morph apply, busy/lifecycle events).'
                end
                li { plain 'Endpoint — verify token → rebuild component → run action → stream the reply.' }
                li do
                  plain 'Component mixin — reactive_record/reactive_state, action, on, reply.<verb>, and on_client ' \
                        '(declared client-only DOM ops via the js builder — zero round trip). ' \
                        'Including it pulls in Streamable automatically (one include is enough).'
                end
                li do
                  plain 'Streamable mixin — #id, replace/morph/append, broadcast_to over the transport. ' \
                        'Record-backed components default #id to dom_id(record).'
                end
              end
            end
          end
        end

        def identity
          DocsUI::Section('Signed identity, not state') do
            DocsUI::Prose() do
              p do
                plain 'The DOM holds a signed identity — a '
                code { 'MessageVerifier' }
                plain ' token, never raw state. Tampering fails verification.'
              end
            end
            DocsUI::Callout(:warning, title: 'Never trust client input') do
              plain 'The signature proves the token is ours, NOT that this user may act. Authorize inside the action.'
            end
            # Dogfood: a reactive modal shows what the token actually contains.
            render ReactiveModalComponent.new(modal: 'signed-identity', label: "What's in the token?")
          end
        end

        def reply_source
          <<~RUBY
            def toggle
              # the token proves identity, not permission
              authorize! @todo, :update?
              @todo.toggle!(:done)
              # no return → DEFAULT reply: replace #id in place
            end

            def rename(title:)
              if title.blank?
                return reply.replace.flash(:error, "Title required")
              end
              @todo.update!(title:)
              reply.replace
            end

            # drop the element from the DOM
            def approve
              @row.approve!
              reply.remove
            end

            # the slug changed → redirect the browser
            def publish
              @article.publish!
              reply.redirect(article_url(@article))
            end
          RUBY
        end

        def morph_source
          <<~RUBY
            # A debounced per-field save fires WHILE the
            # user is still typing. Morph in place so the
            # focused <input> and its value survive.
            def update(name:)
              @row.update!(name:)
              # method="morph" — focus + caret preserved
              reply.morph
            end
          RUBY
        end

        def broadcast_source
          <<~RUBY
            # In a model callback or job — light up every
            # OTHER viewer's tab with the same render,
            # pushed over the transport (not returned).
            Chat::Message.broadcast_to(
              @room, append: message, target: "messages",
              exclude: reactive_connection_id # skip actor
            )
          RUBY
        end
      end
    end
  end
end
