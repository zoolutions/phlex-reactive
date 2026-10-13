# frozen_string_literal: true

# Issue #373: a preview image that follows a field, and buttons that copy an
# image — with no URL in any op or binding. The server renders every candidate
# <img> (hidden); reactive_media copies the one whose key is the first three
# characters of the code, and js.copy_media copies a named one. Central (050)
# has no logo file: its pool <img> carries an alt and no src, so the preview
# drops its image and keeps the name (issue #381).
class MediaPreviewComponent < Phlex::HTML
  include Phlex::Reactive::Component

  REGIONS = {
    '007' => ['#mpv-north', 'North'],
    '011' => ['#mpv-south', 'South'],
    '042' => ['#mpv-east', 'East'],
    '050' => ['#mpv-central', 'Central']
  }.freeze
  NO_LOGO = %w[Central].freeze

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
      span(class: 'label-text') { 'Branch code (007, 011, 042, 050…)' }
      input(name: 'code', value: '007-1234', class: 'input input-bordered input-sm', autocomplete: 'off')
    end
  end

  # The first paint matches the field's initial value (007), so the preview
  # shows without JavaScript; the binding then writes nothing until it changes.
  # Until three digits are typed the binding is pending (issue #380): no
  # "Unknown branch", and the figure hides itself on data-reactive-media-state.
  def preview
    figure(class: 'flex flex-col items-center gap-1 has-[[data-reactive-media-state=pending]]:invisible') do
      img(id: 'mpv-logo', src: '/media-demo/north.svg', alt: 'North', width: 64, height: 64, class: 'rounded',
          **reactive_media(from: :code, take: 3, match: /\A\d{3}\z/, pool: REGIONS.transform_values(&:first),
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
      src = "/media-demo/#{name.downcase}.svg" unless NO_LOGO.include?(name)
      img(id: selector.delete_prefix('#'), src:, alt: name, hidden: true)
    end
  end
end
