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
    #   u — a digest of its reactive_cache_viewer (who the render is for). The
    #       endpoint recomputes it in the CURRENT session and makes the reply
    #       cacheable only when it matches, so a URL can only ever hold the
    #       render of the viewer it names.
    module Fragment
      PURPOSE = "phlex-reactive/fragment"

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

      # The `u` digest of a reactive_cache_viewer value. nil is a viewer too
      # (the anonymous one), so every value digests — the scope is always
      # explicit once a component declares the hook. Namespaced so it can never
      # equal a version digest of the same value.
      def viewer_param(viewer)
        Digest::SHA256.hexdigest("viewer:#{ActiveSupport::Cache.expand_cache_key(viewer)}")[0, 16]
      end

      # The max-age (seconds) the endpoint answers with: the component's
      # declared value, capped by Phlex::Reactive.fragment_cache_max_age_limit.
      def max_age_for(component_class)
        [component_class.reactive_lazy_cache.fetch(:max_age), Phlex::Reactive.fragment_cache_max_age_limit.to_i].min
      end
    end
  end
end
