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
      # The names a CSRF token is rendered under (a form's hidden field, or
      # csrf_meta_tags), besides the controller's own
      # request_forgery_protection_token. Cached, such a token would outlive
      # the session it was minted for.
      CSRF_TOKEN_NAMES = %w[authenticity_token csrf-token].freeze
      # One compiled pattern per forgery-protection field name (it is a
      # class-level setting, so in practice one entry), not one per request.
      CSRF_TOKEN_PATTERNS = Concurrent::Map.new

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
        return forbid_caching unless @fragment_cacheable && !caching_forbidden? && cookies_untouched?

        # Re-assert the policy: an inherited after_action may have LOOSENED it
        # (expires_in …, public: true would let a shared cache keep a viewer's
        # fragment) or overwritten the Vary. Tightening was honoured above.
        apply_cache_policy
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

      # Did the app itself forbid caching this reply — `no_store`, `expires_now`
      # or a max-age of zero in a base-controller filter, or the header set by
      # hand? The app may always tighten the policy; this endpoint only refuses
      # to let it be loosened. (This endpoint's OWN max-age can be zero — a
      # fragment_cache_max_age_limit of 0 — which is revalidate-always, not this.)
      def caching_forbidden?
        control = response.cache_control
        return true if control[:no_store] || control[:no_cache]
        return true if response.headers["Cache-Control"].to_s.match?(/\bno-(?:store|cache)\b/i)

        app_cache_directives[:max_age]&.zero? && !@fragment_policy&.fetch(:max_age)&.zero?
      end

      # What the app's own filters asked for, from expires_in (the response's
      # cache_control hash) or a header set by hand: the smallest max-age, and
      # whether must-revalidate was requested.
      def app_cache_directives
        control = response.cache_control
        header = response.headers["Cache-Control"].to_s
        ages = [control[:max_age], header[/\bmax-age=(\d+)/i, 1]].compact.map(&:to_i)
        { max_age: ages.min, must_revalidate: control[:must_revalidate] || header.match?(/\bmust-revalidate\b/i) }
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

        # Rails commits the flash AFTER the action returns (Metal#dispatch), so
        # commit it now: a flash this request set is then in the session data
        # compared below, and so is the sweep of one this request consumed.
        # Either way the session changed, the write is kept and the reply is
        # not stored; committing twice is harmless.
        request.commit_flash

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
        return render_uncacheable(stream, component.class) if stream.match?(csrf_token_markup)

        viewer = component.send(:fragment_viewer_param)
        # The URL must name exactly the viewer of THIS session — or nobody, when
        # the session has none. Anything else (a page rendered before the viewer
        # changed, a hand-built URL) still renders for this session, but must
        # never be stored under another viewer's key.
        return super unless ActiveSupport::SecurityUtils.secure_compare(viewer.to_s, params[:u].to_s)

        # With no viewer named, the cookie is the only thing that tells two
        # viewers apart; with one, the URL does (and was just checked).
        @fragment_policy = { max_age: Phlex::Reactive::Fragment.max_age_for(component.class), vary: viewer.nil? }
        # A filter that already forbade caching (an app-wide no_store) wins.
        return super if caching_forbidden?

        apply_cache_policy
        render_conditional(stream)
        # Only now: anything that raised above leaves the reply no-store.
        @fragment_cacheable = true
      end

      # The conditional GET, with the ETag set from the BODY ALONE. Not
      # stale?/fresh_when: those run the controller's etaggers, and Rails' own
      # flash etagger LOADS the flash — which marks a pending flash as used, so
      # a fragment GET would eat a notice meant for the next page view. (An
      # app's `etag { }` blocks are skipped for the same reason; vary a cached
      # fragment through reactive_cache_version / reactive_cache_viewer.)
      def render_conditional(stream)
        response.weak_etag = stream
        request.fresh?(response) ? head(:not_modified) : render(turbo_stream: stream)
      end

      # A `name=` attribute, in any quoting, that names a CSRF token — the
      # well-known names plus this controller's forgery-protection field.
      def csrf_token_markup
        token_name = request_forgery_protection_token.to_s
        CSRF_TOKEN_PATTERNS.compute_if_absent(token_name) do
          names = (CSRF_TOKEN_NAMES | [token_name]).reject(&:empty?).map { Regexp.escape(it) }
          /\bname\s*=\s*["']?(?:#{names.join("|")})(?![\w-])/i
        end
      end

      # `private, max-age=<n>` plus Vary: Cookie in the default mode — tightened
      # by whatever the app's filters asked for (a SHORTER max-age,
      # must-revalidate), never loosened (public, s-maxage,
      # stale-while-revalidate and a longer max-age are dropped). Applied before
      # the render (the 304 carries it) and again after every callback ran
      # (settle_caching).
      def apply_cache_policy
        app = app_cache_directives
        policy = { max_age: [@fragment_policy[:max_age], app[:max_age]].compact.min, public: false }
        policy[:must_revalidate] = true if app[:must_revalidate]
        response.headers.delete("Cache-Control")
        response.cache_control.replace(policy)
        vary_on_cookie if @fragment_policy[:vary]
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
