# frozen_string_literal: true

# The Project board's viewers strip (issue #358): one avatar per tab with the
# board open, this tab's ringed. The board is one shared public board, so the
# stream is a fixed key.
class BoardViewersComponent < Phlex::HTML
  include Phlex::Reactive::Component

  reactive_presence :viewers, key: %w[project_board], ttl: 30

  def id = 'board-viewers'

  def view_template
    div(**reactive_root(class: 'flex items-center gap-2 text-sm', data: { testid: 'board-viewers' })) do
      span(class: 'opacity-60') { 'Viewing:' }
      presence.peers.each { avatar(it) }
    end
  end

  private

  def avatar(peer)
    span(**mix(reactive_presence_peer(peer),
               class: 'avatar avatar-placeholder data-[reactive-presence-me]:ring-2 ring-primary rounded-full',
               title: peer.metadata['name'] || 'Guest')) do
      span(class: 'bg-neutral text-neutral-content size-6 rounded-full text-xs') do
        (peer.metadata['name'] || 'G')[0]
      end
    end
  end
end
