# frozen_string_literal: true

# Issue #365: a real modal <dialog> with no custom JavaScript. The picker opens
# with js.show_modal and closes with js.close_dialog — the browser supplies the
# top layer, the focus trap, the backdrop, Escape and focus back on the opener.
# The confirmation keeps "is it open" as server state and renders the dialog
# open with data-reactive-modal, which the client upgrades to a modal one.
class ModalPickerComponent < Phlex::HTML
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  ITEMS = %w[Apple Banana Cherry].freeze

  reactive_state :confirming
  action :ask
  action :cancel

  def initialize(confirming: false)
    @confirming = confirming
  end

  def id = 'modal-picker'

  def ask
    @confirming = true
    reply.morph
  end

  def cancel
    @confirming = false
    reply.morph
  end

  def view_template
    div(**mix(reactive_root, class: 'flex flex-wrap items-center gap-3')) do
      button(**mix(on_client(:click, js.show_modal('#mp-picker')), class: 'btn btn-sm')) { 'Choose a fruit…' }
      button(**mix(on(:ask), class: 'btn btn-sm btn-outline')) { 'Delete (asks the server)' }
      p(class: 'text-sm') do
        plain 'Picked: '
        span(id: 'mp-status', class: 'font-semibold') { 'nothing' }
      end
      picker
      confirmation
    end
  end

  private

  # The titles are not headings: a heading would land in the page's table of contents.
  def picker
    dialog(id: 'mp-picker', class: 'modal', aria_labelledby: 'mp-title') do
      div(class: 'modal-box flex flex-col gap-3') do
        p(id: 'mp-title', class: 'text-lg font-semibold') { 'Choose a fruit' }
        ITEMS.each do |item|
          button(**mix(on_client(:click, js.text('#mp-status', item).close_dialog('#mp-picker')),
                       class: 'btn btn-ghost justify-start')) { item }
        end
        button(**mix(on_client(:click, js.close_dialog('#mp-picker')), class: 'btn btn-sm')) { 'Close' }
      end
    end
  end

  # Escape fires the dialog's `cancel` event: bound to the cancel action, the
  # server clears @confirming and its morph closes the dialog, so a later
  # re-render never brings it back open.
  def confirmation
    attrs = { id: 'mp-confirm', class: 'modal', open: @confirming, aria_labelledby: 'mp-confirm-title',
              data: { reactive_modal: true } }
    dialog(**mix(on(:cancel, event: 'cancel'), attrs)) do
      div(class: 'modal-box flex flex-col gap-3') do
        p(id: 'mp-confirm-title', class: 'text-lg font-semibold') { 'Rendered open by the server' }
        p { 'The reply morphed this dialog in with open and data-reactive-modal; the client made it modal.' }
        button(**mix(on(:cancel), class: 'btn btn-sm')) { 'Cancel (the server closes it)' }
      end
    end
  end
end
