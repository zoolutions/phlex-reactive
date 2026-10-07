# frozen_string_literal: true

# Micro-bench: server-side param coercion. Since issue #109 the coerce family
# lives in Phlex::Reactive::ParamSchema, COMPILED ONCE at declaration and run per
# request (the controller's coerce_params is now a thin logging wrapper around
# schema.coerce). This isolates the per-request work — coercing a realistic
# nested payload (a Rails Form(model:) with an array of nested attributes)
# against a pre-compiled schema — so allocation/throughput regressions in the
# recursion + bracket expansion show up. Baselined pre-#109 at ~35.5k i/s /
# 207 obj/call / 0 retained; the extraction must hold within noise.
#
#   ruby benchmark/micro/coerce_params.rb

require_relative "../support/boot"

# Measure the PRODUCTION path: verbose_errors defaults ON under RAILS_ENV=test
# (Rails.env.local?), which would add the dropped-param collector to every
# call. Production defaults OFF — the nil collector is the zero-cost path.
Phlex::Reactive.verbose_errors = false

# Compiled ONCE at declaration, exactly as Component.action does. The per-request
# hot path is #coerce, not .compile — so compile outside the measured block.
schema = Phlex::Reactive::ParamSchema.compile(
  date: :string,
  bank_account_ids: [:integer],
  invoice_items_attributes: [{ id: :integer, quantity: :float, price: :float, _destroy: :boolean }]
)

# A flat, bracketed payload (what the client's #collectFields posts for a
# Rails-style nested form) as an ActionController::Parameters, the real input.
raw = ActionController::Parameters.new(
  "date" => "2026-01-02",
  "bank_account_ids[]" => %w[1 2 3],
  "invoice_items_attributes[0][id]" => "10",
  "invoice_items_attributes[0][quantity]" => "2.5",
  "invoice_items_attributes[0][price]" => "9.99",
  "invoice_items_attributes[0][_destroy]" => "false",
  "invoice_items_attributes[1][id]" => "11",
  "invoice_items_attributes[1][quantity]" => "1.0",
  "invoice_items_attributes[1][price]" => "4.50",
  "invoice_items_attributes[1][_destroy]" => "true"
)

# The production per-request call: coerce the raw params (nil collector).
run = -> { schema.coerce(raw, nil) }

BenchSupport.header("coerce_params: nested array-of-hash (Rails bracket form)")
BenchSupport.ips { it.report("coerce_params") { run.call } }

BenchSupport.header("coerce_params allocations (per call)")
BenchSupport.allocations("coerce_params") { run.call }

# Issue #337: a `reactive_scope` component. The client's default JSON body keeps
# each field's bracketed name as ONE literal key ("todo[title]"); the endpoint
# peels the scope (ActionsController#unwrap_scope) and then coerces against the
# FLAT schema. Measured through the controller's own unwrap + coerce, so the
# scoped path's whole per-request cost shows up. The unscoped bench above never
# reaches the peel (unwrap_scope returns early without a scope).
scoped_schema = ScopedEditorComponent.reactive_actions.fetch(:save_tags).schema
controller = Phlex::Reactive::ActionsController.new
scoped_json = ActionController::Parameters.new(
  "todo[title]" => "Buy milk",
  "todo[tags][]" => %w[ruby rails]
)
scoped_nested = ActionController::Parameters.new(
  "todo" => { "title" => "Buy milk", "tags" => %w[ruby rails] }
)
scoped = -> { scoped_schema.coerce(controller.send(:unwrap_scope, it, ScopedEditorComponent), nil) }

BenchSupport.header("coerce_params: reactive_scope (JSON bracketed keys vs nested/multipart)")
BenchSupport.ips do
  it.report("scoped JSON \"todo[title]\"") { scoped.call(scoped_json) }
  it.report("scoped nested todo: {...}") { scoped.call(scoped_nested) }
end

BenchSupport.header("coerce_params: reactive_scope allocations (per call)")
BenchSupport.allocations("scoped JSON \"todo[title]\"") { scoped.call(scoped_json) }
BenchSupport.allocations("scoped nested todo: {...}") { scoped.call(scoped_nested) }
