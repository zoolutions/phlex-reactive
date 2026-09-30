# frozen_string_literal: true

# docs-kit synced: v1.2.1
# Per-site configuration for the shared docs chrome (docs-kit). Everything that
# makes this site look like "phlex-reactive" rather than any other docs site
# lives here; the Shell/Sidebar/ThemeSwitcher themselves are shared with the
# daisyUI docs site via the gem.
#
# The themes MUST match the @plugin "daisyui" { themes: ... } block in
# app/assets/stylesheets/application.tailwind.css, or the switcher offers a theme
# the compiled CSS doesn't ship.
Rails.application.config.to_prepare do
  DocsKit.configure do |c|
    c.brand        = 'phlex-reactive'
    c.title_suffix = 'phlex-reactive'
    # The one-line summary agents read first in /llms.txt (the llmstxt.org
    # blockquote under the H1).
    c.tagline = 'Server-driven reactive Phlex components over a Postgres-backed ' \
                'live transport — no bespoke JS, no client framework.'
    c.themes = %w[dark light synthwave retro cyberpunk valentine dracula night coffee nord sunset]

    # Code blocks: a light base with a dark override, so the highlight stays
    # readable when the switcher lands on a dark daisyUI theme. CSS-only scoping
    # ([data-theme=X]) — no JS, no flash.
    c.code_theme      = 'Rouge::Themes::Github'
    c.code_theme_dark = 'Rouge::Themes::Monokai'

    # The sidebar nav interleaves Demos + Docs, so it stays a bespoke lambda.
    c.nav = -> { DocsNav.groups }

    # nav_registries feeds the AI surfaces (/llms.txt, /llms-full.txt, search)
    # from the registry — the custom c.nav above only drives the sidebar, so
    # without this the AI index would be empty. Doc (the reference-page registry)
    # supplies #nav_items; the live Demos aren't authored .md pages, so they're
    # not indexed.
    c.nav_registries = { 'Docs' => Doc }

    # Topbar: the brand clicks home; a GitHub link with the shipped brand mark.
    c.brand_href    = '/'
    c.topbar_links  = [
      { href: 'https://github.com/zoolutions/phlex-reactive', label: 'GitHub', icon: :github }
    ]

    # SEO / social sharing (docs-kit 1.0.2, DocsUI::MetaTags). Every page emits a
    # full <head>: meta description, Open Graph, Twitter Card, canonical, favicon,
    # theme-color. site_url absolutizes canonical/og:url even off-request (static
    # renders); og_image resolves through Propshaft (image_url) to the digested
    # /assets URL. The image is SITE content — app/assets/images/og/og.png is a
    # hand-built 1200×630 card (regenerate a screenshot card with `bin/rails
    # docs_kit:og` if you prefer). Per-page `description "..."` overrides the
    # site default below and falls back to each page's #lead.
    c.seo.description  = 'Server-driven reactive Phlex components for Rails — ' \
                         'Livewire-style actions and live cross-tab updates, ' \
                         'no bespoke JS. Signed identity, default-deny actions, ' \
                         'pgbus-optional transport.'
    c.seo.site_url     = 'https://phlex-reactive.zoolutions.llc'
    c.seo.og_image     = 'og/og.png'
    c.seo.og_type      = 'website'
    c.seo.twitter_card = 'summary_large_image'
    c.seo.locale       = 'en_US'
    c.seo.theme_color  = '#1d232a' # daisyUI dark base-100 (themes.first)
    # favicon href is used verbatim (not through the asset pipeline), so it's a
    # public/ path served at a stable root URL — see public/favicon.svg.
    c.seo.favicon      = '/favicon.svg'
  end
end
