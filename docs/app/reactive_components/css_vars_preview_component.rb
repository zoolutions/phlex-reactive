# frozen_string_literal: true

# Issue #417: a photo preview that follows its controls with no request and no
# JavaScript of the app's own. reactive_css_vars feeds the sliders, the select
# and the checkbox into custom properties on the image; its filter, rotation
# and corners read them through var(). The inline style renders the same
# values, so the first paint is right before the client connects.
class CssVarsPreviewComponent < Phlex::HTML
  include Phlex::Reactive::ClientBindings

  VARS = {
    '--light' => 'light',
    '--sat' => 'sat',
    '--gray' => 'gray',
    '--turn' => { field: 'turn', unit: 'deg' },
    '--radius' => { field: 'radius', unit: 'px' }
  }.freeze
  TURNS = %w[0 90 180 270].freeze
  FIRST_PAINT = '--light: 1; --sat: 1; --gray: 0; --turn: 0deg; --radius: 8px; ' \
                'filter: brightness(var(--light, 1)) saturate(var(--sat, 1)) grayscale(var(--gray, 0)); ' \
                'rotate: var(--turn, 0deg); border-radius: var(--radius, 0px)'

  def view_template
    div(**mix(reactive_root(id: 'css-vars-preview'), reactive_css_vars(to: '#cvp-image', vars: VARS),
              class: 'flex flex-wrap items-center gap-8')) do
      controls
      div(class: 'grid size-60 place-items-center') do
        img(id: 'cvp-image', src: '/css-vars-demo/hillside.svg', alt: 'A hillside at sunset', width: 240, height: 160,
            style: FIRST_PAINT, class: 'transition-[rotate] duration-300', data: { testid: 'cvp-image' })
      end
    end
  end

  private

  def controls
    div(class: 'flex w-60 flex-col gap-3') do
      slider('Brightness', 'light', min: '0.5', max: '1.5', step: '0.05', value: '1')
      slider('Saturation', 'sat', min: '0', max: '2', step: '0.1', value: '1')
      slider('Corners', 'radius', min: '0', max: '48', step: '4', value: '8')
      label(class: 'flex items-center justify-between gap-3 text-sm') do
        span { 'Rotate' }
        select(name: 'turn', class: 'select select-sm w-28', data: { testid: 'cvp-turn' }) do
          TURNS.each { |turn| option(value: turn) { "#{turn}°" } }
        end
      end
      label(class: 'flex items-center gap-2 text-sm') do
        input(type: 'checkbox', name: 'gray', value: '1', class: 'checkbox checkbox-sm', data: { testid: 'cvp-gray' })
        span { 'Black and white' }
      end
    end
  end

  def slider(text, name, **)
    label(class: 'flex flex-col gap-1 text-sm') do
      span { text }
      input(type: 'range', name:, class: 'range range-sm', data: { testid: "cvp-#{name}" }, **)
    end
  end
end
