---
model: opus
description: Review a GitHub pull request for code quality, patterns, and best practices
argument-hint: "PR URL or number (e.g., 5 or https://github.com/mhenrixon/phlex-reactive/pull/5)"
---

# PR Review

Review a PR for pattern compliance and issues. Be concise.

## Workflow

1. Fetch PR details and diff via `mcp__github__pull_request_read`
2. Categorize files by layer (core/config, streamable, component, controller, client, dummy, docs)
3. Check for pattern violations
4. Output a structured review

## Pattern Violations to Check

```text
# WRONG -> RIGHT
Hand-picked Turbo target              -> Component self-targets via #id
Shipping state to the client          -> Sign identity ({c, gid}); re-find server-side
Signature treated as authorization    -> authorize! inside the action
Undeclared action / raw params        -> action :name, params: {...} (default-deny)
@record.update!(params)               -> Explicit declared params
Fabricated view context for render    -> Render through Phlex::Reactive.renderer
dom_id (Phlex helper) inside #id      -> Streamable#dom_id (render-context-free)
**on(:x), data: {...} (clobbers)      -> mix(on(:x), data: {...})
Assume pgbus / call pgbus keyword raw -> Capability gate (pgbus_streams?) + fallback
Listen for pgbus events on document   -> They don't bubble — listen on the element
Secret in reactive_state              -> reactive_record + server-side read
Manual gem push                       -> bin/release
```

## Output Format

```
## Files Requiring Manual Review

| File | Reason |
|------|--------|
| lib/phlex/reactive/streamable.rb | Broadcast seam — verify pgbus gate + fallback |
| app/controllers/phlex/reactive/actions_controller.rb | Endpoint — verify authz + param coercion |
| app/javascript/phlex/reactive/reactive_controller.js | Client — verify request queue + token threading |

## Critical Issues

- `app/controllers/.../actions_controller.rb:NN` - Action lacks authorize!
- `lib/phlex/reactive/streamable.rb:NN` - pgbus keyword called without the gate

## Suggestions (non-blocking)

- Consider extracting X

## Verdict

**Request Changes** | **Approve** | **Comment** — one-line justification
```

## Tools

```text
mcp__github__pull_request_read
  method: "get"        -> PR details
  method: "get_diff"   -> Changes
  method: "get_files"  -> File list
  method: "get_status" -> CI status

bundle exec rubocop      -> Style checks
bundle exec rspec        -> Tests
```
