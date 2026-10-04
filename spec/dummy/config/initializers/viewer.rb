# frozen_string_literal: true

# A minimal authentication gate for the cacheable-fragment fixtures (issue
# #277), on every dummy controller the way an app's ApplicationController
# would have it. The `viewer` cookie names the viewer; two values stand for
# things a real base controller does:
#   * "expired" — a session the app no longer accepts: the gate halts with 401
#     BEFORE the reactive endpoint runs (that reply must still be no-store);
#   * "tracked" — a filter that WRITES the session on every request (an
#     activity timestamp): the write must survive, and the reply not be cached;
#   * "cookied" — a filter that sets a cookie of its own on every request.
# An X-Dummy-Vary request header makes the gate set that Vary, the way a
# controller that localizes by Accept-Language would.
ActiveSupport.on_load(:action_controller_base) do
  before_action do
    Viewer.who = cookies[:viewer]
    session[:seen_at] = Process.clock_gettime(Process::CLOCK_MONOTONIC) if cookies[:viewer] == "tracked"
    cookies[:last_seen] = Process.clock_gettime(Process::CLOCK_MONOTONIC).to_s if cookies[:viewer] == "cookied"
    response.headers["Vary"] = request.headers["X-Dummy-Vary"] if request.headers["X-Dummy-Vary"]
    head :unauthorized if cookies[:viewer] == "expired"
  end
end
