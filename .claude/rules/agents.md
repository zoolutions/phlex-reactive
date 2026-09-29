# Agent Orchestration Rules

## Available Agents

| Agent | Purpose | When to Use |
|-------|---------|-------------|
| Explore | Codebase exploration | Finding files, understanding patterns across the gem + dummy app |
| Plan | Implementation planning | Complex features spanning component → endpoint → client |
| general-purpose | Multi-step tasks | Research, complex searches |

## Immediate Agent Usage

Use agents PROACTIVELY without waiting for a prompt:

1. **Complex feature requests** → Plan agent first
2. **Codebase exploration** → Explore agent
3. **Multi-file searches** → Explore agent (not direct Glob/Grep)
4. **Cross-repo questions** (phlex-reactive ↔ pgbus) → Explore agent (`model: haiku`) against both checkouts

## Parallel Execution

ALWAYS run independent operations in parallel:

```markdown
# GOOD: parallel
1. Agent 1: how Streamable builds + broadcasts today
2. Agent 2: how the client runtime handles the response
3. Agent 3: what pgbus primitive this needs (against the pgbus checkout)

# BAD: sequential when independent
```

## When to Use Explore

Use the Explore agent (subagent_type=Explore, model=haiku) instead of direct Glob/Grep when:
- Open-ended exploration across the gem (`lib/`, `app/`) and the dummy app (`spec/dummy/`)
- Confirming a pgbus primitive's real signature in `~/Code/mhenrixon/pgbus`
  before building against it (verify the wire format — don't assume)
