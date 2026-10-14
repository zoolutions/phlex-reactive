# frozen_string_literal: true

# Issue #391: js.preview_file with wrap:, max_bytes: and accept:. The frame
# around the preview starts hidden (rendered with the runtime's own mark, so
# the first good pick shows it), follows the chosen file, and a file of the
# wrong type or over 1 KB is refused with reactive:file-rejected. A second
# frame is hidden by the author and must stay hidden.
class FramedPhotoPreviewComponent < ApplicationComponent
  include Phlex::Reactive::Component

  def id = "framed-photo-preview"

  def view_template
    div(**reactive_root) do
      framed_upload
      author_hidden_upload
    end
  end

  private

  def framed_upload
    op = js.preview_file("#framed-file", into: "#framed-photo", name: "#framed-name",
      wrap: "#framed-box", max_bytes: 1024, accept: true)
    input(type: "file", id: "framed-file", name: "framed", accept: "image/png",
      **mix(on_client(:change, op), data: { testid: "framed-file" }))
    div(id: "framed-box", class: "rounded-full p-1", hidden: true,
      data: { testid: "framed-box", reactive_wrap_hidden: "" }) do
      img(id: "framed-photo", alt: "", data: { testid: "framed-photo" })
    end
    span(id: "framed-name", data: { testid: "framed-name" })
  end

  def author_hidden_upload
    op = js.preview_file("#kept-file", into: "#kept-photo", wrap: "#kept-box")
    input(type: "file", id: "kept-file", name: "kept", **mix(on_client(:change, op), data: { testid: "kept-file" }))
    div(id: "kept-box", hidden: true, data: { testid: "kept-box" }) do
      img(id: "kept-photo", alt: "", data: { testid: "kept-photo" })
    end
  end
end
