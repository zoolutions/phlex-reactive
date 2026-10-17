# frozen_string_literal: true

# The draggable-regions demo (issue #416): a crop box over a picture, with
# aspect presets and a focal point inside it. The box drags and resizes with a
# mouse, a pen, a finger or the keyboard; the fields below follow it as it
# moves, and each release sends :crop (the point: :focus) with the region as
# fractions of the picture. The region lives in signed state — no database —
# so every visitor gets their own.
class RegionPickerComponent < Phlex::HTML
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  PRESETS = { '' => 'Free', '16:9' => '16:9', '1:1' => 'Square', '4:5' => 'Portrait' }.freeze
  CROP = { 'x' => 0.2, 'y' => 0.15, 'width' => 0.45, 'height' => 0.6 }.freeze
  FOCUS = { 'x' => 0.5, 'y' => 0.4 }.freeze

  # The look is the app's: the box dims what it leaves out, and the styling
  # hooks (data-reactive-dragging, data-reactive-frame-active) light it up.
  BOX_CSS = 'outline-2 outline-white shadow-[0_0_0_9999px_rgb(0_0_0/0.45)] focus-visible:outline-4 ' \
            'focus-visible:outline-primary data-[reactive-dragging]:outline-primary'
  HANDLE_CSS = 'size-3 rounded-full border-2 border-white bg-primary focus:outline-none ' \
               'data-[reactive-dragging]:scale-150'
  POINT_CSS = 'size-4 rounded-full border-2 border-white bg-error shadow focus:outline-none ' \
              'focus-visible:ring-4 focus-visible:ring-error/50 data-[reactive-dragging]:scale-125'

  reactive_state :crop, :focus, :aspect

  # The checked preset is a root field named `aspect`: every action collects
  # it, so the server keeps it and renders it checked again.
  action :crop, params: { x: :float, y: :float, width: :float, height: :float, aspect: :string }
  action :focus, params: { x: :float, y: :float, aspect: :string }

  def initialize(crop: CROP, focus: FOCUS, aspect: '')
    @crop = crop
    @focus = focus
    @aspect = aspect
  end

  def id = 'region-picker'

  def crop(x:, y:, width:, height:, aspect: nil)
    return reply.morph unless inside?(x, width) && inside?(y, height)

    @aspect = aspect.to_s
    @crop = { 'x' => x, 'y' => y, 'width' => width, 'height' => height }
    reply.morph
  end

  def focus(x:, y:, aspect: nil)
    return reply.morph unless [x, y].all? { it.between?(0, 1) }

    @aspect = aspect.to_s
    @focus = { 'x' => x, 'y' => y }
    reply.morph
  end

  def view_template
    div(**reactive_root(class: 'flex flex-col gap-4', data: { testid: 'region-picker' })) do
      picture_frame
      presets
      fields
      p(class: 'text-sm opacity-70', data: { testid: 'region-saved' }) { saved }
    end
  end

  private

  # The schema casts the fractions; it does not range-check them. A forged
  # release outside the picture changes nothing (the helper would refuse to
  # render it). The fields round to 4 decimals, so x + width may reach 1.0001.
  def inside?(at, size) = at.between?(0, 1) && size.positive? && at + size <= 1.0001

  def picture_frame
    div(**mix(reactive_frame, class: 'relative overflow-hidden rounded-box select-none',
                              data: { testid: 'region-frame' })) do
      img(src: '/drag-demo/landscape.svg', alt: 'A landscape to crop', class: 'block w-full', draggable: 'false')
      div(**mix(crop_box, class: BOX_CSS, aria: { label: 'Crop region' }, data: { testid: 'region-box' })) do
        %i[nw n ne e se s sw w].each { span(**mix(reactive_box_handle(it), class: HANDLE_CSS)) }
        span(**mix(focal_point, class: POINT_CSS, aria: { label: 'Focal point' }, data: { testid: 'region-point' }))
      end
    end
  end

  def crop_box
    reactive_box(fields: { x: 'crop[x]', y: 'crop[y]', width: 'crop[width]', height: 'crop[height]' },
                 value: @crop, aspect: 'aspect', min: 0.1, action: :crop)
  end

  def focal_point
    reactive_point(fields: { x: 'focus[x]', y: 'focus[y]' }, value: @focus,
                   within: '[data-reactive-box]', action: :focus)
  end

  def presets
    div(class: 'join', role: 'radiogroup', aria: { label: 'Aspect ratio' }) do
      PRESETS.each do |ratio, label|
        input(type: 'radio', name: 'aspect', value: ratio, checked: ratio == @aspect, aria: { label: },
              class: 'join-item btn btn-sm', data: { testid: "region-aspect-#{label.downcase}" })
      end
    end
  end

  # The fields the box writes: visible here, hidden in a real form.
  def fields
    div(class: 'grid grid-cols-3 gap-2 text-xs sm:grid-cols-6') do
      @crop.each { |key, value| field("crop[#{key}]", value) }
      @focus.each { |key, value| field("focus[#{key}]", value) }
    end
  end

  def field(name, value)
    label(class: 'flex flex-col gap-1') do
      span(class: 'font-mono opacity-70') { name }
      input(type: 'text', name:, value:, readonly: true, class: 'input input-xs font-mono',
            data: { testid: "region-#{name.delete(']').tr('[', '-')}" })
    end
  end

  def saved
    c = @crop.transform_values { (it * 100).round }
    f = @focus.transform_values { (it * 100).round }
    "Saved: #{c['width']}% × #{c['height']}% at #{c['x']}%, #{c['y']}% · focus #{f['x']}%, #{f['y']}%"
  end
end
