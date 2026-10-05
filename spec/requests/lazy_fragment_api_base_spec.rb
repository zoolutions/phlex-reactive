# frozen_string_literal: true

require "rails_helper"

# The cacheable-fragment endpoint under an API base controller (issue #277):
# `Phlex::Reactive.base_controller_name = "ActionController::API"` has no
# forgery protection, flash or cookies modules, and the endpoint must not
# assume them. The base is read when the controllers are defined, so this spec
# redefines them under the API base and restores them afterwards.
RSpec.describe "cacheable lazy fragments under ActionController::API", type: :request do
  let(:headers) { { "Accept" => "text/vnd.turbo-stream.html" } }
  let(:payload) { { "c" => "CachedPanelComponent", "s" => { "scope" => "mine" } } }

  def redefine_endpoints(base)
    root = Phlex::Reactive::Engine.root.join("app/controllers/phlex/reactive")
    %i[FragmentsController ActionsController].each do
      # The superclass is fixed at definition: only redefining can change it.
      Phlex::Reactive.send(:remove_const, it) if Phlex::Reactive.const_defined?(it, false) # rubocop:disable RSpec/RemoveConst
    end
    Phlex::Reactive.base_controller_name = base
    load root.join("actions_controller.rb").to_s
    load root.join("fragments_controller.rb").to_s
  end

  around do
    original = Phlex::Reactive.base_controller_name
    Phlex::Reactive::FragmentsController.name # autoload both before swapping
    redefine_endpoints("ActionController::API")
    it.run
  ensure
    redefine_endpoints(original)
  end

  it "is really running on the API base" do
    expect(Phlex::Reactive::FragmentsController.ancestors).to include(ActionController::API)
    expect(Phlex::Reactive::FragmentsController.ancestors).not_to include(ActionController::Base)
  end

  it "renders a cacheable fragment: 200, private max-age, no Set-Cookie" do
    get Phlex::Reactive::Fragment.src(payload), headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("panel:mine")
    expect(response.headers["Cache-Control"]).to eq("max-age=600, private")
    expect(response.headers["Vary"].to_s).to include("Cookie")
    expect(response.headers["Set-Cookie"]).to be_blank
  end

  it "revalidates with a 304" do
    get Phlex::Reactive::Fragment.src(payload), headers: headers
    get Phlex::Reactive::Fragment.src(payload), headers: headers.merge("If-None-Match" => response.headers["ETag"])

    expect(response).to have_http_status(:not_modified)
  end

  it "still refuses to cache a render with a token field, using the built-in names" do
    get Phlex::Reactive::Fragment.src({ "c" => "CachedProbeComponent", "s" => { "markup" => "single" } }),
      headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to eq("no-store")
  end

  it "is no-store for a component that did not opt in" do
    get Phlex::Reactive::Fragment.src({ "c" => "LazyStatsComponent", "s" => { "scope" => "week" } }), headers: headers

    expect(response).to have_http_status(:not_found)
    expect(response.headers["Cache-Control"]).to eq("no-store")
  end
end
