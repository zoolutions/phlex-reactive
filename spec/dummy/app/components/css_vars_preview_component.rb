# frozen_string_literal: true

# Issue #417: fields feed CSS custom properties on an element — a preview that
# follows its controls with no request. The slider brightens the sample, the
# select rotates it, the checkbox frames it and the radio group pads it. The
# inline properties are the first paint, always the defaults: a page opened
# with ?light=1.3 shows the connect correcting them, and `save` (a morph)
# writes them back, so the binding has to re-seed after it.
class CssVarsPreviewComponent < ApplicationComponent
  include Phlex::Reactive::Component

  VARS = {
    "--light" => "light",
    "--turn" => { field: "turn", unit: "deg" },
    "--framed" => "framed",
    "--gap" => { field: "gap", unit: "px" }
  }.freeze
  TURNS = %w[0 90 180 270].freeze
  FIRST_PAINT = "--light: 1; --turn: 0deg; --framed: 0; filter: brightness(var(--light, 1)); " \
                "rotate: var(--turn, 0deg); outline: calc(var(--framed, 0) * 2px) solid; padding: var(--gap, 4px)"

  reactive_state :light, :saves
  action :save

  def initialize(light: "1", saves: 0)
    @light = light
    @saves = saves
  end

  def id = "css-vars-preview"

  def save
    @saves += 1
    reply.morph
  end

  def view_template
    div(**mix(reactive_root, reactive_css_vars(to: "#sample", vars: VARS))) do
      input(type: "range", name: "light", min: "0.5", max: "1.5", step: "0.05", value: @light,
        data: { testid: "light" })
      select(name: "turn", data: { testid: "turn" }) { TURNS.each { |turn| option(value: turn) { turn } } }
      framed
      gaps
      div(id: "sample", style: FIRST_PAINT, data: { testid: "sample" }) { "Sample" }
      button(**mix(on(:save), data: { testid: "save" })) { "Save" }
      span(data: { testid: "saves" }) { @saves.to_s }
      a(href: "/counter", data: { testid: "away" }) { "Away" }
    end
  end

  private

  def framed
    label do
      input(type: "hidden", name: "framed", value: "0")
      input(type: "checkbox", name: "framed", value: "1", data: { testid: "framed" })
      plain " Framed"
    end
  end

  def gaps
    %w[0 8 16].each do |gap|
      label do
        input(type: "radio", name: "gap", value: gap, data: { testid: "gap-#{gap}" })
        plain " #{gap}"
      end
    end
  end
end
