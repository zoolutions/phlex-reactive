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
    #     re-issued, and a request that changed the session or set any cookie
    #     is not cacheable;
    #   * a render that embeds a form authenticity token is not made cacheable.
    class FragmentsController < ActionsController
      # A form's authenticity token in the render: cached, it would outlive the
      # session it was minted for and fail the form's POST.
      AUTHENTICITY_FIELD = 'name="authenticity_token"'

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

      # Wraps the WHOLE action — callbacks included — so a response the base
      # controller's own filters produced (a 401, a redirect to sign-in) is
      # no-store too, not only the ones this controller renders.
      def process_action(*)
        @state_before = cookie_state
        super
      ensure
        forbid_caching unless @fragment_cacheable
      end

      def forbid_caching
        response.cache_control.clear
        response.headers["Cache-Control"] = "no-store"
        response.headers.delete("ETag")
      end

      def verified_fragment_payload
        Phlex::Reactive.verify_fragment(params.require(:id)) || raise(Phlex::Reactive::InvalidToken.new(
          "fragment id invalid — tampered, or a token of another purpose (identity and defer tokens " \
          "do not resolve at the fragment endpoint)",
          diagnostic: :tampered
        ))
      end

      # The success reply: private, bounded, revalidatable. The ETag is derived
      # from the rendered body (never from `v`/`u`), so a 304 is only ever
      # answered for the exact render this viewer would get.
      def render_real_stream(stream, component)
        return render_uncacheable(stream, component.class) if stream.include?(AUTHENTICITY_FIELD)

        viewer = component.send(:fragment_viewer_param)
        # A viewer-keyed URL that names someone else (a page rendered before the
        # viewer changed, or a hand-built URL): render for THIS viewer, but never
        # let it be stored under the other viewer's key.
        return super if viewer && !ActiveSupport::SecurityUtils.secure_compare(viewer, params[:u].to_s)

        # A request that CHANGED the session or set a cookie (a base-controller
        # filter stamping an activity time, a sign-in side effect) must keep
        # that write, and a reply carrying its Set-Cookie must not be stored.
        return super if cookie_state != @state_before || response.headers["Set-Cookie"].present?

        # Unchanged: don't re-issue it. The cookie store would otherwise send a
        # freshly encrypted Set-Cookie with this very reply, changing the Cookie
        # the next request sends and defeating `Vary: Cookie` within the page.
        request.session_options[:skip] = true
        expires_in Phlex::Reactive::Fragment.max_age_for(component.class), public: false
        # Without a declared viewer the cookie is the only thing that tells two
        # viewers apart; with one, the URL does (and was just checked).
        vary_on_cookie unless viewer
        render turbo_stream: stream if stale?(etag: stream, template: false)
        # Only now: anything that raised above leaves the reply no-store.
        @fragment_cacheable = true
      end

      # Everything this request could turn into a Set-Cookie, as it stands: the
      # session's data and the cookie jar. Compared before the callbacks and
      # after the render. Unreadable state is a fresh object — equal to nothing,
      # so the reply fails closed (no-store) instead of being assumed unchanged.
      def cookie_state
        [session_data, request.cookie_jar.to_hash]
      rescue StandardError
        Object.new
      end

      # The session's data without creating a session: {} when the request has
      # none. Deep-copied, so an in-place change shows up.
      def session_data
        session = request.session
        session.respond_to?(:exists?) && !session.exists? && !session.loaded? ? {} : session.to_h.deep_dup
      end

      # Add Cookie to whatever the base controller or a middleware already
      # varies on — replacing it could let the browser reuse the wrong variant.
      def vary_on_cookie
        fields = response.headers["Vary"].to_s.split(",").map(&:strip).reject(&:empty?)
        response.headers["Vary"] = (fields | ["Cookie"]).join(", ")
      end

      def render_uncacheable(stream, component_class)
        ::Rails.logger&.warn(
          "[phlex-reactive] #{component_class.name} is reactive_lazy(cache:) but its render embeds a form " \
          "authenticity token — served no-store: a cached token outlives its session. Read the CSRF token " \
          "from the csrf-token meta tag at submit time, or drop cache:."
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
