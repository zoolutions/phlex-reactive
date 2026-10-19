# frozen_string_literal: true

# Issue #452: reactive_image_fallback inside a Turbo frame. Turbo imports the
# fetched frame into the document and inserts it a few awaits later; an img
# whose request ends in that gap fires its event while detached, where the
# runtime's document listener cannot hear it. The link loads the frame with
# `open`, whose logos 404 (/logos/missing-<n>.svg, one URL each) but one.
class ImageFallbackFrameComponent < ApplicationComponent
  include Phlex::Reactive::ClientBindings

  register_element :turbo_frame

  MISSING = 4

  def initialize(open: false)
    @open = open
  end

  def view_template
    a(href: "/image_fallback_frame?open=1", data: { turbo_frame: "logos", testid: "open" }) { "Show logos" }
    turbo_frame(id: "logos") { logos if @open }
  end

  private

  def logos
    ul(data: { testid: "logos" }) do
      (1..MISSING).each do |n|
        li { img(src: "/logos/missing-#{n}.svg", alt: "Bank #{n}", **reactive_image_fallback(data: { testid: "missing-#{n}" })) }
      end
      li { img(src: "/logos/007.svg", alt: "Bank 007", **reactive_image_fallback(data: { testid: "fine" })) }
    end
  end
end
