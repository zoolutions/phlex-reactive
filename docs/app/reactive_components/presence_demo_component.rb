# frozen_string_literal: true

# The Presence page's live demo (issue #358): who has this page open, one dot
# per tab, and which colour each tab picked. Open it in two tabs: each sees
# the other join, pick and leave. Record-less, so its stream is a fixed key.
class PresenceDemoComponent < Phlex::HTML
  include Phlex::Reactive::Component

  class Denied < StandardError
  end

  COLORS = %w[red green blue].freeze

  reactive_presence :viewers, key: %w[docs_presence], state: { color: :string }, ttl: 30

  def id = 'presence-demo'

  def authorize_presence_state!(color: nil)
    raise Denied, 'unknown colour' if color && COLORS.exclude?(color)
  end

  def view_template
    div(**reactive_root(class: 'flex flex-col gap-4')) do
      p(class: 'text-sm') { "#{presence.count} #{presence.one? ? 'tab has' : 'tabs have'} this page open" }
      div(class: 'flex gap-2') do
        COLORS.each { color_button(it) }
      end
    end
  end

  private

  def color_button(color)
    button(**mix(on_client(:click, js.presence(color:)), class: 'btn btn-sm gap-2')) do
      plain color
      presence.where(color:).each { dot(it) } # rubocop:disable Rails/FindEach -- a roster, not a relation
    end
  end

  # This tab's dot is filled (data-reactive-presence-me), the others outlined.
  def dot(peer)
    span(**mix(reactive_presence_peer(peer),
               class: 'size-3 rounded-full border border-current data-[reactive-presence-me]:bg-current'))
  end
end
