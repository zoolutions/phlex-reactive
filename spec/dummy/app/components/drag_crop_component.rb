# frozen_string_literal: true

# Issue #416: a crop box over a 400 × 200 px frame, state-backed (no DB). The
# box drags and resizes, its aspect follows the preset radios, and a release
# sends :crop with x/y/width/height; the focal point inside it sends :focus.
# The checked preset (a root field named `aspect`) is collected with every
# action, so the server keeps it and renders it checked again. Each reply
# re-renders from the state the action stored, plus the save count and the
# last params, so a spec can see one request per release. :reset moves the box
# from the server (a morph).
class DragCropComponent < ApplicationComponent
  include Phlex::Reactive::Component

  reactive_state :x, :y, :width, :height, :focus_x, :focus_y, :aspect, :saves, :last

  action :crop, params: { x: :float, y: :float, width: :float, height: :float, aspect: :string }
  action :focus, params: { x: :float, y: :float, aspect: :string }
  action :reset, params: { aspect: :string }

  def initialize(x: 0.1, y: 0.1, width: 0.5, height: 0.4, focus_x: 0.5, focus_y: 0.5, aspect: "", saves: 0, last: "")
    @x = x
    @y = y
    @width = width
    @height = height
    @focus_x = focus_x
    @focus_y = focus_y
    @aspect = aspect
    @saves = saves
    @last = last
  end

  def id = "drag-crop"

  def crop(x:, y:, width:, height:, aspect: nil)
    # A forged release outside the frame changes nothing: the schema casts, it
    # does not range-check, and the helper refuses to render a box outside.
    return reply.morph unless inside?(x, width) && inside?(y, height)

    @x = x
    @y = y
    @width = width
    @height = height
    @aspect = aspect.to_s
    @saves += 1
    @last = "crop #{x} #{y} #{width} #{height}"
    reply.morph
  end

  def focus(x:, y:, aspect: nil)
    return reply.morph unless [x, y].all? { it.between?(0, 1) }

    @focus_x = x
    @focus_y = y
    @aspect = aspect.to_s
    @saves += 1
    @last = "focus #{x} #{y}"
    reply.morph
  end

  def reset(aspect: nil)
    @x = 0.25
    @y = 0.25
    @width = 0.5
    @height = 0.5
    @aspect = aspect.to_s
    reply.morph
  end

  def view_template
    div(**reactive_root(data: { testid: "crop" })) do
      p(data: { testid: "crop-last" }) { "#{@saves} #{@last}" }
      div(**mix(reactive_frame, class: "frame", data: { testid: "crop-frame" })) do
        div(**mix(crop_box, class: "box", data: { testid: "crop-box" }, aria: { label: "Crop" })) do
          %i[nw n ne e se s sw w].each { span(**mix(reactive_box_handle(it), class: "handle", data: { testid: "handle-#{it}" })) }
          span(**mix(focal_point, class: "point", data: { testid: "crop-point" }, aria: { label: "Focus" }))
        end
      end
      aspect_presets
      { x: @x, y: @y, width: @width, height: @height }.each { |key, value| input(type: "hidden", name: "crop[#{key}]", value:) }
      input(type: "hidden", name: "focus[x]", value: @focus_x)
      input(type: "hidden", name: "focus[y]", value: @focus_y)
      button(**mix(on(:reset), data: { testid: "crop-reset" })) { "Reset" }
    end
  end

  private

  # The fields round to 4 decimals, so x + width may reach 1.0001.
  def inside?(start, size) = start.between?(0, 1) && size.positive? && start + size <= 1.0001

  def crop_box
    reactive_box(fields: { x: "crop[x]", y: "crop[y]", width: "crop[width]", height: "crop[height]" },
      value: { x: @x, y: @y, width: @width, height: @height },
      aspect: "aspect", min: 0.1, action: :crop)
  end

  def focal_point
    reactive_point(fields: { x: "focus[x]", y: "focus[y]" }, value: { x: @focus_x, y: @focus_y },
      within: "[data-reactive-box]", action: :focus)
  end

  # The frame is 400 × 200 px: 2:1 is as many fractions wide as tall.
  def aspect_presets
    fieldset do
      { "" => "Free", "2:1" => "2:1", "4:1" => "4:1" }.each do |ratio, label|
        label do
          input(type: "radio", name: "aspect", value: ratio, checked: ratio == @aspect,
            data: { testid: "aspect-#{label.downcase}" })
          plain label
        end
      end
    end
  end
end
