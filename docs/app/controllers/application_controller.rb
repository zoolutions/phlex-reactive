# frozen_string_literal: true

class ApplicationController < ActionController::Base
  include DocsKit::Controller

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  # Presence (issue #358): the site has no sign-in, so each visitor gets a short
  # random id in the session (which csrf_meta_tags already sets). The stream
  # endpoint's authorize hook reads it back as the visitor's identity — an SSE
  # request cannot set a cookie itself.
  before_action { session[:presence_visitor] ||= SecureRandom.hex(8) }

  # render_page comes from DocsKit::Controller (included above) — it renders the
  # Phlex view with layout: false (DocsUI::Shell IS the whole document) AND
  # serves the Markdown twin on a .md request. The site no longer defines its
  # own; the gem's version supersedes it.
end
