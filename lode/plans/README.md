# Plans

Plans for this repository live in two places, and which one depends on how the work will be picked up:

- **GitHub issues** — the default. `zoolutions/phlex-reactive` issues are the execution unit the implementation workflow takes by number, and the codebase cross-references them heavily (nearly every non-obvious comment in `lib/` names the issue that produced it). Dedupe with `gh issue list --search "<keywords>"` before opening one, and apply the `plan` label if it already exists rather than creating labels.
- **`../../docs/plans/`** — markdown, named `YYYY-MM-DD-<slug>.md`, for a plan too long or too exploratory for an issue body. `docs/plans/165-deferred-reply-segments.md` is the existing example; note it is named for its issue number rather than by date, so match whichever convention the neighbouring file uses when you add one.

A plan file is left uncommitted unless the author decides otherwise — committing it is a choice, not a step.

Working notes, gate reports and handovers are NOT plans: they go in `../tmp/`, which is git-ignored.
