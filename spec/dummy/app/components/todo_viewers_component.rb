# frozen_string_literal: true

# Issue #358: a presence roster. Who is viewing this todo (one entry per
# person, with a seat count), and which of three steps each tab has selected.
# Selecting a step is the js.presence op: no action of the app's own. A step
# above 3 is refused by authorize_presence_state!.
class TodoViewersComponent < ApplicationComponent
  include Phlex::Reactive::Component

  class Denied < StandardError
  end

  STEPS = [1, 2, 3].freeze

  reactive_record :todo
  reactive_presence :viewers, state: { selected: :integer }, ttl: 30

  def initialize(todo:)
    @todo = todo
  end

  def id = "todo-viewers-#{@todo.id}"

  def authorize_presence_state!(selected: nil)
    raise Denied, "no such step" if selected && !STEPS.include?(selected)
  end

  def view_template
    div(**reactive_root(data: { testid: "viewers" })) do
      ul(data: { testid: "members" }) do
        presence.members.each { member(it) }
      end
      STEPS.each { step(it) }
    end
  end

  private

  def member(member)
    li(**mix(reactive_presence_member(member), data: { testid: "member-#{member.id}" })) do
      plain member.metadata["name"].to_s
      span(data: { testid: "seats" }) { member.seats.size.to_s } if member.seats.size > 1
    end
  end

  def dot(peer)
    span(**reactive_presence_peer(peer), class: "dot") { peer.metadata["name"].to_s[0] }
  end

  def step(number)
    button(**mix(on_client(:click, js.presence(selected: number)), data: { testid: "step-#{number}" })) do
      plain "Step #{number}"
      presence.where(selected: number).each { dot(it) }
    end
  end
end
