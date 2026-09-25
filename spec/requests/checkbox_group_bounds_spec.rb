# frozen_string_literal: true

require "rails_helper"

# Issue #258: the empty-group announcement resolves against the action's
# DECLARATION and nothing else. The endpoint builds the wire name it expects
# from each declared array param and compares; it never parses the announced
# name into a key. So a name the action did not declare as an array cannot
# reach the params at all — the keyword default stands, which is exactly
# today's behaviour.
RSpec.describe "The announcement is bounded by the declaration (issue #258)", type: :request do
  # Restore the lazy default after every example — remove the ivar entirely so
  # an explicit `= false` from one example never leaks into the next.
  around do
    it.run
  ensure
    if Phlex::Reactive.instance_variable_defined?(:@verbose_errors)
      Phlex::Reactive.remove_instance_variable(:@verbose_errors)
    end
  end

  let(:payload) { { "s" => { "received" => nil } } }

  def received(response)
    JSON.parse(CGI.unescapeHTML(response.body[%r{data-testid="received">(.*?)</pre>}m, 1]))
  end

  it "ignores a name the action never declared" do
    post_reactive_multipart(CheckboxGroupComponent, "save", payload:,
      params: { "subscribe" => "yes" }, empty_groups: ["admin_ids"])

    expect(response).to have_http_status(:ok)
    expect(received(response).key?("admin_ids")).to be(false)
  end

  it "ignores a declared param that is not an array type" do
    post_reactive_multipart(CheckboxGroupComponent, "save", payload:,
      params: {}, empty_groups: ["subscribe"])

    expect(response).to have_http_status(:ok)
    expect(received(response)["subscribe"]).to be_nil
  end

  it "ignores a nested name rather than building the nesting" do
    # `save_scoped` declares features one level down. The endpoint resolves a
    # top-level name (optionally scope-prefixed) and nothing deeper, so the
    # group is not filled AND no `project` key is invented to hold it.
    post_reactive_multipart(CheckboxGroupComponent, "save_scoped", payload:,
      params: {}, empty_groups: ["project[features]"])

    expect(response).to have_http_status(:ok)
    expect(received(response)["project"]).to be_nil
  end

  it "fills a group whose schema was written with string keys" do
    post_reactive_multipart(CheckboxGroupComponent, "save_string_keys", payload:,
      params: {}, empty_groups: ["features"])

    expect(received(response)["features"]).to eq([])
  end

  it "ignores a malformed name" do
    post_reactive_multipart(CheckboxGroupComponent, "save", payload:,
      params: { "subscribe" => "yes" }, empty_groups: ["features[", ""])

    expect(response).to have_http_status(:ok)
    expect(received(response)["features"]).to be_nil
  end

  it "still answers 200 when the announcement itself is not a list" do
    # `empty_groups` is request data like any other: `empty_groups=features` from
    # a query string is a String, and iterating it would raise.
    token = reactive_token_for(CheckboxGroupComponent, payload)
    post "#{Phlex::Reactive.action_path}?empty_groups=features",
      params: { token:, act: "save", params: { "subscribe" => "yes" } },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }

    expect(response).to have_http_status(:ok)
    expect(received(response)["features"]).to be_nil
  end

  it "still answers 200 when params arrived as a string" do
    # `params[:params]` is whatever arrived: `params=x` from a query string is a
    # String, which coerce normalises to {}. Writing an announcement into it
    # would raise, so a request that answers 200 today has to keep doing so.
    token = reactive_token_for(CheckboxGroupComponent, payload)
    post "#{Phlex::Reactive.action_path}?params=x&empty_groups[]=features",
      params: { token:, act: "save" },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }

    expect(response).to have_http_status(:ok)
  end

  describe "the diagnostic for an ignored announcement" do
    # The whole price of this rule is that it is narrower than it looks, so an
    # announcement that resolved to nothing is reported rather than silent.
    before { allow(Rails.logger).to receive(:warn) }

    it "names the real reason, and does not route through the shape hints" do
      # `:undeclared` would: those hints read the path as a param name, find
      # `features` declared at top level, and advise nesting it under
      # `empty_groups` — the internal wire field.
      Phlex::Reactive.verbose_errors = true

      post_reactive_multipart(CheckboxGroupComponent, "save", payload:,
        params: {}, empty_groups: ["subscribe"])

      expect(Rails.logger).to have_received(:warn)
        .with(a_string_including("empty_groups subscribe (undeclared — the action declares no array param"))
      expect(Rails.logger).not_to have_received(:warn).with(a_string_including("{ empty_groups:"))
    end

    it "answers 200 with the diagnostic OFF, the production default" do
      # `verbose_errors` defaults on in dev+test and OFF in production, where the
      # collector is nil — so the reporting path must not be the only one tested.
      Phlex::Reactive.verbose_errors = false

      post_reactive_multipart(CheckboxGroupComponent, "save", payload:,
        params: {}, empty_groups: ["admin_ids"])

      expect(response).to have_http_status(:ok)
      expect(Rails.logger).not_to have_received(:warn)
    end
  end
end
