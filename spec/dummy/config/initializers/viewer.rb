# frozen_string_literal: true

# A minimal authentication gate for the cacheable-fragment fixtures (issue
# #277), on every dummy controller the way an app's ApplicationController
# would have it. The `viewer` cookie names the viewer; some values stand for
# things a real base controller does, so the specs can prove what each does to
# a fragment reply's cacheability:
#   * "expired"        — a session the app no longer accepts: halts with 401
#                        BEFORE the reactive endpoint runs;
#   * "redirected"     — the same, as a redirect to a sign-in page;
#   * "tracked"        — a before_action that WRITES the session (an activity
#                        timestamp) on every request;
#   * "tracked_after"  — the same write from an after_action;
#   * "tracked_around" — the same write from an around_action, after the yield;
#   * "cookied"        — a before_action that sets a cookie of its own;
#   * "cookied_after"  — the same from an after_action;
#   * "rolling"        — re-sets a cookie to the SAME value with a new expiry;
#   * "forgetful"      — deletes a cookie;
#   * "publisher"      — an after_action that makes every reply public;
#   * "flasher"        — a before_action that sets a flash;
#   * "flasher_after"  — the same from an after_action;
#   * "flash_now"      — a before_action that sets flash.now;
#   * "flash_reader"   — a before_action that READS the flash (so this request
#                        sweeps it) and echoes it in an X-Dummy-Flash header;
#   * "no_store"       — a before_action that forbids caching (no_store);
#   * "expires_now_after" — an after_action that calls expires_now.
# An X-Dummy-Vary request header makes the gate set that Vary, the way a
# controller that localizes by Accept-Language would.
module DummyViewerGate
  extend ActiveSupport::Concern

  included do
    before_action :dummy_viewer_before
    after_action :dummy_viewer_after
    around_action :dummy_viewer_around
  end

  private

  def dummy_viewer = cookies[:viewer]

  def dummy_stamp = Process.clock_gettime(Process::CLOCK_MONOTONIC).to_s

  def dummy_viewer_before
    Viewer.who = dummy_viewer
    response.headers["Vary"] = request.headers["X-Dummy-Vary"] if request.headers["X-Dummy-Vary"]

    case dummy_viewer
    when "expired" then head :unauthorized
    when "redirected" then (redirect_to "/lazy_stats" unless request.path == "/lazy_stats")
    when "tracked" then session[:seen_at] = dummy_stamp
    when "cookied" then cookies[:last_seen] = dummy_stamp
    when "rolling" then cookies[:roll] = { value: "same", expires: 1.day }
    when "forgetful" then cookies.delete(:gone)
    when "flasher" then flash[:alert] = "x"
    when "flash_now" then flash.now[:alert] = "n"
    when "flash_reader" then response.headers["X-Dummy-Flash"] = flash.to_h.to_json
    when "no_store" then no_store
    end
  end

  def dummy_viewer_after
    case dummy_viewer
    when "tracked_after" then session[:left_at] = dummy_stamp
    when "cookied_after" then cookies[:left_at] = dummy_stamp
    when "flasher_after" then flash[:alert] = "x"
    when "expires_now_after" then expires_now
    when "publisher"
      expires_in 1.hour, public: true
      response.headers["Vary"] = "Accept-Encoding"
    end
  end

  def dummy_viewer_around
    yield
    session[:around_at] = dummy_stamp if dummy_viewer == "tracked_around"
  end
end

ActiveSupport.on_load(:action_controller_base) { include DummyViewerGate }
