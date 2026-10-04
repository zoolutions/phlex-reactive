# frozen_string_literal: true

module Phlex
  module Reactive
    # The privately cacheable lazy render (issue #277):
    #
    #   GET <Phlex::Reactive.fragment_path>/<signed id>[?v=<version>][&u=<viewer>]
    #
    # renders a `reactive_lazy cache: { max_age: }` component's REAL template as
    # its replace stream, with `Cache-Control: private, max-age=<n>` and an
    # ETag, so the browser reuses it instead of asking again.
    #
    # It is a READ, the defer endpoint's twin: the id is verified, the component
    # is rebuilt from its signed identity and rendered through the same
    # authorization step (the base controller's auth, then whatever
    # from_identity / the render raise). No action runs, no around_action
    # wrapper, no transaction, no params reach the render — `v` and `u` only
    # shape the browser's cache key. Subclassing ActionsController shares that
    # read leg and its error plumbing; only the token, the opt-in gate and the
    # reply's headers differ.
    #
    # What keeps a private cache safe here:
    #   * the id names no viewer — who it renders for always comes from the session;
    #   * only a component that declared `cache:` is reachable (404 otherwise);
    #   * a cached copy is never replayed to another viewer: by default the
    #     reply says `Vary: Cookie`; a component that names its viewer
    #     (reactive_cache_viewer) is keyed on it in the URL instead, and the
    #     reply is cacheable only when that URL names the viewer of THIS session;
    #   * the reply is cacheable ONLY on the success path; every other response
    #     this controller produces — including one a base-controller filter
    #     rendered before the action ran — is `no-store`;
    #   * a cacheable reply carries no Set-Cookie: an unchanged session is not
    #     re-issued, and a request that changed the session or wrote any cookie
    #     — in any callback, before or after the action — is not cacheable;
    #   * a render that embeds a CSRF token is not made cacheable.
    class FragmentsController < ActionsController
      # A CSRF token in the render (a form's hidden field, or csrf_meta_tags):
      # cached, it would outlive the session it was minted for. Any quoting.
      CSRF_TOKEN_MARKUP = /\bname\s*=\s*["']?(?:authenticity_token|csrf-token)(?![\w-])/i

      # Stands in for the response when asking the cookie jar what it WOULD
      # write (CookieJar#write calls set_cookie / delete_cookie per pending
      # write), so pending writes are read through the jar's own public method.
      class CookieWrites < ::Hash
        def set_cookie(name, *) = store(name.to_s, :set)
        def delete_cookie(name, *) = store(name.to_s, :delete)
      end

      def show
        event = { component: nil, outcome: nil }
        Phlex::Reactive.with_url_options(Phlex::Reactive.url_options_for(request)) do
          Phlex::Reactive.instrument("defer", event) do
            render_real_component(event, permit: :reactive_lazy_cache, denied: :not_found) do
              verified_fragment_payload
            end
          end
        end
      end

      private

      # Wraps the WHOLE action — every before/around/after callback included —
      # so the cacheability decision is made last: a response the base
      # controller's filters produced (a 401, a redirect to sign-in) is
      # no-store, and so is a reply during which ANY callback wrote the session
      # or a cookie, however late.
      def process_action(*)
        @session_before = begin
          session_data
        rescue StandardError
          Object.new # unreadable: equal to nothing, so the reply stays no-store
        end
        super
      ensure
        settle_caching
      end

      # The single place a reply becomes cacheable: the success path asked for
      # it AND this request leaves the browser's cookies exactly as they were.
      def settle_caching
        return forbid_caching unless @fragment_cacheable && cookies_untouched?

        # Nothing changed, so don't re-issue the session: the cookie store
        # would otherwise send a freshly encrypted Set-Cookie with this very
        # reply — on a stored response, and changing the Cookie the next
        # request sends (defeating `Vary: Cookie` within the page).
        request.session_options[:skip] = true
      end

      def forbid_caching
        response.cache_control.clear
        response.headers["Cache-Control"] = "no-store"
        response.headers.delete("ETag")
      end

      # True only when it is KNOWN that this request writes no cookie: the
      # session's data is what it was, it is not being renewed or dropped, and
      # the cookie jar has no pending write or delete. Anything unreadable
      # counts as touched — the reply fails closed.
      def cookies_untouched?
        options = request.session_options
        return false if options[:renew] || options[:drop]
        # A cookie written straight onto the response (response.set_cookie),
        # which never passes through the jar.
        return false if response.headers["Set-Cookie"].present?

        session_data == @session_before && pending_cookie_writes.empty?
      rescue StandardError
        false
      end

      # The session's data without creating a session: {} when the request has
      # none. Deep-copied, so an in-place change shows up.
      def session_data
        session = request.session
        session.respond_to?(:exists?) && !session.exists? && !session.loaded? ? {} : session.to_h.deep_dup
      end

      # What the cookie jar will write when the response leaves — including a
      # cookie re-set to the same value with a new expiry, and deletes.
      def pending_cookie_writes
        CookieWrites.new.tap { request.cookie_jar.write(it) }
      end

      def verified_fragment_payload
        Phlex::Reactive.verify_fragment(params.require(:id)) || raise(Phlex::Reactive::InvalidToken.new(
          "fragment id invalid — tampered, or a token of another purpose (identity and defer tokens " \
          "do not resolve at the fragment endpoint)",
          diagnostic: :tampered
        ))
      end

      # The success reply: private, bounded, revalidatable — provisionally; see
      # settle_caching. The ETag is derived from the rendered body (never from
      # `v`/`u`), so a 304 is only ever answered for the exact render this
      # viewer would get.
      def render_real_stream(stream, component)
        return render_uncacheable(stream, component.class) if stream.match?(CSRF_TOKEN_MARKUP)

        viewer = component.send(:fragment_viewer_param)
        # The URL must name exactly the viewer of THIS session — or nobody, when
        # the session has none. Anything else (a page rendered before the viewer
        # changed, a hand-built URL) still renders for this session, but must
        # never be stored under another viewer's key.
        return super unless ActiveSupport::SecurityUtils.secure_compare(viewer.to_s, params[:u].to_s)

        expires_in Phlex::Reactive::Fragment.max_age_for(component.class), public: false
        # With no viewer named, the cookie is the only thing that tells two
        # viewers apart; with one, the URL does (and was just checked).
        vary_on_cookie unless viewer
        render turbo_stream: stream if stale?(etag: stream, template: false)
        # Only now: anything that raised above leaves the reply no-store.
        @fragment_cacheable = true
      end

      # Add Cookie to whatever the base controller or a middleware already
      # varies on — replacing it could let the browser reuse the wrong variant.
      def vary_on_cookie
        fields = response.headers["Vary"].to_s.split(",").map(&:strip).reject(&:empty?)
        response.headers["Vary"] = (fields | ["Cookie"]).join(", ")
      end

      def render_uncacheable(stream, component_class)
        ::Rails.logger&.warn(
          "[phlex-reactive] #{component_class.name} is reactive_lazy(cache:) but its render embeds a CSRF " \
          "token (a form authenticity token or csrf_meta_tags) — served no-store: a cached token outlives its " \
          "session. Read the token from the page's csrf-token meta tag at submit time, or drop cache:."
        )
        render turbo_stream: stream
      end

      def unpermitted_render_message(component_class)
        "#{component_class.name} is not reactive_lazy(cache:) — only a component that opted in is " \
          "reachable at the fragment endpoint"
      end
    end
  end
end
