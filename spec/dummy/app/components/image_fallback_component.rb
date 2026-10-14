# frozen_string_literal: true

# Issue #383: reactive_image_fallback. Every preview here starts on, or can be
# pointed at, a src that 404s (/logos/missing.svg), then recovers through each
# path that changes a src: reactive_media (the rib field), js.copy_media (the
# buttons), js.preview_file (the file input) and a morph reply (the server
# img, whose src the `fix` action changes; `refresh` morphs it unchanged).
class ImageFallbackComponent < ApplicationComponent
  include Phlex::Reactive::Streamable
  include Phlex::Reactive::Component

  MISSING = "/logos/missing.svg"
  POOL = { "001" => "#bank-001", "007" => "#bank-007" }.freeze

  reactive_state :fixed, :refreshes
  action :fix
  action :refresh

  def initialize(fixed: false, refreshes: 0)
    @fixed = fixed
    @refreshes = refreshes
  end

  def id = "image-fallback"

  def fix
    @fixed = true
    reply.morph
  end

  def refresh
    @refreshes += 1
    reply.morph
  end

  def view_template
    div(**reactive_root) do
      bank_logo
      copied_logo
      photo
      server_logo
      badges
      img(id: "bank-001", src: MISSING, alt: "Broken Bank", hidden: true)
      img(id: "bank-007", src: "/logos/007.svg", alt: "Attijariwafa", hidden: true)
    end
  end

  private

  def bank_logo
    input(name: "rib", autocomplete: "off", data: { testid: "rib" })
    img(id: "logo", alt: "", **reactive_media(from: :rib, take: 3, pool: POOL,
      **reactive_image_fallback(hide: true, data: { testid: "logo" })))
  end

  def copied_logo
    button(**mix(on_client(:click, js.copy_media("#copied", from: "#bank-001")), data: { testid: "use-broken" })) { "Broken" }
    button(**mix(on_client(:click, js.copy_media("#copied", from: "#bank-007")), data: { testid: "use-valid" })) { "Valid" }
    button(**mix(on_client(:click, js.copy_media("#copied", from: "#nowhere")), data: { testid: "use-none" })) { "None" }
    img(id: "copied", alt: "", **reactive_image_fallback(show_alt: "#copied-name", data: { testid: "copied" }))
    span(id: "copied-name", hidden: true, data: { testid: "copied-name" })
  end

  def photo
    input(type: "file", id: "photo-file", name: "photo", accept: "image/*",
      **mix(on_client(:change, js.preview_file("#photo-file", into: "#photo")), data: { testid: "photo-file" }))
    img(id: "photo", src: MISSING, alt: "", **reactive_image_fallback(data: { testid: "photo" }))
  end

  def server_logo
    img(id: "server", src: @fixed ? "/logos/007.svg" : MISSING, alt: "Server",
      **reactive_image_fallback(data: { testid: "server" }))
    # An SVG with only a viewBox: naturalWidth may read 0 once loaded.
    img(id: "viewbox", src: "/logos/viewbox.svg", alt: "Viewbox", **reactive_image_fallback(data: { testid: "viewbox" }))
    p(data: { testid: "refreshes" }) { "Refreshed #{@refreshes}" }
    button(**mix(on(:fix), data: { testid: "fix" })) { "Fix" }
    button(**mix(on(:refresh), data: { testid: "refresh" })) { "Refresh" }
  end

  # Issue #392: wrap: hides the padded box around a broken logo, and shows it
  # again when a later src loads. The second box is hidden by the author and
  # must stay hidden through the recovery.
  def badges
    span(id: "badge", class: "rounded-full p-1", data: { testid: "badge" }) do
      img(id: "badge-logo", src: MISSING, alt: "Bank",
        **reactive_image_fallback(hide: false, wrap: "#badge", data: { testid: "badge-logo" }))
    end
    span(id: "kept-badge", hidden: true, data: { testid: "kept-badge" }) do
      img(id: "kept-logo", src: MISSING, alt: "", **reactive_image_fallback(wrap: "#kept-badge", data: { testid: "kept-logo" }))
    end
    button(**mix(on_client(:click, js.copy_media("#badge-logo", from: "#bank-007").copy_media("#kept-logo", from: "#bank-007")),
      data: { testid: "fix-badges" })) { "Fix badges" }
  end
end
