# frozen_string_literal: true

# Renders the example pages exercised by the system specs. Uses the ERB
# application layout (which loads Turbo + Stimulus + the reactive controller)
# and renders the Phlex component as its body via phlex-rails.
class DemosController < ActionController::Base
  layout "application"

  # slow_feature answers a module import with JavaScript; Rails would refuse
  # a non-XHR GET for JS as a cross-origin script include.
  skip_after_action :verify_same_origin_request, only: :slow_feature

  def counter
    # ?count= renders the counter signed for another state (issue #301).
    render_component CounterComponent.new(count: params.fetch(:count, 0).to_i)
  end

  # Issue #273: the lazily loaded controller layout (early.js eager, the
  # controller after a delayed import()), so triggers fire before connect.
  def early_triggers
    html = render_to_string(EarlyTriggersComponent.new, layout: false)
    render html: html.html_safe, layout: "lazy_controller"
  end

  # Issue #274: a page whose ONLY reactive root is dormant, on the lazily
  # loading layout. ?load=auto fetches the controller when an element first
  # lists it in data-controller (lazyLoadControllersFrom's rule); ?load=eager
  # registers it up front.
  # Issue #275: the hints feature module's first-click cases. ?load= as for
  # /dormant ("" means the spec loads the controller itself); ?dormant=1 renders
  # the root dormant; ?slow=<ms>&slow_feature=hints serves the module late.
  def hinted
    @reactive_load = params[:load].presence_in(%w[auto eager]) || ""
    html = render_to_string(HintedPanelComponent.new(dormant: params[:dormant].present?), layout: false)
    render html: html.html_safe, layout: "lazy_controller"
  end

  def dormant
    @reactive_load = params[:load].presence_in(%w[auto eager]) || "auto"
    html = render_to_string(DormantPanelComponent.new, layout: false)
    visit = %(<a href="/dormant?load=#{@reactive_load}" data-testid="visit">Visit again</a>)
    render html: "#{html}#{visit}".html_safe, layout: "lazy_controller"
  end

  # Issue #303: two roots sharing a window-bound hotkey. ?dormant=both (the
  # default) renders both dormant; ?dormant=second leaves the first awake.
  def hotkey_pair
    @reactive_load = params[:load].presence_in(%w[auto eager]) || "auto"
    first_dormant = params[:dormant] != "second"
    html = [
      render_to_string(HotkeyPairComponent.new(name: "first", dormant: first_dormant), layout: false),
      render_to_string(HotkeyPairComponent.new(name: "second"), layout: false)
    ].join
    render html: html.html_safe, layout: "lazy_controller"
  end

  # Issue #274 + #276: a dormant reactive_lazy(on:) event shell as the page's
  # only reactive root — no client until the panel opens, then one request.
  def dormant_lazy
    @reactive_load = "auto"
    # ?scope=forbidden ships a panel whose materialize is denied (403).
    html = render_to_string(DormantLazyPanelComponent.new(scope: params.fetch(:scope, "mine")), layout: false)
    render html: html.html_safe, layout: "lazy_controller"
  end

  # Issues #274 + #276 + #277: a dormant on: + cache: shell as the page's only
  # reactive root — no client until the panel opens, then one cacheable GET.
  def dormant_cached
    @reactive_load = params[:load].presence_in(%w[auto eager]) || "auto"
    html = render_to_string(DormantCachedPanelComponent.new(scope: "mine"), layout: false)
    render html: html.html_safe, layout: "lazy_controller"
  end

  # Issue #274: what a broadcast or page refresh sends — the root rendered
  # OUTSIDE an actor reply (so dormant), morphed over the live one.
  def dormant_stream
    render turbo_stream: DormantPanelComponent.new(clicks: 7).to_stream_replace(morph: true)
  end

  # Effects (issue #215). The dummy has no asset pipeline, so the page inlines
  # the gem's REAL shipped stylesheet — the browser animations under test are
  # driven by the exact CSS apps get. The duration override AFTER it widens the
  # window the spec's mid-animation assertions (still-present-while-exiting,
  # arrives-wearing-enter-class) have to observe the transient classes.
  def effects
    css = Phlex::Reactive::Engine.root.join("app/assets/stylesheets/phlex/reactive/effects.css").read
    component = render_to_string(EffectsListComponent.new(next_n: 2), layout: false)
    extras = <<~HTML
      <style>#{css}</style>
      <style>:root { --reactive-fx-duration: 600ms; }</style>
    HTML
    render html: extras.html_safe + component, layout: true
  end

  # Client debug mode (issue #108). Force Phlex::Reactive.debug ON around THIS
  # render so the root carries data-reactive-debug="true"; the generic controller
  # then console.groups every dispatch. The spec overrides console.group to write
  # into a probe node and asserts the trace was emitted (with NAMES, never the
  # token/values). Restore the flag after — a global toggled for one page only.
  def debug
    was = Phlex::Reactive.debug
    Phlex::Reactive.debug = true
    render_component CounterComponent.new(count: 0)
  ensure
    Phlex::Reactive.debug = was
  end

  # User-visible failure surface (issue #100): a boom (undeclared → 403 with an
  # error_flash), a success that clears data-reactive-error, and a self-dismissing
  # flash. The page carries a server-rendered <template data-reactive-error-flash>
  # so the offline fallback has something to clone (not exercised without a real
  # network failure, but proves the opt-in renders).
  def failure_surface
    component = render_to_string(FailureSurfaceComponent.new(count: 0), layout: false)
    template = <<~HTML
      <template data-reactive-error-flash>
        <div class="reactive-flash reactive-flash--error" data-testid="offline-flash">You are offline</div>
      </template>
    HTML
    render html: component + template.html_safe, layout: true
  end

  # Timeout + offline surface (issue #101). A SHORT phlex-reactive-timeout meta
  # (300ms) so the component's 1.5s `slow` action reliably aborts on the client,
  # plus a document-level probe node the reactive:error listener writes the kind
  # into — the spec reads it to prove kind=timeout / kind=offline without app JS.
  def network_status
    component = render_to_string(NetworkStatusComponent.new(count: 0), layout: false)
    extras = <<~HTML
      <meta name="phlex-reactive-timeout" content="1000">
      <div data-testid="error-probe"></div>
      <script>
        document.addEventListener("reactive:error", (e) => {
          document.querySelector("[data-testid='error-probe']").textContent = e.detail.kind
        })
      </script>
    HTML
    render html: component + extras.html_safe, layout: true
  end

  # Latency simulator dev aid (issue #102). Carries the APP-AUTHORED
  # <meta name="phlex-reactive-env" content="development"> so the client attaches
  # window.PhlexReactive (the dev gate). The spec enables the sim and asserts
  # aria-busy is visible during the injected client-side delay — finally covering
  # aria-busy in a real browser (the fast `bump` action has no server-side sleep).
  def latency
    component = render_to_string(LatencyComponent.new(count: 0), layout: false)
    extras = <<~HTML
      <meta name="phlex-reactive-env" content="development">
    HTML
    render html: component + extras.html_safe, layout: true
  end

  def todos
    render_component TodoListComponent.new
  end

  def combobox
    # Seed the query so options render on load — the system spec drives keyboard
    # nav without hammering the debounced search (which stresses Falcon's fibers).
    render_component ComboboxComponent.new(query: params[:q].to_s)
  end

  # Client-side option filtering (issue #163): the whole catalog preloads and
  # typing narrows it in-browser — the spec's fetch spy proves zero POSTs.
  def filter_combobox
    render_component FilterComboboxComponent.new
  end

  # The tag-chip input (issue #203): reactive_tags ∘ reactive_filter ∘
  # reactive_listnav, all client-side. The widget's own GET form submits back
  # HERE — params[:tags] carries the hidden field's comma-joined value, and the
  # re-render echoes it (the system spec's proof the server received it).
  def tags_field
    render_component TagsFieldComponent.new(tags: params[:tags].to_s, submitted: params.key?(:tags))
  end

  # The form-builder shape of the tag-chip input (issue #224): a VERBATIM
  # bracketed wire name (reactive_tags(name: "user[tags]")) and an id-targeted,
  # name-less query input (reactive_filter(input:)). The GET submit proves the
  # wire: user[tags] arrives comma-joined, and stray_params lists every query
  # key that isn't user[…] — the spec asserts it stays empty.
  def form_tags_field
    render_component FormTagsFieldComponent.new(
      tags: params.dig(:user, :tags).to_s,
      submitted: params.key?(:user),
      stray_params: request.query_parameters.keys - ["user"]
    )
  end

  # A NEW (unsaved) order: the split recomputes in-browser via reactive_compute,
  # no round trip. total=500 seeds the three-way split. The page also carries a
  # read-only recap OUTSIDE the reactive root (issue #159) — the component's
  # declared `mirror:` paints #summary-cash/#summary-total via textContent.
  # #summary-total deliberately seeds "—" so the spec can PROVE the identity
  # paint happened (the text must change, not coincide).
  def new_order
    component = render_to_string(OrderComponent.new(order: Order.new(total: 500)), layout: false)
    summary = <<~HTML
      <div data-testid="order-summary" style="padding: 2rem">
        Cash: <span id="summary-cash">0</span> / Total: <span id="summary-total">—</span>
      </div>
    HTML
    render html: component + summary.html_safe, layout: true
  end

  # A PERSISTED order: editing allowance fires the reactive rebalance action and
  # the server reconciles cash through the same PaymentSplit twin.
  def order
    render_component OrderComponent.new(order: Order.find(params[:id]))
  end

  # Issue #208: the draft nested-attribute rows form — a "new order + line
  # items" page building child rows client-side BEFORE the parent exists.
  def draft_order
    render_component DraftOrderFormComponent.new
  end

  # The reconcile half (issue #208): the REAL form submit posts
  # order[line_items_attributes][<index>][…] and accepts_nested_attributes_for
  # creates the order + rows in ONE request. The confirmation page carries
  # testids so the system spec can assert exactly what persisted.
  def create_order
    order = Order.create!(create_order_params)
    items = order.line_items.map do
      %(<li data-testid="created-item">#{it.quantity} × #{it.price}</li>)
    end.join
    render html: <<~HTML.html_safe, layout: true
      <div data-testid="order-created">
        <p>Order created with <span data-testid="item-count">#{order.line_items.count}</span> items</p>
        <ul>#{items}</ul>
      </div>
    HTML
  end

  # Issue #208 (JSON mode): the draft form whose list opts into `as: :json` —
  # the rows serialize into ONE hidden field the client keeps in sync.
  def draft_order_json
    render_component DraftOrderJsonFormComponent.new
  end

  # Issue #218: a JSON-mode draft list whose per-row remove gates behind
  # reactive_nested_remove(confirm:). Reconciled through the SAME /orders_json
  # endpoint, so the confirm is the only thing under test.
  def draft_order_confirm_remove
    render_component DraftOrderConfirmRemoveComponent.new
  end

  # Issue #222: the per-row remove confirm carries a %{quantity} PLACEHOLDER;
  # a row the user ADDS client-side interpolates it from its own live value at
  # click time. Reconciled through the SAME /orders_json endpoint.
  def draft_order_confirm_interpolate
    render_component DraftOrderConfirmInterpolateComponent.new
  end

  # The JSON-mode reconcile: the app parses a SERIALIZED JSON param by hand
  # (NO accepts_nested_attributes_for), the exact controller path an app that
  # already ships a JSON param keeps unchanged when adopting the primitive.
  def create_order_json
    permitted = params.require(:order).permit(:total, :line_items)
    rows = JSON.parse(permitted[:line_items].presence || "[]")
    # Only pass total when present (the fill-then-add form omits it) — else an
    # explicit nil overrides the column's NOT NULL default.
    order = Order.create!(**(permitted[:total].present? ? { total: permitted[:total] } : {}))
    rows.each { order.line_items.create!(quantity: it["quantity"], price: it["price"]) }

    items = order.line_items.map do
      %(<li data-testid="created-item">#{it.quantity} × #{it.price}</li>)
    end.join
    render html: <<~HTML.html_safe, layout: true
      <div data-testid="order-created">
        <p>Order created with <span data-testid="item-count">#{order.line_items.count}</span> items</p>
        <ul>#{items}</ul>
      </div>
    HTML
  end

  # Issue #208 Scenario A: fill-then-add — the add controls live OUTSIDE the
  # row and "Add" snapshots them into a new row. Two variants: accepts-nested
  # (reuses /orders) and JSON mode (reuses /orders_json).
  def draft_order_fill
    render_component DraftOrderFillFormComponent.new
  end

  def draft_order_fill_json
    render_component DraftOrderFillJsonFormComponent.new
  end

  # reactive_text + typed compute (issue #104): a live title preview + character
  # counter that update in-browser as you type (no round trip), then a save
  # reconciles through the server (the morph re-seeds the derived heading/counter).
  def post_preview
    render_component PostPreviewComponent.new(todo: Todo.find(params[:id]))
  end

  # Connect-time compute seed (issue #199): a freshly-rendered compute root whose
  # derived outputs + mirror are rendered BLANK, so the client MUST self-seed them
  # on connect (no user input, no round trip). The recap node OUTSIDE the root
  # seeds "—" so the spec PROVES the mirror painted (the text must change).
  def compute_seed
    component = render_to_string(ComputeSeedComponent.new(first: 2, second: 4), layout: false)
    recap = <<~HTML
      <div data-testid="seed-summary" style="padding: 2rem">
        Total: <span id="seed-total-label">—</span>
      </div>
    HTML
    render html: component + recap.html_safe, layout: true
  end

  # Checked-state compute controls (issue #262): a checkbox pair, a lone box and
  # a radio group as compute inputs AND outputs.
  def compute_checked
    render_component ComputeCheckedComponent.new
  end

  def notifications
    render_component NotificationsListComponent.new
  end

  def reactive_rows
    render_component ReactiveRowsListComponent.new
  end

  def chat
    room = params[:room].presence || "lobby"
    render_component ChatRoomComponent.new(room:, messages: ChatMessage.for_room(room).last(50))
  end

  def rich_editor
    render_component RichEditorComponent.new(todo: Todo.find(params[:id]))
  end

  def form_submit
    render_component FormSubmitComponent.new(todo: Todo.find(params[:id]))
  end

  # Dirty-field tracking (issue #103): a record-backed form whose title field is
  # dirty-tracked against its own defaultValue. Typing reveals the "Unsaved" badge
  # (pure CSS on [data-reactive-dirty]); saving morphs the field with the new value
  # as its fresh default, so the post-morph re-scan clears the badge — no reload.
  def dirty_form
    render_component DirtyFormComponent.new(todo: Todo.find(params[:id]))
  end

  def nested_editor
    render_component NestedEditorComponent.new
  end

  def nested_params
    render_component NestedParamsComponent.new
  end

  def debounce
    render_component DebounceComponent.new
  end

  # The outside-click dropdown (issue #80). The page carries content OUTSIDE the
  # reactive root — a plain area to click and a real link — so the system spec
  # can prove the outside close fires AND that the window-bound trigger never
  # preventDefaults native navigation elsewhere on the page.
  def dropdown
    component = render_to_string(DropdownMenuComponent.new, layout: false)
    outside = <<~HTML
      <div data-testid="outside-area" style="padding: 4rem">outside the menu</div>
      <a href="/nav_probe" data-testid="outside-link">elsewhere</a>
    HTML
    # render_to_string returns a SafeBuffer whose #to_s returns SELF, so a
    # `component.to_s + outside` concat ESCAPES the raw fixture into visible
    # text. Appending an html_safe right-hand side concatenates verbatim.
    render html: component + outside.html_safe, layout: true
  end

  # Pure client-side interactivity (issue #95, extended in #96): on_client + js
  # ops. The page carries an outside area so the spec can prove the outside-close
  # op, a fetch spy proves NOTHING is ever posted, and a real @keyframes fade
  # (ct-fade-to) drives the #96 transition op so animationend actually fires.
  def client_tabs
    component = render_to_string(ClientTabsComponent.new, layout: false)
    extras = <<~HTML
      <style>
        @keyframes ct-fade-in { from { opacity: 0 } to { opacity: 1 } }
        .ct-fade-to { animation: ct-fade-in 40ms ease-out }
      </style>
      <div data-testid="outside-area" style="padding: 4rem">outside the tabs</div>
      <span id="ct-status-global" data-testid="status-global">One</span>
    HTML
    render html: component + extras.html_safe, layout: true
  end

  # Issue #271: the accessible disclosure menu (on_client only). The outside area
  # lets the spec prove the window-bound outside close; ClientTabsComponent
  # carries a SECOND window-bound outside close on the same page, so one outside
  # click must close both (Stimulus shares one event across window bindings).
  def disclosure_menu
    component = render_to_string(DisclosureMenuComponent.new, layout: false)
    tabs = render_to_string(ClientTabsComponent.new, layout: false)
    outside = <<~HTML
      <div data-testid="dm-outside" style="padding: 4rem">outside the menu</div>
      <span id="ct-status-global">One</span>
    HTML
    render html: component + tabs + outside.html_safe, layout: true
  end

  # Issue #226: the $ops flagship — a one-time-code field whose reducer
  # normalizes on input and auto-commits (submit → intercepted signed action)
  # exactly once when the value first becomes complete.
  def verification
    component = render_to_string(VerificationCodeComponent.new, layout: false)
    render html: component, layout: true
  end

  # Issue #226: the multi-box code entry — one reducer joins six boxes,
  # redistributes pastes, advances focus per digit, submits on completion.
  def split_code
    component = render_to_string(SplitCodeComponent.new, layout: false)
    render html: component, layout: true
  end

  # Issue #226: the declarative completion binding — reactive_on_complete with
  # zero JavaScript (no reducer; the Ruby length: condition drives the ops).
  def code_complete
    component = render_to_string(CodeCompleteComponent.new, layout: false)
    render html: component, layout: true
  end

  # Issue #226: the general autosubmit story — a plain GET filter form whose
  # select submits it on change via on_client(:change, js.submit("form")).
  # Turbo Drive turns the requestSubmit into a visit (no full reload).
  def autosubmit_filter
    component = render_to_string(
      AutosubmitFilterComponent.new(sort: params.fetch(:sort, "name")), layout: false
    )
    render html: component, layout: true
  end

  # Value-conditional visibility (issue #161): reactive_show bindings driven by
  # a select, a checkbox, and a radio group — all client-only. The spec's fetch
  # spy proves no round trip ever fires. The badge lives OUTSIDE the component's
  # root — the #164 cross-root target the component declares by id.
  # Issue #239: reactive_persist. ?name= renders a server value the draft must
  # not overwrite; the POST redirects (a successful Turbo submit → draft cleared).
  def persist_form
    render_component PersistFormComponent.new(name: params[:name])
  end

  def persist_form_submit
    redirect_to "/persist_form?submitted=1"
  end

  # Issue #319: the bulk-selection list. The POST echoes what the form sent —
  # the submitter's bulk_action and the ticked ids — back through ?result=.
  def bulk_selection
    render_component BulkSelectionComponent.new(result: params[:result])
  end

  def bulk_selection_submit
    result = "#{params[:bulk_action].presence || "none"}:#{Array(params[:ids]).join(",")}"
    redirect_to "/bulk_selection?result=#{CGI.escape(result)}", status: :see_other
  end

  # Issue #343: a nested-root list whose boxes drive a bulk bar outside it.
  def group_targets
    render_component GroupTargetsPageComponent.new
  end

  # Issue #275: the draft code is a feature module the client imports on
  # demand. ?slow=<ms> pins that module to a delayed copy, so a spec can act
  # in the window between the controller connecting and the draft restoring;
  # ?layout=lazy uses the lazily loading layout (early.js, controller later).
  def persist_action
    @slow_feature_ms = params[:slow].to_i.clamp(0, 5000) if params[:slow].present?
    html = render_to_string(PersistActionComponent.new, layout: false)
    return render(html: html.html_safe, layout: true) unless params[:layout] == "lazy"

    @reactive_load = params[:load].presence_in(%w[auto eager]) || ""
    render html: html.html_safe, layout: "lazy_controller"
  end

  # A feature module, served after ?ms= (the layouts pin one to this route).
  def slow_feature
    name = params[:name]
    return head(:not_found) unless Phlex::Reactive::Engine::CLIENT_FEATURES.include?(name)

    sleep(params[:ms].to_i.clamp(0, 5000) / 1000.0)
    send_file Rails.public_path.join("vendor/features/#{name}.js"), type: "text/javascript", disposition: "inline"
  end

  # Issue #241: reactive_persist over rich editors. ?body= / ?notes= render
  # server values the draft must not overwrite; ?late=1 defines the editors
  # after the reactive controller connected (the whenDefined deferral).
  def persist_editors
    render_component PersistEditorsFormComponent.new(
      body: params[:body], notes: params[:notes], late: params[:late].present?
    )
  end

  def persist_editors_submit
    redirect_to "/persist_editors?submitted=1"
  end

  def conditional_fieldset
    component = render_to_string(ConditionalFieldsetComponent.new, layout: false)
    outside = <<~HTML
      <span id="cf-mode-badge" hidden data-testid="mode-badge">Shipping enabled</span>
      <aside id="cf-bulk-alert" hidden data-testid="bulk-alert">Company bulk order — approval needed</aside>
    HTML
    render html: component + outside.html_safe, layout: true
  end

  def confirm
    render_component ConfirmComponent.new
  end

  # Issue #178: confirm: on on_client. A destructive-feeling client op (clear a
  # draft) gated behind the themed confirmResolver — zero round trips. The system
  # spec overrides window.confirm to prove decline leaves the marker, accept
  # clears it, neither navigates. Declares no actions (client-op only).
  def client_op_confirm
    render html: render_to_string(ClientOpConfirmComponent.new, layout: false).html_safe, layout: true
  end

  # Issue #179: DECLARATIVE conditional confirm — the save warns only when total
  # is 0 (the reactive_show conditions language evaluated client-side).
  def conditional_confirm
    render_component ConditionalConfirmComponent.new
  end

  # Issue #179: NAMED-PREDICATE conditional confirm — the save warns only when
  # the end date precedes the start (a registered multi-field JS predicate).
  def schedule_confirm
    render_component ScheduleConfirmComponent.new
  end

  # Optimistic visual hints (issue #98): a checkbox that flips natively before
  # the (deliberately slow) morph, a failing action whose hint reverts, and a
  # hide-then-remove delete. A fresh, unfinished Todo each visit.
  def optimistic
    todo = Todo.create!(title: "optimistic", done: false)
    component = render_to_string(OptimisticRowComponent.new(todo:), layout: false)
    render html: %(<ul>#{component}</ul>).html_safe, layout: true
  end

  # Declarative loading states (issue #99): a disable_with button that disables +
  # swaps its text while a slow save runs, so a rapid double-click enqueues only
  # ONE POST (the disabled button swallows the second), plus a busy_on spinner.
  def loading_button
    render_component LoadingButtonComponent.new(count: 0)
  end

  # Deferred reply segments (issue #165): the driver component + the expensive
  # rollup on one page. Specs dial SlowTotalsComponent.render_delay_ms (same
  # process as this Capybara server) to make the pending window observable.
  def defer
    html = render_to_string(DeferDemoComponent.new(count: 0), layout: false) +
           render_to_string(SlowTotalsComponent.new(value: 0), layout: false)
    render html: html.html_safe, layout: true
  end

  # Lazy initial mount (issue #165): the page ships the placeholder shell; the
  # client fetches the real content on connect via the defer machinery.
  def lazy_stats
    render_component LazyStatsComponent.new(scope: "week")
  end

  # reactive_lazy(on:) (issue #276): an event-triggered panel at the top, and a
  # visibility-triggered shell far below the fold. Neither fetches on load.
  # reactive_lazy(on:) composed with phlex/reactive/early (issues #276 + #273):
  # the event shell on the lazily-loaded-controller layout, so its event can
  # fire before the controller connects.
  def lazy_on_early
    html = render_to_string(LazyPanelComponent.new(scope: "mine"), layout: false)
    render html: html.html_safe, layout: "lazy_controller"
  end

  # ?scope=forbidden ships a panel whose materialize is denied (403), so specs
  # can leave a shell in the failed state.
  def lazy_on
    html = render_to_string(LazyPanelComponent.new(scope: params.fetch(:scope, "mine")), layout: false) +
           %(<div data-testid="spacer" style="height: 3000px"></div>).html_safe +
           render_to_string(LazyFoldComponent.new(label: "below"), layout: false)
    render html: html.html_safe, layout: true
  end

  # reactive_lazy(cache:) (issue #277): a per-viewer menu whose real render is
  # a privately cacheable GET. The shell's URL is keyed on the viewer (the
  # `viewer` cookie, via reactive_cache_viewer), so a later page view reuses
  # the browser's copy.
  def cached_menu
    render_component CachedMenuComponent.new(scope: params.fetch(:scope, "main"))
  end

  # reactive_lazy(on:, cache:): no request on load; the first `panel:opened`
  # GETs the cacheable fragment. No declared viewer, so the reply varies on the
  # cookie.
  def cached_panel
    render_component CachedPanelComponent.new(scope: "mine")
  end

  def morph_grid
    render_component MorphGridComponent.new(account: Account.find(params[:id]))
  end

  # Issue #338: a morph save that normalises the value keeps the focused field's text.
  def morph_normalize
    render_component MorphNormalizeComponent.new
  end

  # Issue #97: post-save focus lands on the freshly morphed field via
  # reply.morph.js(js.focus(...)) — the reactive:js op stream rides AFTER the
  # morph so focus targets the morphed node.
  def js_focus
    render_component JsFocusComponent.new(account: Account.find(params[:id]))
  end

  def partial_grid
    render_component PartialGridComponent.new(line_item: LineItem.find(params[:id]))
  end

  def checkbox_group
    render_component CheckboxGroupComponent.new
  end

  # Issue #337: a reactive_scope component saved by a real browser, whose
  # default JSON body keeps the field's bracketed name ("todo[title]").
  def scoped_editor
    render_component ScopedEditorComponent.new(todo: Todo.find(params[:id]))
  end

  def document_upload
    render_component DocumentUploadComponent.new(document: Document.find(params[:id]))
  end

  # The page a non-intercepted form submit would navigate to (issue #11).
  def nav_probe
    render html: "<div data-testid='nav-probe'>NAVIGATED</div>".html_safe, layout: true
  end

  # Issue #320: answer only after ?seconds= (capped, no DB) so the timeout
  # proof sees a server that "never" answers without wedging it for later specs.
  def stall
    sleep(params[:seconds].to_i.clamp(0, 15))
    render plain: "stalled"
  end

  private

  # Render a Phlex component as the layout's body. `render component, layout:`
  # is phlex-rails; we capture it into the ERB layout via a content block.
  def render_component(component)
    html = render_to_string(component, layout: false)
    render html: html.html_safe, layout: true
  end

  # Issue #208: the nested-attributes permit — the standard Rails shape for a
  # parent + indexed child rows (id/_destroy cover the edit-form flow too).
  def create_order_params
    params.require(:order).permit(:total, line_items_attributes: %i[id quantity price _destroy])
  end
end
