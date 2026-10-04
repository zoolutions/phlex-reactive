# frozen_string_literal: true

# A minimal authentication gate for the cacheable-fragment fixtures (issue
# #277), on every dummy controller the way an app's ApplicationController
# would have it: the `viewer` cookie names the viewer, and the value "expired"
# stands for a session the app no longer accepts — the gate halts with 401
# BEFORE the reactive endpoint runs (the "base controller rejected the request"
# path, whose reply must still be no-store).
ActiveSupport.on_load(:action_controller_base) do
  before_action do
    Viewer.who = cookies[:viewer]
    head :unauthorized if cookies[:viewer] == "expired"
  end
end
