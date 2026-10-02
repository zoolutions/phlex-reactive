---
model: opus
description: "Executes full autonomous engineering workflow with verification. Use when implementing complete features, tackling GitHub issues, or running end-to-end development cycles."
argument-hint: "GitHub issue number/URL or feature description"
allowed-tools: Bash(gh issue view:*), Bash(gh search:*), Bash(gh issue list:*), Bash(gh pr create:*), Bash(gh pr edit:*), Bash(gh pr view:*), Bash(bin/labels infer:*), Bash(bin/labels sync), Bash(bin/labels sync --dry-run), Bash(bundle exec:*), Bash(git:*), Read, Write, Edit, Glob, Grep, Agent
---

# LFG - Full Autonomous Workflow

Execute a complete engineering workflow with verification at each phase.

## Phase 0: Branch Setup

**BEFORE any other work, prepare the git branch:**

1. Check the current branch: `git branch --show-current`
2. If NOT on `main`, switch: `git checkout main`
3. Pull latest: `git pull origin main`
4. Create feature branch: `git checkout -b issue-{number}-{brief-description}` (or `feature/{description}` if no issue number)

---

## Phase 1: Understand

### Step 1: Gather Requirements

If `$ARGUMENTS` is a GitHub issue number or URL:

```bash
gh issue view <number> --json title,body,labels,assignees,comments
```

If `$ARGUMENTS` is a description, use it directly.

**Keep the issue's `type` and `area` labels** — Phase 7 puts them on the pull request. `/lfg` never edits the issue's own labels; the issue's lifecycle is the user's to manage. A `docs/plans/*.md` plan carries them on its `Labels:` line. If either group is missing, or you were given a description, pin the `type` now (one, per `.github/LABELS.md`); the areas come from the actual changed paths when the PR is opened, via `bin/labels infer`.

### Step 2: Define Acceptance Criteria

**MANDATORY:** Write explicit acceptance criteria:

- **GIVEN** [context/setup]
- **WHEN** [action taken]
- **THEN** [expected outcome]

You MUST NOT proceed until you can articulate these clearly.

### Step 3: Comprehension Gate

Before proceeding, you must:

1. State the problem/feature in one sentence
2. Explain WHY this is needed (the user-facing payoff — "a pleasure to work with")
3. List what changes from the developer's perspective (the API delta)
4. Identify edge cases not explicitly mentioned
5. Explain the data flow: client event → endpoint → action → re-render → DOM, and/or the broadcast path

If you cannot complete ALL five items, investigate further.

### Step 4: Create Task List

Create a TaskCreate todo list with specific implementation steps.

---

## Phase 2: Explore

1. Find related files (Glob/Grep or Explore agent, `model: haiku`)
2. Read existing patterns in similar features
3. Understand integration points across the layers
4. Check existing test coverage in `spec/`
5. Review the Streamable mixin in `lib/phlex/reactive/streamable.rb`
6. Review the Component mixin in `lib/phlex/reactive/component.rb`
7. Review the action endpoint in `app/controllers/phlex/reactive/actions_controller.rb`
8. Review the client runtime in `app/javascript/phlex/reactive/reactive_controller.js`
9. If a pgbus primitive is involved, **verify its real signature** in `~/Code/mhenrixon/pgbus` — do not assume the wire format

---

## Phase 3: Plan

1. List files to modify with specific changes
2. List new files to create with purpose
3. Identify the pgbus-present vs pgbus-absent behavior (the optionality invariant)
4. Plan test coverage across layers (TDD: tests FIRST) — unit, request, broadcast, system
5. Update the task list
6. Consider backwards compatibility (existing components must keep working verbatim)

---

## Phase 4: Implement (TDD)

### The deviation log (keep it from the first edit)

The plan is the map; the codebase is the territory. The moment reality forces a choice the plan or issue didn't settle, log it in `implementation-notes.md` at the repo root — one line, at the moment it happens, not reconstructed later:

- **Deviations** — the plan said X, you did Y, because Z
- **Discoveries** — facts about the codebase the plan didn't know
- **Judgment calls** — choices the user might have made differently (defaults, naming, scope cuts)

Pick the conservative option and keep going. The log is how the user audits your judgment afterwards. Never commit the file: its contents move into the PR body (Phase 7), then the file is deleted.

For each logical unit:

### 4.1: Write Failing Test First

```bash
bundle exec rspec <spec_file>
```

### 4.2: Implement Minimum Code

Write the MINIMUM code to make the test pass. Follow project patterns:

| Never Do | Always Do |
|----------|-----------|
| Hand-pick a Turbo target | Component self-targets via `#id` |
| Ship state to the client | Sign identity (`{c, gid}`); re-find server-side |
| Trust client input for authz | `authorize!` inside the action |
| Undeclared / raw-param actions | `action :name, params: {...}` (default-deny) |
| Fabricate a view context | Render through `Phlex::Reactive.renderer` |
| Assume pgbus / call a pgbus keyword blind | Capability-gate (`pgbus_streams?`) + fallback |
| `dom_id` (Phlex helper) in `#id` | `Streamable#dom_id` (render-context-free) |

### 4.3: Refactor

Once green, refactor while keeping tests passing.

### 4.4: Validate

```bash
bundle exec rubocop
```

### 4.5: Repeat

Move to the next unit. Mark task items complete.

---

## Phase 5: Deep Root Cause Analysis (Bug Fixes Only)

**If this is a bug fix, investigate before implementing.**

### Trace the lifecycle

For the failing interaction:
- Where did the client event originate? What token did it carry?
- Did the action re-render, or did a broadcast deliver it? Both?
- What ASSUMPTIONS does the code make at the failure point? Which was violated, and WHY?

### Use git history

```bash
git log --oneline -20 <file>
git blame <file>
```

### Map all callers

Use Grep to find every call site. Does the bug happen only on the pgbus path? Only on Action Cable? Only for the actor (echo)? Only on the first action (connection-id race)?

### Five Whys

Keep asking WHY until you reach the real fix point.

### Fix-location principle

The best fix is usually NOT where the error surfaced:
- Double-applied broadcast → suppress the actor echo / dedup by id, not a `rescue`
- `ArgumentError: unknown keyword :exclude` → the capability gate, not a `begin/rescue`
- Stale token under rapid clicks → the request queue + token threading, not a debounce
- `HelpersCalledBeforeRenderError` in `#id` → use `Streamable#dom_id`, not a `rescue`

### Unacceptable superficial fixes — DO NOT DO THESE

- `rescue nil` / bare `rescue` to silence an error you don't understand
- `&.` to paper over a nil without finding why it's nil
- `return if x.nil?` to silently skip
- swallowing errors instead of logging + fixing the cause

**These HIDE bugs. Find the EARLIEST point you could prevent the error and fix there.**

---

## Phase 6: Verify

**ALL of these must pass before committing:**

```bash
bundle exec rubocop
bundle exec rspec spec/phlex spec/requests
# client-touching changes: also run the browser suite
bundle exec rspec spec/system    # Puma (default); CAPYBARA_SERVER=falcon for the async server
bundle exec rake spec:system_servers  # client-touching changes: run BOTH real servers (puma + falcon)
```

### Solution verification

- "If I were the requester, is this fully resolved?"
- "Did I fix the ROOT CAUSE, not the symptom?"
- "Do the tests prove it, including the pgbus-absent fallback?"
- "Does every existing component still work verbatim (backwards compatible)?"

---

## Phase 6.5: Fable validation

Spawn the `fable-validator` agent (it is pinned to Fable) with the issue, the acceptance criteria from Phase 1 and the base branch. On **BLOCK**, fix every blocker (back to Phase 4 for code, with a failing test first), re-verify, and run the validator again. On **PASS WITH NOTES**, fix the risks you agree with and list the rest in the pull request under "Accepted risks". Put the validator's one-line verdict and its "Not verified" list in the pull request body. Do not open the pull request before a PASS or PASS WITH NOTES.

---

## Phase 7: Commit & PR

### Commit

```bash
git add <specific_files>
git commit -m "$(cat <<'EOF'
feat(scope): brief description

## Summary
[What changed and why]

## Test Coverage
- spec 1: validates X
- spec 2: validates the pgbus-absent fallback

## Verification
- [x] bundle exec rubocop passes
- [x] bundle exec rspec passes
EOF
)"
```

### Push & PR

```bash
git push -u origin $(git branch --show-current)

gh pr create --title "feat(scope): brief description" --label <type> --label <area> [--label <area>…] --body-file /tmp/pr-body.md
```

**Label the PR — every time.** The `--label` flags are the issue's `type` + `area` labels from Phase 1, never a `status` label (`plan`, `epic`, …). For a description-only run, infer them: one `type` (`.github/LABELS.md` maps conventional-commit prefixes to types) plus `bin/labels infer $(git diff --name-only origin/main...HEAD)`. Exactly one type, at least one area: when `infer` prints nothing (changes confined to unmapped paths such as specs, the README or the Gemfile), pick the closest area by hand — never zero. `gh pr create` fails on a label that doesn't exist on GitHub: run `bin/labels sync` first, then re-run the create (`gh pr edit <n> --add-label …` labels a PR that is already open, once the labels exist).

Write the PR body to a temp file (`--body-file`) to avoid shell-interpolation of
backticks/tables. The body is copied verbatim — if you would not type a
backslash in a GitHub comment, do not type one in the heredoc.

The PR body MUST end with a `## Deviations & judgment calls` section copied from
`implementation-notes.md` (then delete the file). If the plan held completely,
write "None — the plan held." This section is read FIRST in review — it is the
audit trail for every decision the plan didn't make.

---

## Phase 8: Comprehension Close-Out

The tests prove the CODE is right; this phase keeps the USER's mental model right. After the PR is up, end your final message with:

1. **The decisions, not the diff** — the 3–5 non-obvious choices in this change someone must understand to maintain it. Lead with anything from the deviation log; the user has never seen those.
2. **Three merge-gate questions** the user should be able to answer before merging (e.g. "why does the verify run inside the transaction?"). If any answer isn't obvious to them, offer a walkthrough — an unanswerable question is comprehension debt, and merging anyway is how it compounds.

---

## Verification Checklist

- [ ] All acceptance criteria met
- [ ] Tests written BEFORE implementation
- [ ] `bundle exec rubocop` passes
- [ ] `bundle exec rspec` passes (browser suite too, if the client changed)
- [ ] Backwards compatible — existing components unchanged
- [ ] pgbus optionality preserved (works with pgbus AND on Action Cable)
- [ ] `fable-validator` returned PASS or PASS WITH NOTES (verdict and "Not verified" list in the PR body)
- [ ] PR created with summary + test plan
- [ ] PR labelled: one `type` + at least one `area`, no `status` (`.github/LABELS.md`)
- [ ] PR body ends with `## Deviations & judgment calls` (from implementation-notes.md, since deleted)
- [ ] Comprehension close-out delivered (decisions + three merge-gate questions)

Now, execute this workflow for the provided issue or feature.
