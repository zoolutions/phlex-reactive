# frozen_string_literal: true

# Issue #375: preview a chosen image before any upload, with no custom
# JavaScript. js.preview_file paints the input's first image file onto the img
# through an object URL the client makes from the File itself (and revokes on
# the next choice); the op carries no URL at all.
class PhotoPreviewComponent < Phlex::HTML
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  def id = 'photo-preview'

  def view_template
    div(**mix(reactive_root, class: 'flex flex-wrap items-center gap-4')) do
      label(class: 'form-control') do
        span(class: 'label-text text-sm') { 'Choose a photo' }
        input(type: 'file', id: 'pp-file', accept: 'image/*',
              **mix(on_client(:change, js.preview_file('#pp-file', into: '#pp-photo', name: '#pp-name')),
                    class: 'file-input file-input-bordered file-input-sm'))
      end
      figure(class: 'flex flex-col items-center gap-1') do
        img(id: 'pp-photo', alt: 'Preview of the chosen photo',
            class: 'h-24 w-24 rounded-box border border-base-300 bg-base-200 object-cover')
        figcaption(id: 'pp-name', class: 'text-xs opacity-70')
      end
    end
  end
end
