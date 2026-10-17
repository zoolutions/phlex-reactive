# frozen_string_literal: true

require "spec_helper"
require "phlex"

# Issue #416: draggable regions — reactive_frame (the coordinate space),
# reactive_box (a box that moves and resizes inside it), reactive_box_handle (an
# edge or corner to resize from) and reactive_point (a point inside the frame, or
# inside a box). Every position is a fraction of the frame, 0..1 on each axis,
# rendered as left/top/width/height percentages so first paint needs no JavaScript.
RSpec.describe Phlex::Reactive::Component::Drag do
  let(:klass) do
    Class.new(Phlex::HTML) do
      include Phlex::Reactive::Component

      def self.name = "RegionPicker"

      reactive_state :n
      action :crop, params: { x: :float, y: :float, width: :float, height: :float }

      def initialize = @n = 0

      def id = "picker"

      def view_template
        div(**reactive_root) do
          div(**mix(reactive_frame, class: "relative")) do
            div(**reactive_box(fields: { x: "r[x]", y: "r[y]", width: "r[w]", height: "r[h]" },
              value: { x: 0.1, y: 0.1, width: 0.5, height: 0.4 })) do
              span(**reactive_box_handle(:se))
            end
          end
        end
      end
    end
  end

  let(:client_only) do
    Class.new(Phlex::HTML) do
      include Phlex::Reactive::ClientBindings

      def self.name = "FocusPicker"

      def view_template
        div(**reactive_root(id: "focus")) do
          div(**reactive_frame) do
            span(**reactive_point(fields: { x: "focus[x]", y: "focus[y]" }, value: { x: 0.5, y: 0.25 }))
          end
        end
      end
    end
  end

  let(:view) { klass.new }
  let(:fields) { { x: "region[x]", y: "region[y]", width: "region[width]", height: "region[height]" } }
  let(:value) { { x: 0.1, y: 0.1, width: 0.5, height: 0.4 } }

  def box(**) = view.reactive_box(fields: fields, value:, **)

  def data(attrs) = attrs.fetch(:data)

  def with_verbose_errors
    Phlex::Reactive.verbose_errors = true
    yield
  ensure
    Phlex::Reactive.remove_instance_variable(:@verbose_errors)
  end

  describe "#reactive_frame" do
    it "marks the coordinate space" do
      expect(view.reactive_frame).to eq(data: { reactive_frame: true })
    end
  end

  describe "#reactive_box" do
    it "renders its position from value: as percentages, so first paint needs no JavaScript" do
      expect(box[:style]).to eq(
        "position: absolute; box-sizing: border-box; left: 10%; top: 10%; width: 50%; height: 40%; " \
        "touch-action: none; cursor: move;"
      )
    end

    it "rounds the percentages to 2 decimals (the fields' 4)" do
      style = view.reactive_box(fields: fields, value: { x: 0.123456, y: 0, width: 0.333333, height: 1 })[:style]
      expect(style).to include("left: 12.35%; top: 0%; width: 33.33%; height: 100%;")
    end

    it "is focusable (the keyboard model)" do
      expect(box[:tabindex]).to eq(0)
    end

    it "marks the box with its fields, its min: and the default words" do
      attrs = data(box)
      expect(JSON.parse(attrs[:reactive_box])).to eq(
        "x" => "region[x]", "y" => "region[y]", "width" => "region[width]", "height" => "region[height]"
      )
      expect(attrs[:reactive_box_min]).to eq(0.05)
      expect(JSON.parse(attrs[:reactive_box_messages])).to eq(
        "moved" => "Moved to {x}%, {y}%",
        "resized" => "Resized to {width}% by {height}%",
        "cancelled" => "Cancelled"
      )
    end

    it "omits every optional attribute by default" do
      expect(data(box).keys).to contain_exactly(:reactive_box, :reactive_box_min, :reactive_box_messages)
    end

    it "takes string keys in fields: and value:" do
      attrs = view.reactive_box(fields: fields.transform_keys(&:to_s), value: value.transform_keys(&:to_s))
      expect(JSON.parse(data(attrs)[:reactive_box])).to include("x" => "region[x]")
      expect(attrs[:style]).to include("left: 10%;")
    end

    it "takes a Numeric aspect: as a fixed ratio" do
      expect(data(box(aspect: 16 / 9r))[:reactive_box_ratio]).to be_within(1e-9).of(16 / 9.0)
      expect(data(box(aspect: 1))[:reactive_box_ratio]).to eq(1.0)
    end

    it "takes a field's name as aspect: (read at drag start, re-fit when it changes)" do
      expect(data(box(aspect: "region[aspect]"))).to include(reactive_box_aspect: "region[aspect]")
      expect(data(box(aspect: :ratio))).to include(reactive_box_aspect: "ratio")
    end

    it "writes a Rational min: as a number the browser reads" do
      expect(data(box(min: 1/10r))[:reactive_box_min]).to eq(0.1).and be_a(Float)
    end

    it "takes min: as a fraction of the frame" do
      expect(data(box(min: 0.1))[:reactive_box_min]).to eq(0.1)
    end

    it "merges app-supplied words over the defaults (translations)" do
      messages = JSON.parse(data(box(messages: { moved: "Verschoben nach {x} %, {y} %" }))[:reactive_box_messages])
      expect(messages).to include("moved" => "Verschoben nach {x} %, {y} %", "cancelled" => "Cancelled")
    end

    it "takes action: and busy: (sent once on release)" do
      attrs = data(box(action: :crop, busy: "Saving…"))
      expect(attrs).to include(reactive_box_action: "crop")
      expect(JSON.parse(attrs[:reactive_box_busy])).to eq("disable" => true, "text" => "Saving…")
    end

    it "raises (verbose_errors) on an undeclared action:" do
      with_verbose_errors do
        expect { box(action: :corp) }.to raise_error(Phlex::Reactive::Error, /no declared action :corp/)
      end
    end

    it "raises on a blank action:" do
      expect { box(action: " ") }.to raise_error(ArgumentError, /action: needs the name of a declared action/)
    end

    it "raises on busy: without action:" do
      expect { box(busy: "Saving…") }.to raise_error(ArgumentError, /busy: needs an action:/)
    end

    it "raises on missing or unknown fields: keys, saying which are needed" do
      expect { view.reactive_box(fields: fields.except(:height), value:) }
        .to raise_error(ArgumentError, /fields: is missing :height.*fields: \{ x: "region\[x\]"/m)
      expect { view.reactive_box(fields: fields.merge(z: "z"), value:) }
        .to raise_error(ArgumentError, /unknown fields: key :z/)
      expect { view.reactive_box(fields: "region", value:) }
        .to raise_error(ArgumentError, /fields: must be a Hash/)
      expect { view.reactive_box(fields: fields.merge(x: ""), value:) }
        .to raise_error(ArgumentError, /fields: x needs a field name/)
    end

    it "raises on a value: outside 0..1, or a box that leaves the frame" do
      expect { view.reactive_box(fields: fields, value: value.merge(x: -0.1)) }
        .to raise_error(ArgumentError, /value: x must be a number from 0 to 1 \(a fraction\), got -0.1/)
      expect { view.reactive_box(fields: fields, value: value.merge(height: 1.5)) }
        .to raise_error(ArgumentError, /value: height must be a number from 0 to 1/)
      expect { view.reactive_box(fields: fields, value: value.merge(x: "0.1")) }
        .to raise_error(ArgumentError, /value: x must be a number from 0 to 1 \(a fraction\), got "0.1"/)
      expect { view.reactive_box(fields: fields, value: value.merge(x: 0.6, width: 0.5)) }
        .to raise_error(ArgumentError, /x \+ width is 1.1/)
      expect { view.reactive_box(fields: fields, value: value.merge(width: 0)) }
        .to raise_error(ArgumentError, /width must be greater than 0/)
    end

    it "accepts a box that ends exactly at the frame's edge (float sums included)" do
      expect { view.reactive_box(fields: fields, value: { x: 0.7, y: 0.6, width: 0.3, height: 0.4 }) }
        .not_to raise_error
    end

    it "accepts the fields' own rounding (4 decimals) at the edge, but not more" do
      # 0.45545 + 0.54455 rounded apart is 0.4555 + 0.5446 = 1.0001
      expect { view.reactive_box(fields: fields, value: { x: 0.4555, y: 0, width: 0.5446, height: 1 }) }
        .not_to raise_error
      expect { view.reactive_box(fields: fields, value: { x: 0.4556, y: 0, width: 0.5446, height: 1 }) }
        .to raise_error(ArgumentError, /x \+ width is 1.0002/)
    end

    it "raises on missing value: keys" do
      expect { view.reactive_box(fields: fields, value: value.except(:y)) }
        .to raise_error(ArgumentError, /value: is missing :y/)
    end

    it "raises on a non-positive or oversized min:" do
      expect { box(min: 0) }.to raise_error(ArgumentError, /min: must be a fraction of the frame above 0/)
      expect { box(min: -0.1) }.to raise_error(ArgumentError, /min: must be a fraction/)
      expect { box(min: 1.5) }.to raise_error(ArgumentError, /min: must be a fraction/)
      expect { box(min: "0.1") }.to raise_error(ArgumentError, /min: must be a fraction/)
    end

    it "raises on an aspect: that is neither a positive Numeric nor a field name" do
      expect { box(aspect: 0) }.to raise_error(ArgumentError, /aspect: must be a positive Numeric/)
      expect { box(aspect: true) }.to raise_error(ArgumentError, /aspect: must be a positive Numeric/)
      expect { box(aspect: "") }.to raise_error(ArgumentError, /aspect: must be a positive Numeric/)
      expect { box(aspect: Float::INFINITY) }.to raise_error(ArgumentError, /aspect: must be a positive Numeric/)
    end

    it "raises on a ratio written as a String, saying to pass a Numeric" do
      expect { box(aspect: "16:9") }.to raise_error(ArgumentError, %r{"16:9" is a ratio, not a field name — pass 16/9r})
      expect { box(aspect: "1.5") }.to raise_error(ArgumentError, /"1.5" is a ratio/)
    end

    it "raises on bad messages:" do
      expect { box(messages: "x") }.to raise_error(ArgumentError, /messages: must be a Hash/)
      expect { box(messages: { dropped: "x" }) }.to raise_error(ArgumentError, /unknown messages: key :dropped/)
      expect { box(messages: { moved: 1 }) }.to raise_error(ArgumentError, /messages: moved must be a String/)
    end

    it "works on a ClientBindings view without action:" do
      klass = Class.new(Phlex::HTML) do
        include Phlex::Reactive::ClientBindings

        def view_template
          div(**reactive_frame) do
            div(**reactive_box(fields: { x: "x", y: "y", width: "w", height: "h" },
              value: { x: 0, y: 0, width: 1, height: 1 }))
          end
        end
      end
      expect(klass.new.call).to include("data-reactive-box=", "left: 0%; top: 0%; width: 100%; height: 100%;")
    end

    it "refuses action: on a ClientBindings view (an action needs a token)" do
      view = Class.new(Phlex::HTML) { include Phlex::Reactive::ClientBindings }.new
      expect { view.reactive_box(fields: fields, value:, action: :crop) }
        .to raise_error(ArgumentError, /action: needs the full Phlex::Reactive::Component/)
    end
  end

  describe "#reactive_box_handle" do
    it "marks an edge or corner and places it there" do
      attrs = view.reactive_box_handle(:se)
      expect(attrs[:data]).to eq(reactive_box_handle: "se")
      expect(attrs[:style]).to eq(
        "position: absolute; left: 100%; top: 100%; translate: -50% -50%; touch-action: none; cursor: nwse-resize;"
      )
      expect(view.reactive_box_handle("n")[:style]).to include("left: 50%; top: 0%;", "cursor: ns-resize;")
      expect(view.reactive_box_handle(:w)[:style]).to include("left: 0%; top: 50%;", "cursor: ew-resize;")
      expect(view.reactive_box_handle(:ne)[:style]).to include("cursor: nesw-resize;")
    end

    it "is focusable by a press, but not a tab stop (the box is)" do
      expect(view.reactive_box_handle(:nw)[:tabindex]).to eq(-1)
    end

    it "raises on an unknown edge, listing the valid ones" do
      expect { view.reactive_box_handle(:top) }
        .to raise_error(ArgumentError, /unknown edge :top — one of :nw, :n, :ne, :e, :se, :s, :sw, :w/)
    end
  end

  describe "#reactive_point" do
    let(:point_fields) { { x: "focus[x]", y: "focus[y]" } }

    it "renders its centre at value: as percentages" do
      attrs = view.reactive_point(fields: point_fields, value: { x: 0.5, y: 0.25 })
      expect(attrs[:style]).to eq(
        "position: absolute; left: 50%; top: 25%; translate: -50% -50%; touch-action: none; cursor: move;"
      )
      expect(attrs[:tabindex]).to eq(0)
      expect(JSON.parse(data(attrs)[:reactive_point])).to eq("x" => "focus[x]", "y" => "focus[y]")
      expect(data(attrs).keys).to contain_exactly(:reactive_point, :reactive_point_messages)
    end

    it "takes within: (the element it sits inside, whose box its fractions are of), action: and busy:" do
      attrs = data(view.reactive_point(fields: point_fields, value: { x: 0, y: 1 }, within: "#region-box",
        action: :crop, busy: { add_class: "opacity-50" }))
      expect(attrs).to include(reactive_point_within: "#region-box", reactive_point_action: "crop")
      expect(JSON.parse(attrs[:reactive_point_busy])).to eq("add_class" => ["opacity-50"])
    end

    it "raises on missing fields: keys, a value: outside 0..1, or a blank within:" do
      expect { view.reactive_point(fields: { x: "focus[x]" }, value: { x: 0, y: 0 }) }
        .to raise_error(ArgumentError, /fields: is missing :y/)
      expect { view.reactive_point(fields: point_fields, value: { x: 2, y: 0 }) }
        .to raise_error(ArgumentError, /value: x must be a number from 0 to 1/)
      expect { view.reactive_point(fields: point_fields, value: { x: 0, y: 0 }, within: " ") }
        .to raise_error(ArgumentError, /within: needs a CSS selector/)
    end

    it "works on a ClientBindings view" do
      expect(client_only.new.call).to include("data-reactive-frame", "left: 50%; top: 25%;")
    end
  end

  it "renders a whole picker through Phlex" do
    html = view.call
    expect(html).to include("data-reactive-frame", "data-reactive-box=", 'data-reactive-box-handle="se"',
      'tabindex="0"', 'tabindex="-1"', 'class="relative"')
  end
end
