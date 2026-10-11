# frozen_string_literal: true

# One card on the Project board (issue #216) — its OWN reactive root nested
# inside the board (issue #15), because it carries a rename input: a tokenless
# row would feed every card's `title` into the BOARD's root-wide field sweep
# (last one wins). Identity is the Card's GlobalID PLUS the picked effect
# style as signed state (the inline-edit record+state pattern), so a move
# animates with the style THIS visitor chose.
#
# The card is a sortable item of its lane (issue #350): it drags by its ⠿
# handle, or with the keyboard once focused (Space picks it up, the arrows move
# it — ← → across lanes — and Space drops it). The drop is the BOARD's action
# (move_card); the card itself owns rename and archive.
class BoardCardComponent < Phlex::HTML
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  reactive_record :card
  reactive_state :style

  # Effects (issue #215): the board's default polish, declared on the ROW so
  # the arriving append template carries the enter attr and the in-DOM row the
  # exit/update attrs. A non-default picked style overrides these PER CALL —
  # the three-level precedence, demoed live.
  reactive_effects enter: :slide, exit: :fade, update: :highlight

  action :rename, params: { title: :string }
  action :archive

  def initialize(card:, style: 'default')
    @card = card
    @style = ProjectBoardComponent::STYLES.include?(style) ? style : 'default'
  end

  # Enter-to-save inline rename; the morph keeps the input's focus + caret.
  def rename(title:)
    @card.update!(title: title.strip) if title.to_s.strip.present?
    self.class.broadcast_to(*Card.stream_key, replace: @card, morph: true,
                                              exclude: reactive_connection_id)
    reply.morph
  end

  def archive
    @card.destroy!
    self.class.broadcast_to(*Card.stream_key, remove: @card, exclude: reactive_connection_id)
    ProjectBoardComponent.broadcast_counts(exclude: reactive_connection_id)
    reply.remove
         .js(ProjectBoardComponent.count_ops)
         .flash(:notice, 'Card archived', dismiss_after: 2000)
  end

  def view_template
    li(**mix(reactive_root(class: 'flex flex-col gap-1 rounded-field border border-base-300 bg-base-100 p-3 shadow-sm ' \
                                  'data-[reactive-sortable-dragging]:rotate-1 data-[reactive-sortable-dragging]:shadow-lg',
                           data: { testid: 'board-card', lane: @card.lane }),
             reactive_sortable_item(@card.id))) do
      title_row
    end
  end

  private

  def title_row
    div(class: 'flex items-center gap-2') do
      span(class: 'cursor-grab touch-none select-none opacity-50', title: 'Drag to move',
           data: { drag_handle: true, testid: 'drag-handle' }) { '⠿' }
      input(**mix(on(:rename, event: 'keydown.enter'),
                  name: 'title', value: @card.title, autocomplete: 'off',
                  class: 'input input-ghost input-sm flex-1 font-medium',
                  data: { testid: 'card-title' }))
      # Archive is confirm-gated AND optimistic: the row hides the instant you
      # confirm (to: targets THIS row — :root inside a nested root is the row
      # anyway, but the explicit id keeps the intent obvious).
      button(**mix(on(:archive, confirm: 'Archive this card?',
                                optimistic: { hide: true, to: "##{id}" }),
                   class: 'btn btn-ghost btn-xs text-error', data: { testid: 'archive-card' })) { '×' }
    end
  end
end
