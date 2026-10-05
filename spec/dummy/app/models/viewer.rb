# frozen_string_literal: true

# The dummy's stand-in for "the signed-in user" (issue #277 fixtures): set per
# request from the `viewer` cookie by the gate in config/initializers/viewer.rb,
# the way a real app's base controller sets Current.user from the session. A
# cacheable fragment renders it, so specs can prove one session never receives
# another's render.
class Viewer < ActiveSupport::CurrentAttributes
  attribute :who
end
