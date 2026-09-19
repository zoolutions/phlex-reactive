# `.claude/` — commands, agents, and rules for phlex-reactive

This directory configures how Claude Code works in this repo. It is checked in so
the whole team (and every autonomous session) shares the same conventions.

```
.claude/
├── commands/   Slash commands (/lfg, /tdd, /plan, /security, …) — one markdown file each
├── rules/      Standing rules auto-loaded into context (coding-style, testing, performance, git-workflow, agents)
├── README.md   This file — how to author a command
└── SKILL_TEMPLATE.md   Copy-paste starting point for a new command
```

## Anatomy of a command

A command is a markdown file under `commands/` with a YAML frontmatter block
followed by the prompt body. `.claude/commands/tdd.md` is a good reference.

```markdown
---
model: sonnet
description: "What it does. Use when {trigger phrases, contexts, file types}."
argument-hint: "example input the user might provide"
allowed-tools: Bash(gh pr view:*), Read, Write, Edit, Glob, Grep, Agent
---

# Command Title

The prompt body — instructions Claude follows when the command runs.
```

### Frontmatter fields

| Field | Purpose |
|-------|---------|
| `model` | Model **tier alias** — see the convention below. Use an alias, never a full model ID, so the command tracks the latest model in its tier. |
| `description` | One line. Leads with action verbs and the trigger context; this is what surfaces the command in the skill list. |
| `argument-hint` | Example of the input the user passes as `$ARGUMENTS`. Omit for zero-argument commands. |
| `allowed-tools` | Optional allowlist that narrows what the command may call (e.g. scoping `Bash` to specific `gh`/`git`/`bundle exec` invocations). Omit to inherit the session's tools. |

## The model tier convention

Pin a model **tier** by the work the command does, not the model you happen to be
running. Tier aliases (`haiku`, `sonnet`, `opus`, `fable`) always resolve to the
latest model in that tier, so a command never goes stale on an outdated pin.

| Tier | Use for | Commands here |
|------|---------|---------------|
| `haiku` | Mechanical / config work, diff pattern-scanning | *(none yet)* |
| `sonnet` | Prescriptive, pattern-following passes with a tight prompt | `/github-review-comments`, `/github-review-failures` |
| `opus` | Orchestration, security, review synthesis, and reasoning-heavy specialists | `/lfg`, `/architect`, `/security`, `/review-pr`, `/github-review-pr`, `/tdd`, `/perf` |
| `fable` | Read-only planning that hands execution to cheaper models | `/plan` |

Rules of thumb:

- **Always use the alias**, never `claude-opus-4-8` or another full model ID —
  aliases track the latest model per tier and never rot.
- **`fable` is pinned only on `/plan`.** For a plain interactive session, pick it
  per-session with `/model` when you want the most capable model for architecture
  or the hardest debugging.
- **Subagents don't inherit the tier for free.** When a command (or you) spawns a
  subagent for mechanical work — file finding, naming-convention sweeps, pattern
  scans — pass a cheaper `model:` explicitly. Left unset, a subagent inherits the
  session model, so the most mechanical work runs at the highest price.

The convention is also recorded in the repo `AGENTS.md` ("Slash Commands") so it
survives across sessions.

## Authoring a new command

1. Copy `SKILL_TEMPLATE.md` into `commands/{name}.md`.
2. Pick the tier by the table above.
3. Write a `description` that leads with what it does and when to use it.
4. Scope `allowed-tools` if the command should be constrained (review/CI commands
   usually are; open implementation commands usually are not).
5. Add a row to the "Slash Commands" table in `AGENTS.md`.
