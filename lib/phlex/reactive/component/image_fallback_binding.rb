# frozen_string_literal: true

module Phlex
  module Reactive
    module Component
      # An <img> that falls back when its src fails and recovers when the src
      # changes (issue #383).
      #
      #   img(id: "logo", alt: "", **reactive_image_fallback(hide: true))
      #   img(id: "logo", alt: "Bank", **reactive_image_fallback(show_alt: "#bank-name"))
      #   span(id: "bank-name", hidden: true)
      #
      # On `error` the client sets data-reactive-image-state="error", adds
      # `hidden` (hide: true, the default) and, with show_alt:, writes the
      # img's alt into that node (a CSS selector inside the root) and shows it.
      # On `load` the state is "loaded". A later src — copy_media,
      # reactive_media, preview_file, a morph, or any src that loads — clears
      # the error and shows the img again; an img with no src is never an
      # error. hide: false leaves visibility alone: style the state with CSS.
      # Composes with reactive_media (its **attrs mix the data attribute in):
      #
      #   img(**reactive_media(from: :rib, pool: POOL, **reactive_image_fallback))
      #
      # Named ImageFallbackBinding for the reason MediaBinding is (issue #233).
      module ImageFallbackBinding
        def reactive_image_fallback(hide: true, show_alt: nil, **attrs)
          wire = { "hide" => image_fallback_hide!(hide) }
          wire["alt"] = image_fallback_alt!(show_alt) unless show_alt.nil?
          mix({ data: { reactive_image_fallback: wire.to_json } }, attrs)
        end

        private

        def image_fallback_hide!(hide)
          return hide if [true, false].include?(hide)

          raise ArgumentError, "reactive_image_fallback hide: must be true or false, got #{hide.inspect}"
        end

        # A selector the client passes to querySelector, never a URL.
        def image_fallback_alt!(selector)
          if selector == JS::ROOT_SENTINEL
            raise ArgumentError,
              "reactive_image_fallback show_alt: #{selector} names the whole root — pass the selector of a node inside it"
          end
          return selector if selector.is_a?(String) && !selector.strip.empty?

          raise ArgumentError,
            "reactive_image_fallback show_alt: must be a CSS selector (e.g. \"#bank-name\"), got #{selector.inspect}"
        end
      end
    end
  end
end
