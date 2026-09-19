# Command Template

Use this template when creating a new slash command for phlex-reactive. See
`.claude/README.md` for the full authoring guide.

Copy the content below into `.claude/commands/{name}.md`, then fill it in.

Pick the model tier by the work the command does: `haiku` for mechanical/config
work, `sonnet` for prescriptive pattern-following passes, `opus` for
orchestration, security, review synthesis, and reasoning-heavy specialists.
Always use the tier alias, never a full model ID — aliases track the latest model
in the tier. Pin `fable` only on read-only planning commands that hand execution
to cheaper models (see `/plan`); otherwise choose it per-session with `/model`.

```markdown
---
model: sonnet
description: "{Action verbs describing what it does}. Use when {trigger phrases, contexts, file types}."
argument-hint: "{example input the user might provide}"
allowed-tools: {optional — narrow the tool allowlist, e.g. Bash(gh pr view:*), Read, Grep}
---

# {Command Title}

{One or two sentences: what this command is for and the mental model.}

## When to Use

- {Trigger context 1}
- {Trigger context 2}

## Workflow

1. {Step}
2. {Step}

## Project invariants to respect

- **Signed identity, never state** — the DOM carries `{c, gid}` / `{c, state}`; re-find server-side.
- **Default-deny actions** — only `action :name` methods run; mutating actions `authorize!`.
- **Declared, coerced params** — declare a `params:` schema; no raw mass assignment.
- **Component self-targets via `#id`** — no hand-picked Turbo targets; `#id` is render-context-free.
- **pgbus is optional** — capability-gate every pgbus-only feature and fall back to `Turbo::StreamsChannel`.

## Verification

```bash
bundle exec rspec spec/phlex spec/requests
bundle exec rubocop
```

## Checklist

- [ ] {Success criterion}
- [ ] `bundle exec rubocop` passes
```

After creating the file, add a row to the "Slash Commands" table in the repo
`AGENTS.md` so the command is discoverable and its tier is recorded.
