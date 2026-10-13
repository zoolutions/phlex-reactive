# frozen_string_literal: true

# Issue #373: a preview image that follows a field, and buttons that copy an
# image — with no URL in any op or binding. The server renders every candidate
# <img> (hidden); reactive_media copies the one whose key is the first three
# characters of the code, and js.copy_media copies a named one.
class MediaPreviewComponent < Phlex::HTML
  include Phlex::Reactive::Component

  REGIONS = {
    '007' => ['#mpv-north', 'North'],
    '011' => ['#mpv-south', 'South'],
    '042' => ['#mpv-east', 'East']
  }.freeze

  def id = 'media-preview'

  def view_template
    div(**mix(reactive_root, class: 'flex flex-wrap items-start gap-6')) do
      field
      preview
      buttons
      pool
    end
  end

  private

  def field
    label(class: 'form-control w-56') do
      span(class: 'label-text') { 'Branch code (007, 011, 042…)' }
      input(name: 'code', value: '007-1234', class: 'input input-bordered input-sm', autocomplete: 'off')
    end
  end

  # The first paint matches the field's initial value (007), so the preview
  # shows without JavaScript; the binding then writes nothing until it changes.
  def preview
    figure(class: 'flex flex-col items-center gap-1') do
      img(id: 'mpv-logo', src: '/media-demo/north.svg', alt: 'North', width: 64, height: 64, class: 'rounded',
          **reactive_media(from: :code, take: 3, pool: REGIONS.transform_values(&:first),
                           label: '#mpv-caption', blank_label: 'Unknown branch'))
      figcaption(id: 'mpv-caption', class: 'text-sm') { 'North' }
    end
  end

  def buttons
    div(class: 'flex flex-col items-center gap-2') do
      div(class: 'flex gap-2') do
        REGIONS.each_value do |selector, name|
          button(**mix(on_client(:click, js.copy_media('#mpv-copied', from: selector)), class: 'btn btn-xs')) { name }
        end
      end
      img(id: 'mpv-copied', alt: '', width: 32, height: 32, class: 'rounded')
    end
  end

  def pool
    REGIONS.each_value do |selector, name|
      img(id: selector.delete_prefix('#'), src: "/media-demo/#{name.downcase}.svg", alt: name, hidden: true)
    end
  end
end
