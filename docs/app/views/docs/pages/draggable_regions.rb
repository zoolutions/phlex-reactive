# frozen_string_literal: true

module Views
  module Docs
    module Pages
      class DraggableRegions < DocsUI::Page
        title 'Draggable regions'
        eyebrow 'Guide'
        description 'Move and resize a box, or move a point, over an image or a chart — with mouse, touch or ' \
                    'keyboard — and get its position in fields as fractions. No JavaScript.'

        def lead
          'Mark a frame `reactive_frame`, a box in it `reactive_box`, and a point `reactive_point`: they drag ' \
            'with a mouse, a finger or the keyboard, stay inside the frame, and their fields always hold ' \
            'where they are as fractions of it — a crop box, a focal point, a hotspot, a selection.'
        end

        def content
          try_it
          the_box
          handles
          point
          aspect
          fields_and_action
          keyboard
          styling
          morphs
          reference
        end

        private

        def try_it
          DocsUI::Section('Try it') do
            md <<~MD
              Drag the box to move it, or a handle to resize it, and drag the
              red point to set the focus. Pick a preset to lock the shape: the
              box re-fits around its centre. Then try the keyboard: **Tab** to
              the box, **← → ↑ ↓** to move it, **Alt** + arrows to resize it,
              **Shift** for bigger steps. The fields follow as you drag; each
              release saves once.
            MD
            render Views::Examples::LatencyToggle.new(delay_ms: 600)
            render Views::Examples::LiveExample.new(component: RegionPickerComponent.new, source: demo_source,
                                                    filename: 'app/reactive_components/region_picker_component.rb')
          end
        end

        def the_box
          DocsUI::Section('A box in a frame') do
            md <<~'MD'
              `reactive_frame` marks the coordinate space: its padding box is
              0..1 on each axis. `reactive_box` goes on an element inside it,
              with the names of the fields that hold it and where it is:

              ```ruby
              class CropPicker < Phlex::HTML
                include Phlex::Reactive::Component

                reactive_record :photo
                action :crop, params: { x: :float, y: :float, width: :float, height: :float }

                def crop(x:, y:, width:, height:)
                  authorize! @photo, :update?
                  @photo.update!(crop: { x:, y:, width:, height: })
                  reply.morph
                end

                def view_template
                  div(**reactive_root) do
                    div(**mix(reactive_frame, class: "relative")) do
                      img(src: @photo.url, alt: "", class: "block w-full")
                      div(**reactive_box(
                        fields: { x: "crop[x]", y: "crop[y]", width: "crop[width]", height: "crop[height]" },
                        value: @photo.crop,      # { x: 0.1, y: 0.1, width: 0.5, height: 0.4 }
                        min: 0.05,
                        action: :crop
                      )) do
                        %i[nw n ne e se s sw w].each { span(**reactive_box_handle(it)) }
                      end
                    end
                    @photo.crop.each { |key, value| input(type: "hidden", name: "crop[#{key}]", value:) }
                  end
                end
              end
              ```

              The helper renders the box's `left`, `top`, `width` and `height`
              as percentages of the frame from `value:`, so the first paint is
              right with no JavaScript, and a re-render with new values moves
              it. The box is clamped to the frame and never gets smaller than
              `min:` (a fraction of the frame; 0.05 by default).

              Fractions, not pixels: they survive a resize, a responsive layout
              and a morph, and the server turns them into pixels with the
              dimensions it already knows (`x * image.width`).

              The frame must be positioned — `relative`, or `absolute` for an
              overlay — which is left to you. The fields can be anywhere in the
              root: hidden inputs, or visible ones as in the demo.
            MD
          end
        end

        def handles
          DocsUI::Section('Handles') do
            md <<~MD
              `reactive_box_handle(edge)` goes on an element inside the box. A
              press on it resizes from that edge or corner, the opposite side
              staying put; a press anywhere else on the box moves it. The edges
              are `:nw`, `:n`, `:ne`, `:e`, `:se`, `:s`, `:sw` and `:w`, and the
              helper places each one on its edge with the matching resize
              cursor. Its size and look are yours:

              ```ruby
              span(**mix(reactive_box_handle(:se), class: "size-3 rounded-full bg-white"))
              ```

              A drag starts after a 4 px move, so a click still works. The box,
              its handles and the point are `touch-action: none`: a finger drag
              moves them instead of scrolling the page. A press on the frame
              outside the box does nothing.
            MD
          end
        end

        def point
          DocsUI::Section('A point') do
            md <<~MD
              `reactive_point` is a point — its centre — that moves inside the
              frame, with an `x` and a `y` field:

              ```ruby
              span(**reactive_point(fields: { x: "focus[x]", y: "focus[y]" }, value: { x: 0.5, y: 0.5 }))
              ```

              To keep a point inside a box (a focal point inside a crop), put it
              in the box and pass `within:`, a selector for the element it sits
              in. Its fractions are then of that element, and it moves with the
              box:

              ```ruby
              div(**reactive_box(...)) do
                span(**reactive_point(fields: { x: "focus[x]", y: "focus[y]" }, value: @focus,
                                      within: "[data-reactive-box]"))
              end
              ```

              The point has to sit inside the `within:` element: its percentages
              are of that element, which is what lets the server place it with
              no JavaScript.
            MD
          end
        end

        def aspect
          DocsUI::Section('Locking the aspect ratio') do
            md <<~MD
              `aspect:` locks the box's shape — its width over its height as it
              appears, in pixels. Pass a Numeric (`16/9r`, `1.5`) for a fixed
              ratio, or the name of a field whose value is `"16:9"`, a decimal,
              or `""` for free:

              ```ruby
              div(**reactive_box(fields: { ... }, value: @crop, aspect: "aspect")) { ... }

              { "" => "Free", "16:9" => "16:9", "1:1" => "Square" }.each do |ratio, label|
                label { input(type: "radio", name: "aspect", value: ratio, checked: ratio == @aspect); plain label }
              end
              ```

              The field is read when a drag starts. On a corner the axis you
              moved more decides the size; on an edge the other side grows
              around the box's centre. When the field changes — a preset is
              picked, or `set_value` writes it — the box re-fits to the new
              ratio: the same area, centred where it was, inside the frame. A
              re-fit is a change like a release: the fields get `change` and
              the action is sent.

              The aspect field is an ordinary field of the root, so every
              action collects it. Declare it in the action's params
              (`aspect: :string`) to keep the preset and render it checked
              again, as the demo does.
            MD
          end
        end

        def fields_and_action
          DocsUI::Section('The fields and the action') do
            md <<~MD
              While a box or point moves, the client writes its fields the way
              `set_value` does: the live `.value`, a fraction rounded to 4
              decimals, and a bubbling `input` — at most once per field per
              animation frame. So `reactive_show`, compute reducers and other
              bindings follow the box as it moves. A single `change` fires on
              each field when you let go.

              `action:` is sent once on release, through the root's own
              pipeline: the signed token, the request queue,
              `reactive:before-dispatch`, `busy:` (the same values as
              `on(busy:)`) and the reply. It gets these params; declare them as
              `:float`:

              | Element | Params |
              |---|---|
              | `reactive_box` | `x`, `y`, `width`, `height` — fractions of the frame |
              | `reactive_point` | `x`, `y` — fractions of the frame, or of its `within:` element |

              A drag that ends where it started sends nothing. Without
              `action:` the binding is client-only: it needs no token and works
              on a `Phlex::Reactive::ClientBindings` root, where a form submit
              sends the fields.

              **Check the range before you store it.** The schema casts the
              numbers but does not range-check them, so a forged request can
              post `x: 2`. `reactive_box` refuses to render a box outside the
              frame, so a stored bad value would break every later render of it.
              Refuse anything outside 0..1, or a box whose `x + width` or
              `y + height` passes 1, in the action or with a model validation.
              The fields round to 4 decimals, so allow a sum of up to 1.0001, as
              the helper does. The demo's `inside?` does this.
            MD
          end
        end

        def keyboard
          DocsUI::Section('Keyboard and screen readers') do
            md <<~MD
              The box and the point are focusable (`tabindex="0"`); a handle
              is focusable with a press, but is not a tab stop. On a focused
              box or point:

              | Key | Does |
              |---|---|
              | **← → ↑ ↓** | move it 1% of the frame |
              | **Shift** + arrows | move it 10% |
              | **Alt** + arrows | resize the box from its bottom-right corner, or from the focused handle |
              | **Escape** | while an arrow is held (or during a pointer drag), put it back where it started |

              Each arrow writes the fields (`input`); letting go of the key is
              the release: one `change`, and one request for `action:`, however
              long the key was held. Each step is announced through an
              `aria-live="polite"` region: "Moved to 20%, 15%", "Resized to 45%
              by 60%", "Cancelled". Give the box and the point an `aria-label`
              that says what they are. Translate the words with `messages:` —
              `{x}`, `{y}`, `{width}` and `{height}` are filled in as whole
              percents, so the `%` sign is yours to place:

              ```ruby
              reactive_box(..., messages: {
                moved: t(".moved"),         # "Verschoben nach {x} %, {y} %"
                resized: t(".resized"),
                cancelled: t(".cancelled")
              })
              ```
            MD
          end
        end

        def styling
          DocsUI::Section('Styling the drag') do
            md <<~MD
              The look is yours. While a pointer drag is on, the client sets
              these attributes — style them in CSS, or with Tailwind's `data-*`
              variants as the demo does:

              | Attribute | On |
              |---|---|
              | `data-reactive-frame-active` | the frame |
              | `data-reactive-dragging` | the box, handle or point being pressed |

              The helpers write an inline `style` (the position, `position:
              absolute`, `touch-action: none`, the cursor). To add your own
              inline style, mix it in after the helper's, as a String:

              ```ruby
              div(**mix(reactive_box(...), style: "z-index: 10;", class: "outline-2 outline-white"))
              ```

              A border on the box is inside it (`box-sizing: border-box`), so
              the box covers exactly the region its fields describe. The demo
              uses an outline and a wide box-shadow to dim what the crop leaves
              out.
            MD
          end
        end

        def morphs
          DocsUI::Section('Morphs') do
            md <<~MD
              Where a box or point is lives in its inline style, so a server
              re-render that changes `value:` moves it — after a reply, a
              broadcast or a page refresh. Fields outside what the morph
              rendered are brought along.

              A morph that arrives during a drag does not interrupt it: the
              dragged element's style and its fields are held until release,
              like a field being typed in. The drag's values win, and its
              release sends them.
            MD
          end
        end

        def reference
          DocsUI::Section('Reference') do
            md <<~MD
              ```ruby
              reactive_frame
              reactive_box(fields:, value:, aspect: nil, min: 0.05, action: nil, busy: nil, messages: nil)
              reactive_box_handle(edge)      # :nw :n :ne :e :se :s :sw :w
              reactive_point(fields:, value:, within: nil, action: nil, busy: nil, messages: nil)
              ```

              Every argument is checked when the view renders: missing or
              unknown `fields:` keys, a `value:` outside 0..1 (or a box that
              leaves the frame), an unknown handle edge, a `min:` that is not
              above 0, an `aspect:` that is neither a positive Numeric nor a
              field name (a ratio written as a String, `"16:9"`, says to pass
              `16/9r`), `busy:` without `action:`, or `action:` on a client-only
              view raises an `ArgumentError` that says how to fix it. Under
              `verbose_errors`, an undeclared action raises too.

              The drag code is the client's `drag` feature module (about 3.5 KB
              gzipped). The default client bundles it; with the split client
              (`phlex/reactive/core`) a page without a frame never loads it.
            MD
          end
        end

        def demo_source
          Rails.root.join('app/reactive_components/region_picker_component.rb').read.strip
        end
      end
    end
  end
end
