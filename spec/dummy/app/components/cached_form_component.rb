# frozen_string_literal: true

# The cached-fragment CSRF footgun fixture (issue #277): a `cache:` component
# whose real render embeds a form authenticity token. A cached copy of that
# token outlives the session it was minted for, so the fragment endpoint must
# refuse to make this response cacheable (no-store) and say why.
class CachedFormComponent < ApplicationComponent
  include Phlex::Rails::Helpers::FormAuthenticityToken
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  reactive_state :label

  reactive_lazy cache: { max_age: 10.minutes }

  def initialize(label: "x")
    @label = label
  end

  def id = "cached-form"

  def view_template
    div(id:, **reactive_attrs) do
      form(action: "/todos", method: "post") do
        input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)
        button(type: "submit") { @label }
      end
    end
  end
end
