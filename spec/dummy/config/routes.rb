# frozen_string_literal: true

Rails.application.routes.draw do
  mount Turbo::Engine => "/turbo" if defined?(Turbo::Engine)

  # Issue #187: under TRANSPORT=pgbus the dummy mounts pgbus so its SSE stream
  # endpoint (/pgbus/streams) is live and turbo_stream_from routes over it.
  mount Pgbus::Engine => "/pgbus" if ENV["TRANSPORT"] == "pgbus" && defined?(Pgbus::Engine)

  # Example pages exercised by system specs.
  get "counter" => "demos#counter"
  get "effects" => "demos#effects"
  get "debug" => "demos#debug"
  get "failure_surface" => "demos#failure_surface"
  get "network_status" => "demos#network_status"
  get "latency" => "demos#latency"
  get "chat" => "demos#chat"
  get "todos" => "demos#todos"
  get "combobox" => "demos#combobox"
  get "filter_combobox" => "demos#filter_combobox"
  get "tags_field" => "demos#tags_field"
  # Issue #224: the form-builder shape — verbatim name: + id-targeted input:.
  get "form_tags_field" => "demos#form_tags_field"
  get "new_order" => "demos#new_order"
  get "order/:id" => "demos#order"
  # Issue #208: the draft nested-attribute rows form + its reconcile endpoint.
  get "draft_order" => "demos#draft_order"
  post "orders" => "demos#create_order"
  # Issue #208 (JSON mode): the same form, list `as: :json`, reconciled through
  # a hand-rolled JSON.parse controller path (no accepts_nested_attributes_for).
  get "draft_order_json" => "demos#draft_order_json"
  post "orders_json" => "demos#create_order_json"
  # Issue #208 Scenario A: fill-then-add (add controls OUTSIDE the row) — both
  # wire modes, reconciled through the SAME /orders and /orders_json endpoints.
  get "draft_order_fill" => "demos#draft_order_fill"
  get "draft_order_fill_json" => "demos#draft_order_fill_json"
  # Issue #218: a JSON-mode draft list whose per-row remove confirms first —
  # reconciled through the SAME /orders_json endpoint.
  get "draft_order_confirm_remove" => "demos#draft_order_confirm_remove"
  # Issue #222: the per-row remove confirm carries a %{field} PLACEHOLDER; a
  # client-added row interpolates it from its own live field value on remove.
  get "draft_order_confirm_interpolate" => "demos#draft_order_confirm_interpolate"
  get "post_preview/:id" => "demos#post_preview"
  get "compute_seed" => "demos#compute_seed"
  get "compute_checked" => "demos#compute_checked"
  # Issue #226: the $ops flagship — normalize on input, auto-commit when complete.
  get "verification" => "demos#verification"
  # Issue #226: the multi-box variant — paste redistribution + focus advance.
  get "split_code" => "demos#split_code"
  # Issue #226: the declarative twin — reactive_on_complete, zero JavaScript.
  get "code_complete" => "demos#code_complete"
  get "notifications" => "demos#notifications"
  get "reactive_rows" => "demos#reactive_rows"
  get "rich_editor/:id" => "demos#rich_editor"
  get "form_submit/:id" => "demos#form_submit"
  get "dirty_form/:id" => "demos#dirty_form"
  get "nested_editor" => "demos#nested_editor"
  get "nested_params" => "demos#nested_params"
  get "debounce" => "demos#debounce"
  get "dropdown" => "demos#dropdown"
  get "client_tabs" => "demos#client_tabs"
  # Issue #226: the general autosubmit story — on_client(:change, js.submit).
  get "autosubmit_filter" => "demos#autosubmit_filter"
  get "conditional_fieldset" => "demos#conditional_fieldset"
  # Issue #239: reactive_persist — client-only localStorage drafts; the POST
  # redirects so a successful turbo:submit-end clears the draft.
  get "persist_form" => "demos#persist_form"
  post "persist_form" => "demos#persist_form_submit"
  # Issue #241: reactive_persist over rich editors (real Trix + Lexxy + a bare
  # contenteditable); ?late=1 defers the editor definitions past connect.
  get "persist_editors" => "demos#persist_editors"
  post "persist_editors" => "demos#persist_editors_submit"
  get "confirm" => "demos#confirm"
  get "client_op_confirm" => "demos#client_op_confirm"
  get "conditional_confirm" => "demos#conditional_confirm"
  get "schedule_confirm" => "demos#schedule_confirm"
  get "optimistic" => "demos#optimistic"
  get "loading_button" => "demos#loading_button"
  get "defer" => "demos#defer"
  get "lazy_stats" => "demos#lazy_stats"
  get "morph_grid/:id" => "demos#morph_grid"
  get "js_focus/:id" => "demos#js_focus"
  get "partial_grid/:id" => "demos#partial_grid"
  get "checkbox_group" => "demos#checkbox_group"
  get "document_upload/:id" => "demos#document_upload"
  # Nav probe: where a NON-intercepted form submit would land. Accept POST (and
  # GET) so a native submit produces an observable navigation, not a 404.
  match "nav_probe" => "demos#nav_probe", :via => %i[get post]

  # The phlex-reactive engine appends POST /reactive/actions itself.
end
