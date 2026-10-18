# frozen_string_literal: true

# Issue #439: js.preview_file(…, per_file: true) on an <input multiple>. Every
# file is checked (accept, then max_bytes); the refused ones leave the input
# before the action mixed in AFTER the op on the same change collects it, so
# the upload posts only the accepted files. A second picker has no action, so
# its preview and its kept files stay on the page to be read.
class MultiPhotoPreviewComponent < ApplicationComponent
  include Phlex::Reactive::Component

  action :upload, params: { photos: [:file] }

  def id = "multi-photo-preview"

  def upload(photos: [])
    @posted = photos.map(&:original_filename)
  end

  def view_template
    div(**reactive_root) do
      uploading_picker
      preview_only_picker
    end
  end

  private

  def uploading_picker
    op = js.preview_file("#photos-file", into: "#photos-shot", max_bytes: 1024, accept: true, per_file: true)
    input(type: "file", id: "photos-file", name: "photos", multiple: true, accept: "image/png",
      **mix(on_client(:change, op), on(:upload, event: "change"), data: { testid: "photos-file" }))
    img(id: "photos-shot", alt: "", data: { testid: "photos-shot" })
    p(data: { testid: "posted" }) { posted }
  end

  def posted
    return "Nothing posted" unless @posted

    "Posted #{@posted.size}: #{@posted.join(", ")}".strip
  end

  def preview_only_picker
    op = js.preview_file("#gallery-file", into: "#gallery-shot", name: "#gallery-name",
      max_bytes: 1024, accept: true, per_file: true)
    input(type: "file", id: "gallery-file", multiple: true, accept: "image/png",
      **mix(on_client(:change, op), data: { testid: "gallery-file" }))
    img(id: "gallery-shot", alt: "", data: { testid: "gallery-shot" })
    span(id: "gallery-name", data: { testid: "gallery-name" })
  end
end
