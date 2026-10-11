# frozen_string_literal: true

# A plain-Ruby registry of the live reactive demos (no DB rows for the registry
# itself). Drives the sidebar nav and DemosController#show. Each entry maps a URL
# slug to its title/group/blurb, the reactive component to show source for, a
# call-site snippet, and a `build` proc that constructs the live instance (some
# demos need arguments — Chat needs its messages, Counter a seed).
class Demo
  REGISTRY = [
    {
      slug: 'searchable-combobox',
      title: 'Searchable combobox',
      group: 'Inputs',
      blurb: 'Debounced live filtering over an in-memory list — zero custom JavaScript.',
      component: 'SearchableComboboxComponent',
      build: -> { SearchableComboboxComponent.new },
      call_site: <<~RUBY
        # Mount the component anywhere a Phlex view renders:
        render SearchableComboboxComponent.new

        # Pre-seed the search or selection (both ride in the signed token):
        render SearchableComboboxComponent.new(query: "ru", selected_name: "Ruby")
      RUBY
    },
    {
      slug: 'counter',
      title: 'Counter',
      group: 'Basics',
      blurb: 'State-backed actions with and without params — the simplest reactive shape.',
      component: 'CounterComponent',
      build: -> { CounterComponent.new(count: 0) },
      call_site: <<~RUBY
        # State rides in the signed token; start from any value:
        render CounterComponent.new(count: 0)
      RUBY
    },
    {
      slug: 'payment-split',
      title: 'Payment split',
      group: 'Forms',
      blurb: 'Live sum-to-total rebalancer: nested bracketed params, a disabled ' \
             'computed field, auto-collected siblings — the pattern behind #64–#67.',
      component: 'PaymentSplitComponent',
      build: -> { PaymentSplitComponent.new },
      call_site: <<~RUBY
        # Editing one amount rebalances the peers so they always sum to the
        # total. The fields are model-scoped (split[allowance], …), so the
        # action schema nests under `split:` to match them:
        render PaymentSplitComponent.new(allowance: 700, cash: 200, leasing: 100, total: 1000)
      RUBY
    },
    {
      slug: 'todos',
      title: 'Todo list',
      group: 'Records',
      blurb: 'Record-backed rows (GlobalID identity): add, toggle, inline-rename, archive.',
      component: 'TodoListComponent',
      build: -> { TodoListComponent.new },
      call_site: <<~RUBY
        # The list renders one reactive TodoItemComponent per row, each
        # self-targeting by the Todo's GlobalID:
        render TodoListComponent.new
      RUBY
    },
    {
      slug: 'chat',
      title: 'Chat room',
      group: 'Records',
      blurb: 'Action + live broadcast over Turbo Streams (same-process async cable in this demo).',
      component: 'ChatRoomComponent',
      build: -> { ChatRoomComponent.new(room: 'lobby', messages: ChatMessage.for_room('lobby').last(50)) },
      call_site: <<~RUBY
        # The composer's send_message broadcasts the new message to every
        # subscriber, excluding the sender's own connection:
        render ChatRoomComponent.new(room: "lobby", messages: ChatMessage.for_room("lobby"))
      RUBY
    },
    {
      slug: 'team-inbox',
      title: 'Team inbox',
      group: 'Records',
      blurb: 'The flagship — reactive_collection rows + optimistic archive (revert on ' \
             'failure) + disable_with + cross-tab broadcast + an on_client kebab + error_flash.',
      component: 'TeamInboxComponent',
      build: -> { TeamInboxComponent.new },
      call_site: <<~RUBY
        # A believable inbox composing the whole toolkit. Archive is optimistic
        # (hides instantly, reverts if the server denies a locked message); every
        # change broadcasts to teammates' tabs; the row kebab is a pure client op:
        render TeamInboxComponent.new
      RUBY
    },
    {
      slug: 'project-board',
      title: 'Project board',
      group: 'Records',
      blurb: 'The kanban flagship — drag cards within and across lanes (mouse, touch or keyboard), ' \
             'live in every open tab, with inline rename, confirm-gated archive, and ' \
             'a per-visitor effect-style picker.',
      component: 'ProjectBoardComponent',
      build: -> { ProjectBoardComponent.new },
      call_site: <<~RUBY
        # One shared board, three lanes. The lanes are sortable lists of one
        # group: a drop calls move_card with the card, its lane and position;
        # the actor's board morphs, and peers get each lane it touched:
        render ProjectBoardComponent.new
      RUBY
    }
  ].freeze

  attr_reader :slug, :title, :group, :blurb, :component_name, :call_site, :build

  def initialize(slug:, title:, group:, blurb:, component:, call_site:, build:)
    @slug = slug
    @title = title
    @group = group
    @blurb = blurb
    @component_name = component
    @call_site = call_site
    @build = build
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

  # The live component instance for this demo's page.
  def component
    build.call
  end

  def component_class
    component_name.constantize
  end
end
