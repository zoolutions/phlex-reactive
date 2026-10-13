# frozen_string_literal: true

# Issue #373: a preview <img> that shows an image the server already rendered,
# with no URL in any op or binding. The code field drives reactive_media (its
# first three characters pick a pool image); the buttons copy one with
# js.copy_media. The pool holds a URL-string entry ("999") and a non-<img>
# entry ("span") that must clear the preview, and an <iframe> the op must
# never give a src.
class LogoPreviewComponent < ApplicationComponent
  include Phlex::Reactive::Component

  POOL = {
    "007" => "#logo-007",
    "011" => "#logo-011",
    "050" => "#logo-050",
    "999" => "https://example.test/a.svg",
    "spa" => "#logo-text"
  }.freeze

  def id = "logo-preview"

  def view_template
    div(**reactive_root) do
      input(name: "code", data: { testid: "code" }, autocomplete: "off")
      img(id: "logo", alt: "", **reactive_media(from: :code, take: 3, pool: POOL, label: "#caption",
        blank_label: "Unknown", data: { testid: "preview" }))
      span(id: "caption", data: { testid: "caption" })
      pool
      buttons
      iframe(id: "frame", title: "frame", data: { testid: "frame" })
    end
  end

  private

  def pool
    img(id: "logo-007", src: "/logos/007.svg", srcset: "/logos/007.svg 1x", alt: "North", hidden: true)
    img(id: "logo-011", src: "/logos/011.svg", alt: "South", hidden: true)
    img(id: "logo-050", alt: "Bank Al-Maghrib", hidden: true)
    span(id: "logo-text", hidden: true) { "/logos/007.svg" }
  end

  def buttons
    button(**mix(on_client(:click, js.copy_media("#copied", from: "#logo-007")), data: { testid: "use-north" })) { "North" }
    button(**mix(on_client(:click, js.copy_media("#copied", from: "#logo-011")), data: { testid: "use-south" })) { "South" }
    button(**mix(on_client(:click, js.copy_media("#copied", from: "#missing")), data: { testid: "use-none" })) { "None" }
    button(**mix(on_client(:click, js.copy_media("#copied", from: "#logo-050")), data: { testid: "use-nologo" })) { "No logo" }
    button(**mix(on_client(:click, js.copy_media("#frame", from: "#logo-007")), data: { testid: "use-frame" })) { "Frame" }
    img(id: "copied", alt: "", data: { testid: "copied" })
  end
end
