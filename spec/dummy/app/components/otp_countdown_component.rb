# frozen_string_literal: true

# Issue #400: reactive_countdown. The deadline lives in the signed state; the
# server renders the time left and the waiting/done visibility itself (the
# page reads with JavaScript off), and the client counts it down. `refresh`
# morphs with the same deadline (no second reactive:countdown-done);
# `restart` morphs with a new one, a few seconds out.
class OtpCountdownComponent < ApplicationComponent
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  reactive_state :until_at, :refreshes
  action :restart
  action :refresh

  def initialize(until_at: nil, refreshes: 0, seconds: 90)
    @until_at = until_at || (Time.current + seconds).utc.iso8601
    @refreshes = refreshes
  end

  def id = "countdown"

  def restart
    @until_at = (Time.current + 3).utc.iso8601
    reply.morph
  end

  def refresh
    @refreshes += 1
    reply.morph
  end

  def view_template
    div(**reactive_root) do
      span(**reactive_countdown(until: @until_at, waiting: "#wait", done: "#done", data: { testid: "clock" })) { server_text }
      div(id: "wait", hidden: left.zero?, data: { testid: "wait" }) { "Waiting" }
      div(id: "done", hidden: !left.zero?, data: { testid: "done" }) { "Finished" }
      p(data: { testid: "refreshes" }) { "Refreshed #{@refreshes}" }
      button(**mix(on(:refresh), data: { testid: "refresh" })) { "Refresh" }
      button(**mix(on(:restart), data: { testid: "restart" })) { "Restart" }
    end
  end

  private

  def left = [(Time.iso8601(@until_at) - Time.current).ceil, 0].max

  def server_text = Kernel.format("%<m>d:%<s>02d", m: left / 60, s: left % 60)
end
