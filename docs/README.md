# phlex-reactive — interactive demo site

A Rails app that **dogfoods** [phlex-reactive](https://github.com/zoolutions/phlex-reactive):
every demo is a real reactive component running live, with its source shown
alongside. It depends on the gem from the repo root (`gem "phlex-reactive", path: ".."`),
so the site always exercises the working tree.

> This is a separate application from the published Jekyll docs in `../docs`.
> The Jekyll site keeps publishing to GitHub Pages until this app is live; only
> then does the cutover happen.

## What's here (PR #1)

- **`SearchableComboboxComponent`** — the headline demo (issue #51): a debounced,
  state-backed combobox that filters an in-memory list with **zero custom
  JavaScript**. Typing filters via a reactive round trip; focus and caret survive
  the morph; clicking an option reports the selection back.
- A **3-tab demo panel** per example: **Demo** (live), **Call-site** (how to mount
  it), **Component** (the component's own source).
- A landing page + a per-demo route (`/demos/:slug`).

Counter / Todos / Chat demos and the ported reference docs land in PR #2.

## Running locally

```bash
cd site
bundle install
bun install && bunx playwright install chromium   # browser suite
bin/rails server                                   # http://localhost:3000
```

## Presence demo (production)

The Presence guide's live demo and the Project board's viewers strip need
pgbus's `pgbus_presence_members` table, created on deploy by the
`AddPhlexReactiveDocsPresence` migration (Postgres only). On a **fresh**
Postgres, `db:prepare` loads the SQLite-dumped `schema.rb` (no presence table)
and marks that migration as run, so run `rails g pgbus:add_presence` and
migrate, or the demo stays hidden.

## Tests

```bash
bundle exec rspec spec/requests spec/system          # under Puma (default)
CAPYBARA_SERVER=falcon bundle exec rspec spec/system # under Falcon (async)
bundle exec rubocop
```

The reactive round trip is proven under **both** real servers — Puma (sync) and
Falcon (async) — exactly as the gem's own suite requires.

## AI & tooling surfaces (docs-kit)

Every reference page is machine-readable, not just human-readable — the docs-kit
chrome exposes the whole site to agents with no extra authoring:

- **`/llms.txt`** + **`/llms-full.txt`** — the [llmstxt.org](https://llmstxt.org)
  index and the full concatenation, built from each page's Markdown twin.
- **`<page>.md`** — every doc page has a Markdown twin (e.g.
  `/docs/architecture.md`), derived from its own render so it can't drift. The
  masthead **"Markdown"** action copies the page to the clipboard for pasting
  into an LLM.
- **`/docs/search`** — full-text search over the same twins, no external service.
- **`/mcp`** — a read-only, stateless [MCP](https://modelcontextprotocol.io)
  server exposing `list_pages`, `get_page`, and `search_docs` over the live
  registry. Add it to an agent:

  ```bash
  claude mcp add --transport http docs https://phlex-reactive.zoolutions.llc/mcp
  ```

  It needs `gem "mcp"` (bundled here) and the `/mcp` route (drawn in
  `config/routes.rb`); `c.mcp` defaults to on. The public AI endpoints
  (`/mcp`, `/llms*`, `/docs/search`) are rate-limited per IP by Rack::Attack
  (`config/initializers/rack_attack.rb`).

## How it dogfoods the gem

The phlex-reactive engine auto-mounts `POST /reactive/actions` and auto-pins the
client controller for importmap apps. The only manual wiring is registering the
controller eagerly in `app/javascript/controllers/index.js`. Reactive demo
components live at the top level in `app/reactive_components/` (no `Components::`
prefix) so their class names match what a reader would write — the signed
identity token carries the class name verbatim.
