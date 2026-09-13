# Git Workflow Rules

## Commit Messages

Use conventional commits:
- `feat:` - New feature
- `fix:` - Bug fix
- `refactor:` - Code refactoring
- `perf:` - Performance improvement
- `docs:` - Documentation only
- `test:` - Adding/updating tests
- `chore:` - Maintenance tasks
- `ci:` - CI/CD changes

Format:
```
feat(scope): brief description

Longer explanation if needed. Focus on WHY, not WHAT.

Refs #123
```

Scopes map to the architecture: `streamable`, `component`, `controller`,
`client`, `engine`, `docs`, `ci`.

## Branch Naming

- `feature/description` - New features
- `fix/description` - Bug fixes
- `refactor/description` - Refactoring
- `ci/description` - CI changes
- `chore/description` - Maintenance

## PR Workflow

All work goes through PRs.

1. Create branch from `main`
2. Make focused, atomic commits
3. Run validators before pushing (`bundle exec rake`)
4. Create PR with summary + test plan
5. Request review
6. Squash merge when approved + CI green

## Release

Releases go through `bin/release` — the front door that works out the next
version (`patch` default, `minor`, `major`, or an explicit `X.Y.Z`), shows the
commits since the last tag, refuses to run off a clean up-to-date `main`, and
hands off to `rake release[X.Y.Z]` (bumps version, re-locks the tracked
lockfiles, verifies the build, commits, pushes, creates the GitHub Release).
The Release workflow then publishes to RubyGems via trusted publishing (OIDC +
Sigstore). Never `gem push` by hand.

```bash
bin/release list        # last releases + what each bump would give
bin/release --dry-run   # show version + changes, publish nothing
bin/release minor       # 0.13.0 -> 0.14.0, after a y/N confirm
```

## Pre-Commit Checklist

Run before EVERY commit:
```bash
bundle exec rubocop                          # Style
bundle exec rspec spec/phlex spec/requests   # Fast suite
# (browser suite — spec/system — runs in CI; run locally before a PR touching the client)
```

## Rules

- **NEVER** commit directly to `main`
- **NEVER** force push to shared branches
- **NEVER** `gem push` manually — use `bin/release` (which drives `rake release[X.Y.Z]`)
- **ALWAYS** run validators before committing
- **ALWAYS** write meaningful commit messages
- Keep commits small and focused — one logical change per commit
