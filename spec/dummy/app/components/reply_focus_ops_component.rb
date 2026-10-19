# frozen_string_literal: true

# Issue #446: a focus, focus_first or blur op in a reply's reactive:js stream
# must survive Turbo's stream focus preservation, which focuses the element
# that had focus before the render again whenever it has an id. Every field
# here has one.
#
#   * The picker: focusing the query shows the list (an on_client focus
#     binding); listnav Enter picks the highlighted option, and the reply hides
#     the list and blurs the query. Undone by Turbo, the query is focused again
#     a frame later, its binding runs and the list is back.
#   * The jump fields: Enter in one posts :jump while that field still has
#     focus, and the reply moves focus to another field (focus) or into a menu
#     (focus_first). Undone by Turbo, focus jumps back to the field.
class ReplyFocusOpsComponent < ApplicationComponent
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  OPTIONS = %w[Alpha Beta].freeze

  reactive_state :picked, :jumps
  action :pick, params: { name: :string }
  action :jump, params: { to: :string }

  def initialize(picked: nil, jumps: 0)
    @picked = picked
    @jumps = jumps
  end

  def id = "reply_focus_ops"

  def pick(name:)
    @picked = name if OPTIONS.include?(name)
    reply.morph.js(js.hide("#picker-list", keep: true).blur("[name=query]"))
  end

  def jump(to:)
    @jumps += 1
    reply.morph.js(to == "menu" ? js.focus_first("#jump-menu") : js.focus("#jump-target"))
  end

  def view_template
    div(**reactive_root) do
      picker
      jumps
    end
  end

  private

  def picker
    input(**mix(
      on_client(:focus, js.show("#picker-list", keep: true)),
      reactive_listnav("[role=option]"),
      id: "picker-query", name: "query", autocomplete: "off",
      data: { testid: "picker-query" }
    ))
    span(data: { testid: "picked" }) { @picked.to_s }
    ul(id: "picker-list", hidden: true, data: { testid: "picker-list" }) do
      OPTIONS.each { |name| li { button(**mix(on(:pick, name:), role: "option")) { name } } }
    end
  end

  def jumps
    input(**mix(on(:jump, event: "keydown.enter", to: "field"), id: "jump-to-field", data: { testid: "jump-to-field" }))
    input(**mix(on(:jump, event: "keydown.enter", to: "menu"), id: "jump-to-menu", data: { testid: "jump-to-menu" }))
    input(id: "jump-target", data: { testid: "jump-target" })
    div(id: "jump-menu") do
      button(id: "jump-menu-first", data: { testid: "jump-menu-first" }) { "First" }
      button(id: "jump-menu-second") { "Second" }
    end
    span(data: { testid: "jumps" }) { @jumps.to_s }
  end
end
