# frozen_string_literal: true

# Issue #375: js.preview_file. Choosing a file paints it onto the img before
# any upload, through an object URL the client makes and revokes itself; a
# morph reply (the server renders the img without a src) and a replace reply
# (the img node is swapped) both revoke it. A second input aims the op at an
# iframe, which must never get a src.
class PhotoPreviewComponent < ApplicationComponent
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  reactive_state :refreshes
  action :refresh_morph
  action :refresh_replace

  def initialize(refreshes: 0)
    @refreshes = refreshes
  end

  def id = "photo-preview"

  def refresh_morph
    @refreshes += 1
    reply.morph
  end

  def refresh_replace
    @refreshes += 1
    reply.replace
  end

  def view_template
    div(**reactive_root) do
      input(type: "file", id: "photo-file", name: "photo", accept: "image/*",
        **mix(on_client(:change, js.preview_file("#photo-file", into: "#photo", name: "#photo-name")),
          data: { testid: "photo-file" }))
      img(id: "photo", alt: "", data: { testid: "photo" })
      span(id: "photo-name", data: { testid: "photo-name" })
      p(data: { testid: "refreshes" }) { "Refreshed #{@refreshes}" }
      button(**mix(on(:refresh_morph), data: { testid: "refresh-morph" })) { "Refresh (morph)" }
      button(**mix(on(:refresh_replace), data: { testid: "refresh-replace" })) { "Refresh (replace)" }
      wrong_target
    end
  end

  private

  def wrong_target
    input(type: "file", id: "frame-file", name: "frame",
      **mix(on_client(:change, js.preview_file("#frame-file", into: "#frame")), data: { testid: "frame-file" }))
    iframe(id: "frame", title: "Never previewed", data: { testid: "frame" })
  end
end
