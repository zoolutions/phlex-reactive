# frozen_string_literal: true

# Issue #380: reactive_media stays PENDING until the RIB field has `take`
# characters (and, with match:, digits), so blank_label only names a full key
# that misses. The bank row hides itself with CSS on the preview's
# data-reactive-media-state — no controller. A second binding keeps its
# preview while pending (pending: :keep).
class RibPreviewComponent < ApplicationComponent
  include Phlex::Reactive::Component

  def id = "rib-preview"

  def view_template
    div(**reactive_root) do
      style { "#bank-row:has([data-reactive-media-state=pending]) { display: none }" }
      input(name: "rib", data: { testid: "rib" }, autocomplete: "off")
      div(id: "bank-row", data: { testid: "bank-row" }) do
        img(id: "bank-logo", alt: "", **reactive_media(
          from: :rib, take: 3, match: /\A\d{3}\z/, pool: { "007" => "#bank-007" },
          label: "#bank-name", blank_label: "Unknown bank", data: { testid: "preview" }
        ))
        span(id: "bank-name", data: { testid: "bank-name" }) { "Pick a bank" }
      end
      img(id: "kept-logo", src: "/logos/011.svg", alt: "Previous", **reactive_media(
        from: :rib, take: 3, pending: :keep, pool: { "007" => "#bank-007" },
        label: "#kept-name", blank_label: "Unknown bank", data: { testid: "kept" }
      ))
      span(id: "kept-name", data: { testid: "kept-name" }) { "Previous" }
      img(id: "bank-007", src: "/logos/007.svg", alt: "Attijariwafa", hidden: true)
    end
  end
end
