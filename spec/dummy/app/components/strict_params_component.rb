# frozen_string_literal: true

# Exercises the strict numeric param types through the endpoint (issue #460):
# `save` reflects what the method received, so a request spec can tell a dropped
# value (the keyword default) from a typed 0. `cap` is the plain :integer beside
# them, the fabricated zero the strict types exist to avoid.
class StrictParamsComponent < ApplicationComponent
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  KEYWORD_DEFAULT = "keyword default"

  reactive_state :received

  action :save, params: { quantity: :strict_integer, weight: :strict_float, cap: :integer, sizes: [:strict_integer] }

  def initialize(received: nil)
    @received = received
  end

  def id = "strict-params"

  def save(quantity: KEYWORD_DEFAULT, weight: KEYWORD_DEFAULT, cap: KEYWORD_DEFAULT, sizes: KEYWORD_DEFAULT)
    @received = { quantity:, weight:, cap:, sizes: }
  end

  def view_template
    div(id:, **reactive_attrs) do
      pre(data: { testid: "received" }) { @received.to_json }
    end
  end
end
