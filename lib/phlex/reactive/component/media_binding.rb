# frozen_string_literal: true

module Phlex
  module Reactive
    module Component
      # A preview image that follows a field (issue #373), with no URL in the
      # page's ops or attributes: the server renders every candidate <img>
      # (hidden), and the binding copies the one whose key matches.
      #
      #   input(name: "code")
      #   img(id: "logo", alt: "", **reactive_media(
      #     from: :code, take: 3,
      #     pool: { "007" => "#logo-007", "011" => "#logo-011" },
      #     label: "#caption", blank_label: "Unknown"
      #   ))
      #   img(id: "logo-007", src: "/logos/007.svg", alt: "North", hidden: true)
      #
      # The field is read the way reactive_show reads one (owned fields, a
      # radio group's checked value, reactive_scope applied). `take:` keeps the
      # first n characters as the key; omit it to use the whole value. A pool
      # value is a CSS SELECTOR for an <img> inside the root, never a URL: the
      # client copies that element's src, srcset and alt the way
      # js.copy_media does. A key, selector or element that misses clears the
      # preview. `label:` names a node whose textContent becomes the chosen
      # image's alt (`blank_label`, or "", on a miss). Client-only: no token,
      # no round trip.
      #
      # Until the field has `take` characters, or while `match:` (a Regexp,
      # anchored to the whole key) rejects the key, the binding is PENDING
      # (issue #380): never `blank_label`. `pending: :clear` (the default)
      # clears the preview and empties the label; `pending: :keep` leaves both
      # alone. The preview's data-reactive-media-state reads pending, hit or
      # miss, so a row can hide itself with CSS until there is an answer.
      #
      # Named MediaBinding, not Media: this module sits in every reactive
      # component's ancestry, and a bare `Media` would shadow a host app's kit
      # component of that name (issue #233).
      module MediaBinding
        def reactive_media(from:, pool: nil, take: nil, match: nil, pending: :clear, label: nil, blank_label: nil, **attrs)
          wire = { "field" => media_field!(from) }
          wire["take"] = media_take!(take) unless take.nil?
          wire["match"] = MediaPattern.to_js(match) unless match.nil?
          wire["pending"] = "keep" if media_pending!(pending) == "keep"
          wire["pool"] = media_pool!(pool)
          wire["label"] = media_selector!(:label, label) unless label.nil?
          wire["blank"] = blank_label.to_s unless blank_label.nil?
          mix({ data: { reactive_media: wire.to_json } }, attrs)
        end

        private

        def media_field!(from)
          name = from.to_s if from.is_a?(Symbol) || from.is_a?(String)
          return name unless name.nil? || name.strip.empty?

          raise ArgumentError, "reactive_media from: needs the field name to watch (e.g. from: :code), got #{from.inspect}"
        end

        def media_take!(take)
          return take if take.is_a?(Integer) && take.positive?

          raise ArgumentError, "reactive_media take: must be a positive Integer (or omitted for the whole value), " \
                               "got #{take.inspect}"
        end

        def media_pending!(pending)
          mode = pending.to_s if pending.is_a?(Symbol) || pending.is_a?(String)
          return mode if %w[clear keep].include?(mode)

          raise ArgumentError, "reactive_media pending: must be :clear or :keep, got #{pending.inspect}"
        end

        def media_pool!(pool)
          if pool.nil?
            raise ArgumentError, "reactive_media needs pool: — a Hash of key => selector of a server-rendered <img> " \
                                 "(e.g. pool: { \"007\" => \"#logo-007\" })"
          end
          unless pool.is_a?(Hash) && !pool.empty?
            raise ArgumentError,
              "reactive_media pool: must be a non-empty Hash of key => <img> selector, got #{pool.inspect}"
          end

          pool.to_h { |key, selector| [key.to_s, media_selector!(:pool, selector)] }
        end

        # A pool value or label: is a selector, never a URL — the client only
        # ever passes it to querySelector.
        def media_selector!(kind, selector)
          if selector == JS::ROOT_SENTINEL
            raise ArgumentError,
              "reactive_media #{kind}: #{selector} names the whole root — pass the selector of an element inside it"
          end
          return selector if selector.is_a?(String) && !selector.strip.empty?

          raise ArgumentError,
            "reactive_media #{kind}: values are CSS selectors (e.g. \"#logo-007\"), got #{selector.inspect}"
        end
      end
    end
  end
end
