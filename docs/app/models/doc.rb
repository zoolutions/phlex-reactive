# frozen_string_literal: true

# Registry of the reference docs. Each entry maps a URL slug to its title, sidebar
# group, and the Phlex page class that renders it (hand-authored — the docs are
# self-contained Phlex, so they survive when the gem's docs/ folder is gone at
# deploy). DocsController renders `view_class`.
class Doc
  REGISTRY = [
    { slug: 'installation',          title: 'Installation',            group: 'Guide',    view: 'Installation' },
    { slug: 'architecture',          title: 'Architecture',            group: 'Guide',    view: 'Architecture' },
    { slug: 'actions-events',        title: 'Actions & events',        group: 'Guide',    view: 'ActionsEvents' },
    { slug: 'security',              title: 'Security & threat model', group: 'Guide',    view: 'Security' },
    { slug: 'broadcasting',          title: 'Broadcasting',            group: 'Guide',    view: 'Broadcasting' },
    { slug: 'transport-pgbus',       title: 'Transport: pgbus',        group: 'Guide',    view: 'TransportPgbus' },
    { slug: 'deferred-rendering',    title: 'Deferred rendering',      group: 'Guide',
      view: 'DeferredRendering' },
    { slug: 'async-actions',         title: 'Async actions',           group: 'Guide',    view: 'AsyncActions' },
    { slug: 'effects',               title: 'Effects',                 group: 'Guide',    view: 'Effects' },
    { slug: 'testing',               title: 'Testing',                 group: 'Guide',    view: 'Testing' },
    { slug: 'performance',           title: 'Performance',             group: 'Guide',    view: 'Performance' },
    { slug: 'observability',         title: 'Observability & APM',     group: 'Guide',    view: 'Observability' },
    { slug: 'tooling',               title: 'Debugging & tooling',     group: 'Guide',    view: 'Tooling' },
    { slug: 'examples',              title: 'Examples overview',       group: 'Examples', view: 'ExamplesOverview' },
    { slug: 'example-counter',       title: 'Counter',                 group: 'Examples', view: 'ExampleCounter' },
    { slug: 'example-payment-split', title: 'Payment split',           group: 'Examples',
      view: 'ExamplePaymentSplit' },
    { slug: 'example-todo-list',     title: 'Todo list',               group: 'Examples', view: 'ExampleTodoList' },
    { slug: 'example-inline-edit',   title: 'Inline edit',             group: 'Examples', view: 'ExampleInlineEdit' },
    { slug: 'example-collections',   title: 'Collections',             group: 'Examples', view: 'ExampleCollections' },
    { slug: 'example-draft-rows',    title: 'Draft rows (new parent)', group: 'Examples',
      view: 'DraftRowsNewParent' },
    { slug: 'example-uploads',       title: 'File uploads & custom types', group: 'Examples',
      view: 'ExampleUploads' },
    { slug: 'example-notifications', title: 'Notifications',           group: 'Examples',
      view: 'ExampleNotifications' },
    { slug: 'example-chat',          title: 'Cross-tab chat',          group: 'Examples', view: 'ExampleChat' },
    { slug: 'example-loading-states', title: 'Loading states',         group: 'Examples',
      view: 'ExampleLoadingStates' },
    { slug: 'example-defer', title: 'Deferred totals', group: 'Examples',
      view: 'ExampleDefer' },
    { slug: 'example-client-ops', title: 'Client-only ops', group: 'Examples',
      view: 'ExampleClientOps' },
    { slug: 'example-failure', title: 'Failure surface', group: 'Examples',
      view: 'ExampleFailure' },
    { slug: 'example-team-inbox', title: 'Team inbox (flagship)', group: 'Examples',
      view: 'ExampleTeamInbox' },
    { slug: 'example-project-board', title: 'Project board (flagship)', group: 'Examples',
      view: 'ExampleProjectBoard' }
  ].freeze

  attr_reader :slug, :title, :group, :view_name

  def initialize(slug:, title:, group:, view:)
    @slug = slug
    @title = title
    @group = group
    @view_name = view
  end

  def self.all
    REGISTRY.map { new(**it) }
  end

  def self.from_slug(slug)
    all.find { it.slug == slug }
  end

  def self.grouped
    all.group_by(&:group)
  end

  # { group => [DocsKit::NavItem] } for the authored pages — the Registry v2
  # shape docs-kit's AI surfaces (/llms.txt, /llms-full.txt, search) consume via
  # config.nav_registries. Unwritten pages (no view_class) are dropped so the
  # index has no dead entries.
  def self.nav_items
    all.select(&:view_class).group_by(&:group).transform_values do |docs|
      docs.map { |doc| DocsKit::NavItem.new(href: "/docs/#{doc.slug}", label: doc.title) }
    end
  end

  # The hand-authored Phlex page class for this doc (nil if not yet written).
  def view_class
    "Views::Docs::Pages::#{view_name}".safe_constantize
  end

  # The page's URL path — consumed by docs-kit's search index and the .md twin
  # links in /llms.txt (both call #href on each registry page).
  def href = "/docs/#{slug}"
end
