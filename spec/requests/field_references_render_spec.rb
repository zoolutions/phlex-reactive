# frozen_string_literal: true

require "rails_helper"

# Issues #394/#395/#396 through the real Rails render path (phlex-rails
# render_in under a controller), not a bare Phlex #call: a same:/after:/clear:
# name the render never produced raises at render, and a correct one renders.
RSpec.describe "show field references at render (issues #394-#396)", type: :request do
  def component(&template)
    Class.new(ApplicationComponent) do
      include Phlex::Reactive::ClientBindings

      def self.name = "FieldRefRequestThing"

      define_method(:view_template, &template)
    end
  end

  def render_page(klass) = ActionController::Base.render(klass.new, layout: false)

  it "renders the dummy demo through its route" do
    get "/field_checks"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("data-reactive-show-clear=")
  end

  it "raises for a typo'd same: through the controller renderer" do
    klass = component do
      div(**reactive_root) do
        input(name: "email")
        p(**reactive_show(unless: { confirm: { same: :emial } })) { "differ" }
        input(name: "confirm")
      end
    end

    expect { render_page(klass) }.to raise_error(ArgumentError, /same: :emial names no field/)
  end

  it "raises for a file input named in clear: through the controller renderer" do
    klass = component do
      div(**reactive_root) do
        div(**reactive_show(if: { kind: "x" }, clear: :photo)) { input(type: "file", name: "photo") }
      end
    end

    expect { render_page(klass) }.to raise_error(ArgumentError, /clear: :photo is a file input/)
  end

  it "renders when every reference resolves" do
    klass = component do
      div(**reactive_root) do
        input(name: "code")
        p(**reactive_show(unless: { code: { digits: 10 } }, after: :blur, clear: :code)) { "bad" }
      end
    end

    expect(render_page(klass)).to include('data-reactive-show-after="code"')
  end
end
