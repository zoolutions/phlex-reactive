# frozen_string_literal: true

# Issue #428: a box and a point whose fields are on a scale of 100 (percent),
# over a 400 × 200 px frame. The visible number inputs beside the frame show
# 10 where an unscaled field shows 0.1; the server renders their first value
# in percent itself. :crop and :focus still get fractions — the reply's line
# shows what the server got, and each reply re-renders from the fractions it
# stored.
class DragScaleComponent < ApplicationComponent
  include Phlex::Reactive::Component

  FRAME_STYLE = "position: relative; width: 400px; height: 200px; background: #ddd; margin: 0 0 16px;"

  reactive_state :x, :y, :width, :height, :focus_x, :focus_y, :saves, :last

  action :crop, params: { x: :float, y: :float, width: :float, height: :float }
  action :focus, params: { x: :float, y: :float }

  def initialize(x: 0.1, y: 0.1, width: 0.5, height: 0.4, focus_x: 0.75, focus_y: 0.5, saves: 0, last: "")
    @x = x
    @y = y
    @width = width
    @height = height
    @focus_x = focus_x
    @focus_y = focus_y
    @saves = saves
    @last = last
  end

  def id = "drag-scale"

  def crop(x:, y:, width:, height:)
    return reply.morph unless inside?(x, width) && inside?(y, height)

    @x = x
    @y = y
    @width = width
    @height = height
    @saves += 1
    @last = "crop #{x} #{y} #{width} #{height}"
    reply.morph
  end

  def focus(x:, y:)
    return reply.morph unless [x, y].all? { it.between?(0, 1) }

    @focus_x = x
    @focus_y = y
    @saves += 1
    @last = "focus #{x} #{y}"
    reply.morph
  end

  def view_template
    div(**reactive_root(data: { testid: "scale" })) do
      p(data: { testid: "scale-last" }) { "#{@saves} #{@last}" }
      # (An id, so a spec can morph the frame alone: the fields sit outside it.)
      div(**mix(reactive_frame, id: "drag-scale-frame", style: FRAME_STYLE, data: { testid: "scale-frame" })) do
        div(**mix(scaled_box, style: "outline: 2px solid #333;", data: { testid: "scale-box" }, aria: { label: "Region" }))
        span(**mix(scaled_point, style: "width: 14px; height: 14px; border-radius: 50%; background: #c00;",
          data: { testid: "scale-point" }, aria: { label: "Marker" }))
      end
      { x: @x, y: @y, width: @width, height: @height }.each { |key, value| percent_field("region", key, value) }
      { x: @focus_x, y: @focus_y }.each { |key, value| percent_field("marker", key, value) }
    end
  end

  private

  def inside?(start, size) = start.between?(0, 1) && size.positive? && start + size <= 1.0001

  def scaled_box
    reactive_box(fields: { x: "region[x]", y: "region[y]", width: "region[width]", height: "region[height]" },
      value: { x: @x, y: @y, width: @width, height: @height }, scale: 100, action: :crop)
  end

  def scaled_point
    reactive_point(fields: { x: "marker[x]", y: "marker[y]" }, value: { x: @focus_x, y: @focus_y },
      scale: 100, action: :focus)
  end

  # The field's first value is the app's to put on the scale: in percent.
  def percent_field(name, key, fraction)
    label do
      plain "#{name} #{key} (%)"
      input(type: "number", name: "#{name}[#{key}]", value: (fraction * 100).round(2), step: "0.01",
        data: { testid: "#{name}-#{key}" })
    end
  end
end
