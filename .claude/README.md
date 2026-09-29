# `.claude/` — commands, agents, and rules for phlex-reactive

This directory configures how Claude Code works in this repo. It is checked in so
the whole team (and every autonomous session) shares the same conventions.

```
.claude/
├── agents/     Subagents with a pinned model (fable-validator)
├── commands/   Slash commands (/lfg, /tdd, /plan, /security, …) — one markdown file each
├── rules/      Standing rules auto-loaded into context (coding-style, testing, performance, git-workflow, agents)
├── settings.json   Session model (opus), advisor (fable), subagent default (sonnet)
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

Sessions run on `opus` (Opus 5.5) with `fable` (Fable 5.1) as the advisor
(`.claude/settings.json`). Fable is spent where judgment matters most: `/plan`
runs on Fable, the advisor is consulted at decision points (before choosing an
approach, a schema or public API, a migration, a dependency, anything
irreversible, and when a failure repeats), and the `fable-validator` agent checks
every finished implementation before its pull request opens (`/lfg`, Phase 6.5).

| Tier | Use for | Commands here |
|------|---------|---------------|
| `haiku` | Mechanical scans (file finding, naming-convention sweeps, pattern scans) | *(no command; the Explore agents `/plan` and `/lfg` fan out)* |
| `sonnet` | Prescriptive, pattern-following passes with a tight prompt; any spawned agent that names no model | `/github-review-comments`, `/github-review-failures` |
| `opus` | Sessions, orchestration, security, full PR review, and reasoning-heavy specialists | `/lfg`, `/architect`, `/security`, `/review-pr`, `/github-review-pr`, `/tdd`, `/perf` |
| `fable` | Planning, the advisor, and final validation | `/plan`, the `fable-validator` agent |

Rules of thumb:

- **Always use the alias**, never `claude-opus-4-8` or another full model ID —
  aliases track the latest model per tier and never rot.
- **Every spawned agent names its `model:`.** One that does not runs on `sonnet`
  (`CLAUDE_CODE_SUBAGENT_MODEL`), never on the session's model.
- **Plan mode cannot take a model of its own.** It runs on Opus and asks the
  advisor.

The convention is also recorded in the repo `AGENTS.md` ("Slash Commands") so it
survives across sessions.

## Authoring a new command

1. Copy `SKILL_TEMPLATE.md` into `commands/{name}.md`.
2. Pick the tier by the table above.
3. Write a `description` that leads with what it does and when to use it.
4. Scope `allowed-tools` if the command should be constrained (review/CI commands
   usually are; open implementation commands usually are not).
5. Add a row to the "Slash Commands" table in `AGENTS.md`.
