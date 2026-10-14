# frozen_string_literal: true

require "rails_helper"

# Issue #400: the server renders a countdown's initial text and its
# waiting/done visibility, so the page reads with JavaScript off; the client
# only counts it down from data-reactive-countdown.
RSpec.describe "the countdown page (issue #400)", type: :request do
  include ActiveSupport::Testing::TimeHelpers
  include Phlex::Reactive::TestHelpers

  it "renders the time left, the waiting node shown and the done node hidden" do
    freeze_time do
      get "/countdown", params: { seconds: 90 }
      deadline = (Time.current + 90).utc.iso8601
      expect(response.body).to include(%(data-reactive-countdown="{&quot;until&quot;:&quot;#{deadline}&quot;))
      expect(response.body).to match(%r{data-testid="clock"[^>]*>1:30</span>})
      expect(response.body).to include('<div id="wait" data-testid="wait">Waiting</div>')
      expect(response.body).to include('<div id="done" hidden data-testid="done">Finished</div>')
    end
  end

  it "renders a past deadline finished" do
    get "/countdown", params: { seconds: -5 }
    expect(response.body).to match(%r{data-testid="clock"[^>]*>0:00</span>})
    expect(response.body).to include('<div id="wait" hidden data-testid="wait">Waiting</div>')
    expect(response.body).to include('<div id="done" data-testid="done">Finished</div>')
  end

  it "keeps the deadline across an action's morph" do
    deadline = "2099-01-01T00:00:00Z"
    post_reactive_action(OtpCountdownComponent.new(until_at: deadline), "refresh")
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("{&quot;until&quot;:&quot;#{deadline}&quot;")
    expect(response.body).to include("Refreshed 1")
  end
end
