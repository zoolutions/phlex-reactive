# frozen_string_literal: true

require "base64"
require "digest"

module Phlex
  module Reactive
    # Privately cacheable lazy renders (issue #277): the signed id and URL of a
    # `reactive_lazy cache: { max_age: }` component's GET fragment.
    #
    # The id is a DETERMINISTIC signature over the component's identity payload
    # — no expiry, no actor binding, purpose-scoped — so the same component
    # renders the same URL on every page view and the browser's private HTTP
    # cache can reuse the response. It names NO viewer: who the render is for
    # always comes from the session at the endpoint. (Like the identity token it
    # does carry the signed state / record gid — signed, not encrypted.) The
    # purpose makes it disjoint
    # from the identity and defer tokens: a fragment id can't run an action or
    # reach the defer endpoint, and neither of those tokens resolves here.
    #
    # Two unsigned query parameters only shape the browser's cache KEY — the
    # render never reads them:
    #   v — a digest of the component's reactive_cache_version (content changed)
    #   u — a KEYED digest of its reactive_cache_viewer (who the render is
    #       for). The endpoint recomputes it in the CURRENT session and makes
    #       the reply cacheable only when it matches, so a URL can only ever
    #       hold the render of the viewer it names. A blank viewer names nobody:
    #       no `u`, and the reply falls back to `Vary: Cookie`.
    module Fragment
      PURPOSE = "phlex-reactive/fragment"
      VIEWER_PURPOSE = "phlex-reactive/fragment-viewer"
      # A viewer is an identity — an id, or a few of them. These bound how far
      # a collection is walked, so no value can make the shell render slow.
      VIEWER_PART_LIMIT = 32
      VIEWER_NODE_LIMIT = 64
      # Components already warned about (by class name): once per component.
      VIEWER_WARNED = Concurrent::Map.new

      # A reactive_cache_viewer value that cannot name a viewer. Internal: it
      # carries the reason from the walk to viewer_param, which logs it.
      class UnusableViewer < StandardError; end

      module_function

      # The URL-safe signed id of an identity payload. The verifier's token
      # (Base64 + "--" + digest; may hold "+", "/", "=") is wrapped in urlsafe
      # Base64 so it survives as ONE path segment under any configured verifier.
      def sign(payload)
        token = Phlex::Reactive.verifier.generate(payload.merge("v" => TOKEN_VERSION), purpose: PURPOSE)
        Base64.urlsafe_encode64(token, padding: false)
      end

      # The verified, version-upgraded payload, or nil — tampered, a token of
      # another purpose, or not urlsafe Base64 at all.
      def verify(id)
        token = Base64.urlsafe_decode64(id.to_s)
        payload = Phlex::Reactive.verifier.verified(token, purpose: PURPOSE)
        payload && Phlex::Reactive.upgrade_token(payload)
      rescue ::ArgumentError
        nil
      end

      # The fragment URL the shell renders into data-reactive-defer-src:
      # <fragment_path>/<signed id>[?v=<version digest>][&u=<viewer digest>].
      # `version` is the component's reactive_cache_version (nil → no `v`);
      # `viewer` is its ALREADY-DIGESTED viewer_param (nil → no `u`).
      def src(payload, version: nil, viewer: nil)
        query = []
        query << "v=#{version_param(version)}" unless version.nil?
        query << "u=#{viewer}" if viewer
        path = "#{Phlex::Reactive.fragment_path}/#{sign(payload)}"
        query.empty? ? path : "#{path}?#{query.join("&")}"
      end

      # `v` only varies the browser's cache KEY — the endpoint never reads it —
      # so it is digested: short, opaque, and safe for any value an app returns
      # (a Time keeps its sub-second precision, a record its cache key).
      def version_param(version)
        key = version.respond_to?(:utc) ? version.utc.strftime("%Y%m%d%H%M%S%N") : version
        Digest::SHA256.hexdigest(ActiveSupport::Cache.expand_cache_key(key))[0, 16]
      end

      # The `u` of a reactive_cache_viewer value, or nil when the value names
      # NO viewer — nil, false, a blank String, or an Array with any blank part
      # or Hash with any blank leaf (`[Current.user&.id, locale]` signed out),
      # or a value whose cache key is empty. A blank viewer must never
      # become a shared "anonymous" key: every signed-out or mis-resolved
      # session would then store and read ONE url with no Vary. nil sends the
      # component back to the default mode (`Vary: Cookie`) for that render.
      #
      # KEYED: the digest is taken over the verifier's signature of the value,
      # so it can be neither reversed to the value (a user id is a small space)
      # nor computed for someone else without the app's secret. 128 bits.
      #
      # NEVER RAISES and never takes long, whatever the hook returned: this runs
      # inside the host page's render. A value that cannot be turned into a key
      # (it raises, it is endless, it is huge) names nobody — the fail-closed
      # default mode — and is logged once per component (`owner`, its class).
      def viewer_param(viewer, owner: nil)
        return nil unless viewer_named?(viewer)

        signed = Phlex::Reactive.verifier.generate(ActiveSupport::Cache.expand_cache_key(viewer),
          purpose: VIEWER_PURPOSE)
        Digest::SHA256.hexdigest(signed)[0, 32]
      rescue UnusableViewer => e
        warn_unusable_viewer(owner, e.message)
      rescue StandardError => e
        warn_unusable_viewer(owner, "#{e.class}: #{e.message}")
      end

      def viewer_named?(viewer)
        named_within?(viewer, [VIEWER_NODE_LIMIT])
      end

      # Every LEAF must name something. A collection — anything
      # expand_cache_key walks with to_a: an Array, a Hash (keys and values), a
      # Set, a Struct, a sized Enumerator, nested — with one blank part is
      # unnamed, and so is a value whose cache key expands to nothing (an
      # object with a blank to_param). 0 is a viewer.
      #
      # Bounded: a Range is never walked, a collection of more than
      # VIEWER_PART_LIMIT parts or a walk of more than VIEWER_NODE_LIMIT values
      # (a self-referential Array, a to_a that returns itself) is unnamed.
      # `budget` is a one-element counter shared by the whole walk.
      def named_within?(value, budget)
        return false if value.nil? || value == false
        raise UnusableViewer, "a Range is not an identity" if value.is_a?(::Range)
        raise UnusableViewer, "too deep or self-referential" if (budget[0] -= 1).negative?
        return viewer_leaf?(value) unless value.respond_to?(:to_a) && !value.respond_to?(:cache_key)

        size = value.respond_to?(:size) ? value.size : nil
        raise UnusableViewer, "a collection of unknown or excessive size" unless viewer_size_ok?(size, value)

        parts = value.to_a
        raise UnusableViewer, "more than #{VIEWER_PART_LIMIT} parts" if parts.size > VIEWER_PART_LIMIT

        parts.any? && parts.all? { named_within?(it, budget) }
      end

      def viewer_leaf?(value)
        value.present? && ActiveSupport::Cache.expand_cache_key(value).present?
      end

      # An Enumerator must report a finite size; anything sized must be small.
      def viewer_size_ok?(size, value)
        return size <= VIEWER_PART_LIMIT if size.is_a?(::Integer)

        !value.is_a?(::Enumerator) && size.nil?
      end

      # Logs why — once per COMPONENT, naming it, since the cause is that
      # component's hook — and answers nil: "this value names nobody".
      def warn_unusable_viewer(owner, reason)
        name = owner.respond_to?(:name) ? owner.name.to_s : owner.to_s
        return nil if VIEWER_WARNED.put_if_absent(name, true)
        return nil unless defined?(::Rails) && ::Rails.respond_to?(:logger)

        ::Rails.logger&.warn(
          "[phlex-reactive] #{name.presence || "a component"}#reactive_cache_viewer returned a value that " \
          "cannot name a viewer (#{reason}) — treated as no viewer (Vary: Cookie). Return an id, or a small " \
          "Array of ids."
        )
        nil
      end

      # Test seam: let the once-per-component warnings fire again.
      def reset_viewer_warning!
        VIEWER_WARNED.clear
      end

      # The max-age (seconds) the endpoint answers with: the component's
      # declared value, capped by Phlex::Reactive.fragment_cache_max_age_limit.
      def max_age_for(component_class)
        [component_class.reactive_lazy_cache.fetch(:max_age), Phlex::Reactive.fragment_cache_max_age_limit.to_i].min
      end
    end
  end
end
