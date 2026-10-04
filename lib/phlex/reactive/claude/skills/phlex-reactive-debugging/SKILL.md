---
name: phlex-reactive-debugging
description: "Debug phlex-reactive in a Rails app: a reactive component that doesn't update, a 400/403/404 from POST /reactive/actions, an AuthorizationNotVerified error, or an audit of which reactive actions authorize. Use when a reactive click does nothing, a Turbo Stream never arrives, or you need to inventory the reactive components/actions in the app."
---

# Debugging phlex-reactive

phlex-reactive turns every reactive component into a browser-reachable RPC:
`POST /reactive/actions` with a signed identity token → verify → rebuild the
component → run the declared action → render an auto-targeted Turbo Stream. When
something "just doesn't work," the failure is almost always at one of those
seams. This skill is the runbook.

Work top-down: **validate the install → inventory the server → find the specific
component → scan the live page → introspect the running app.** Stop as soon as a
step names the problem.

## 1. Validate the install (`doctor`)

```bash
bin/rails phlex_reactive:doctor
```

Prints ✓/✗/? for the whole install: does `POST /reactive/actions` route to the
gem (a host catch-all route shadows it otherwise), is the generic `reactive`
Stimulus controller registered, does the identity verifier round-trip, does every
declared `action :name` have a public method, does every component resolve a
stable `#id`, and an **advisory** authorization heuristic. A ✗ prints the fix.
Run this FIRST — most "nothing happens" reports are a red ✗ here.

## 2. Inventory the server (`actions` / `find`)

```bash
bin/rails phlex_reactive:actions            # every component × action: params, file:line, auth
bin/rails phlex_reactive:actions FORMAT=json
bin/rails phlex_reactive:actions UNVERIFIED=1   # only the unverified rows (the review queue)
bin/rails "phlex_reactive:find[counter]"    # fuzzy-find one; prints each action's method source
```

Answers "what reactive actions exist, where are they defined, and is each
authorized?" without grepping. The `auth` column is a heuristic: `authorized*` =
an authorization call was detected in the body; `skipped` / `skipped (class)` =
the author opted out with `skip_verify_authorized` (for that action / for the
whole class); `unverified` = neither — a helper may still authorize indirectly.

## 3. Scan the live page (browser inspector)

In the browser console on the affected page:

```js
(await import("phlex/reactive/inspect")).report()
```

`report()` prints a `console.table` of every reactive root on the page — its
`id`, decoded token payload (**component class**, gid, state keys), status
(error/busy/dirty), the bound **triggers** (action + event + params +
debounce/confirm), client-only ops, computes, and the named fields a dispatch
would send. `scan()` returns the same data.

**The server↔client mapping is by name.** The `component` and each trigger's
`action` in `report()` are exactly the identifiers `phlex_reactive:actions`
lists. So: does the button on the page carry the action you expect? Does its
`component` match the class you think renders here? A mismatch (or a root with an
`(opaque token)`) localizes the bug.

## 4. Introspect the running app (MCP server)

For live-app introspection from inside your editor, run the read-only MCP server
(needs the optional `mcp` gem — `gem "mcp"`):

```json
// .mcp.json
{ "mcpServers": { "phlex-reactive": { "command": "bin/rails", "args": ["phlex_reactive:mcp"] } } }
```

It exposes five read-only tools — `phlex_reactive_doctor`,
`phlex_reactive_components`, `phlex_reactive_actions` (optional `component:`
filter), `phlex_reactive_find`, `phlex_reactive_config` — the same data as the
rake tasks, queryable in conversation. Constraint: stdio MCP needs a clean
stdout, so an initializer that `puts` breaks it.

`rails g phlex:reactive:claude` installs this skill and writes the `.mcp.json`
entry for you.

## Failure table

| Symptom | Cause | Fix |
|---------|-------|-----|
| **400** (bad request) | Tampered / stale token — a token from before a deploy, a `secret_key_base` mismatch, or a `reply.with(...)` stream that skipped the token refresh | Reload the page for a fresh token; confirm `secret_key_base`; ensure custom streams refresh the token |
| **403** (forbidden) | The action isn't declared (`action :name`), OR your authorizer raised and is registered in `Phlex::Reactive.authorization_errors` | Declare the action; or the 403 is correct — the user isn't allowed |
| **`AuthorizationNotVerified`** (500) | `verify_authorized` is ON and the action completed without calling an authorization method or `mark_authorized!` | Call your authorization method inside the action, call `mark_authorized!` after a bespoke check, or declare `skip_verify_authorized` if it's genuinely public |
| **404** (not found) | The record was deleted while a page still showed it (record-backed component) | Expected for a stale page; handle by removing the row or reloading |
| **Nothing happens on click** | The `reactive` controller isn't registered, or a host catch-all route shadows `POST /reactive/actions` | `bin/rails phlex_reactive:doctor` names both — fix the ✗ |
| **`importmap` 404 for the client** | The engine's pin was overridden | Re-add `pin "phlex/reactive/reactive_controller"`; doctor flags it |
| **Component renders but never updates** | The root's `id` and `data-controller="reactive"` landed on DIFFERENT elements | Spread `**reactive_root` (binds id + controller + token to the same element) instead of `**reactive_attrs` on a child |

## Reference vs live introspection

- **Reference docs** (how a feature works, the API): the hosted docs MCP at
  <https://phlex-reactive.zoolutions.llc/llms.txt> — search/read the published
  guide.
- **Live-app introspection** (what's in THIS app right now): the local
  `phlex_reactive:mcp` server + the rake tasks + the browser `report()`.

For transport-level problems (a broadcast never arrives over pgbus / Action
Cable), reach for pgbus's own tooling (`pgbus doctor`, its MCP) — phlex-reactive
is transport-agnostic and doesn't diagnose the wire.
