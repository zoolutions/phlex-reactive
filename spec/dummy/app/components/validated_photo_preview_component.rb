# frozen_string_literal: true

# Issue #382: js.preview_file under an app's upload validation. The first input
# binds the op with valid: true to BOTH change and the documented
# reactive:file-changed event, so an app that rejects a file (setCustomValidity,
# or clearing the input without a change event) clears the preview. The second
# input binds it without valid: — today's behaviour, unchanged.
class ValidatedPhotoPreviewComponent < ApplicationComponent
  include Phlex::Reactive::Component

  def id = "validated-photo-preview"

  def view_template
    div(**reactive_root) do
      validated_upload
      input(type: "file", id: "plain-file", name: "plain", accept: "image/*",
        **mix(on_client(:change, js.preview_file("#plain-file", into: "#plain-photo")), data: { testid: "plain-file" }))
      img(id: "plain-photo", alt: "", data: { testid: "plain-photo" })
    end
  end

  private

  def validated_upload
    op = js.preview_file("#upload-file", into: "#upload-photo", name: "#upload-name", valid: true)
    input(type: "file", id: "upload-file", name: "upload", accept: "image/*",
      **mix(on_client(:change, op), on_client("reactive:file-changed", op), data: { testid: "upload-file" }))
    img(id: "upload-photo", alt: "", data: { testid: "upload-photo" })
    span(id: "upload-name", data: { testid: "upload-name" })
  end
end
