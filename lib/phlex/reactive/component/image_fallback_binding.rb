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
      #
      # wrap: (issue #392) names the box around the img (a CSS selector inside
      # the root, like show_alt:). On error the client hides it and marks the
      # hide as its own (data-reactive-wrap-hidden); recovery shows it again
      # only when that mark is there, so a wrapper the author hid stays
      # hidden. The wrapper may hold the img: its text is never written.
      # hide: false with wrap: hides the wrapper only.
      #
      #   span(id: "badge", class: "rounded-full p-1") do
      #     img(id: "logo", alt: "", **reactive_image_fallback(hide: false, wrap: "#badge"))
      #   end
      #
      # Named ImageFallbackBinding for the reason MediaBinding is (issue #233).
      module ImageFallbackBinding
        def reactive_image_fallback(hide: true, show_alt: nil, wrap: nil, **attrs)
          wire = { "hide" => image_fallback_hide!(hide) }
          wire["alt"] = image_fallback_selector!(:show_alt, show_alt, "#bank-name") unless show_alt.nil?
          wire["wrap"] = image_fallback_selector!(:wrap, wrap, "#badge") unless wrap.nil?
          mix({ data: { reactive_image_fallback: wire.to_json } }, attrs)
        end

        private

        def image_fallback_hide!(hide)
          return hide if [true, false].include?(hide)

          raise ArgumentError, "reactive_image_fallback hide: must be true or false, got #{hide.inspect}"
        end

        # A selector the client passes to querySelector, never a URL.
        def image_fallback_selector!(key, selector, example)
          if selector == JS::ROOT_SENTINEL
            raise ArgumentError,
              "reactive_image_fallback #{key}: #{selector} names the whole root — pass the selector of a node inside it"
          end
          return selector if selector.is_a?(String) && !selector.strip.empty?

          raise ArgumentError,
            "reactive_image_fallback #{key}: must be a CSS selector (e.g. \"#{example}\"), got #{selector.inspect}"
        end
      end
    end
  end
end
