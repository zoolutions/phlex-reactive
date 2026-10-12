# frozen_string_literal: true

# Issue #365: modal dialogs. A client-only picker opened with js.show_modal
# and closed with js.close_dialog, and a server-state dialog rendered open
# with data-reactive-modal — opened by a morph reply, a replace reply, and
# closed again by a morph that renders it without `open`.
class ModalDialogComponent < ApplicationComponent
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  reactive_state :open, :refreshes
  action :open_morph
  action :open_replace
  action :close_morph
  action :refresh_morph
  action :close_replace

  def initialize(open: false, refreshes: 0)
    @open = open
    @refreshes = refreshes
  end

  def id = "modal-dialog"

  def open_morph
    @open = true
    reply.morph
  end

  def open_replace
    @open = true
    reply.replace
  end

  def close_morph
    @open = false
    reply.morph
  end

  def close_replace
    @open = false
    reply.replace
  end

  # Re-renders the root with the dialog still open — a form inside the dialog
  # posting back with errors.
  def refresh_morph
    @refreshes += 1
    reply.morph
  end

  def view_template
    div(**reactive_root) do
      button(**mix(on_client(:click, js.show_modal("#picker")), data: { testid: "choose" })) { "Choose…" }
      button(**mix(on(:open_morph), data: { testid: "open-morph" })) { "Open (morph)" }
      button(**mix(on(:open_replace), data: { testid: "open-replace" })) { "Open (replace)" }
      button(**mix(on_client(:click, js.text("#behind-clicks", "clicked")), data: { testid: "behind" })) { "Behind" }
      output(id: "behind-clicks", data: { testid: "behind-clicks" })
      picker
      server_dialog
    end
  end

  private

  def picker
    dialog(id: "picker", aria_labelledby: "picker-title", data: { testid: "picker" }) do
      h2(id: "picker-title") { "Choose an item" }
      input(type: "search", name: "q", data: { testid: "picker-search" })
      button(**mix(on_client(:click, js.close_dialog("#picker")), data: { testid: "picker-close" })) { "Close" }
    end
  end

  def server_dialog
    dialog(id: "server-dialog", open: @open, data: { reactive_modal: true, testid: "server-dialog" }) do
      p { "Rendered open by the server" }
      p(data: { testid: "refreshes" }) { "Refreshed #{@refreshes}" }
      button(**mix(on(:refresh_morph), data: { testid: "refresh-morph" })) { "Refresh (morph)" }
      button(**mix(on(:close_morph), data: { testid: "close-morph" })) { "Close (morph)" }
      button(**mix(on(:close_replace), data: { testid: "close-replace" })) { "Close (replace)" }
    end
  end
end
