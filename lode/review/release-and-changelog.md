# Review rules: the release task and the changelog

A release is cheap to re-run and expensive to get wrong, which is the reasoning behind every rule here.

### Every read and every validation happens BEFORE the first destructive or irreversible step
- **Holds because:** `rake release` does two irreversible things — `gh release delete --cleanup-tag`, which takes the GitHub release, its generated notes and its assets with it, and the writes to `version.rb` and the lockfiles. A validation that aborts after either one leaves the release destroyed or the tree dirty, and the task's own clean-tree guard then blocks the retry. That is exactly the state a failed v0.13.1 attempt left behind. The lockfile preflight only READS files, so there was never a reason for it to run late; it now sits immediately after the header, ordered `header → 0a preflight → 0b force cleanup → 1 version → 1b lockfiles`, and Step 1b writes from the already-read contents.
- **Where:** `Rakefile`, the `:release` task — Step 0a (preflight), Step 0b (force cleanup), Step 1, Step 1b
- **Safe direction:** aborting while failing is still free. An abort must be able to say "Nothing has been modified" truthfully.
- **Proven by:** no automated test — the task is verified by hand against copies of both real lockfiles (the PR records the four branches: clean bump, re-run, no pin, partial). Any change here needs the same manual matrix.
- **Origin:** PR #253

### The lockfile pin is COUNTED first: zero aborts, all-current skips, anything stale is rewritten
- **Holds because:** comparing `bumped == content` cannot distinguish "no pin at all" from "pins present and already at the new version". The second is a legitimate state — a re-run after a partial failure — so it cannot simply abort; the first means the file does not pin the gem the way the task thinks, and proceeding would ship `version.rb` bumped against a lockfile still naming the old version. `pin_pattern` is `/^(\s+phlex-reactive) \(([^)]*)\)$/`, which matches the PATH-source spec and the CHECKSUMS pin and deliberately does not match the version-less `phlex-reactive!` in DEPENDENCIES. **Do not assert exactly two matches:** a lockfile written by an older bundler has no CHECKSUMS section and legitimately carries one pin, and a half-applied edit (one stale, one current) passes a `== 2` check while still needing a write.
- **Proven by:** no automated test — verified by hand against copies of both real lockfiles across four branches (clean bump, re-run, no pin, partial).
- **Where:** `Rakefile`, the `:release` task — `pin_pattern`, the Step 0a scan, the Step 1b rewrite
- **Origin:** cubic learning fd99aadf; PR #253

### The pin is bumped with a text edit, not a re-resolve
- **Holds because:** `bundle lock --local` is a full re-resolve, and a re-resolve trips over constraints unrelated to this gem — `docs/Gemfile.lock` declares platform-specific entries a laptop cannot satisfy. The only line a version bump needs to change is the path-gem pin, so the task rewrites exactly that line in both tracked lockfiles and leaves everything else byte-identical.
- **Proven by:** no automated test; the Release workflow's frozen `bundle install` is the downstream gate that catches a stale pin.
- **Where:** `Rakefile`, `:release` Step 1b; the two tracked lockfiles are `Gemfile.lock` (the root `Gemfile` says `gemspec`) and `docs/Gemfile.lock` (`path: ".."`)
- **Origin:** PR #253

### `## [Unreleased]` carries ONE block per section, `### Added` before `### Fixed`
- **Holds because:** the file declares the Keep a Changelog format, which orders Added first. Two blocks of the same section under one heading is how a merge or a hand-edit hides an entry — and two bullets describing the same mechanism is how the changelog ends up contradicting itself (one bullet claiming the release task "re-locks every tracked lockfile" while the one above it says the pin is bumped with a text edit). Both bullets sat under the same unshipped heading, so there was no reason to keep two descriptions of one mechanism: merge, never append a second.
- **Proven by:** no automated test — this is a review-time check, and it is in `../workflow.md`'s conflict table because a merge is where the duplicate block appears.
- **Where:** `CHANGELOG.md`, the `## [Unreleased]` heading
- **Origin:** cubic learnings 0fa5ffc3; PR #253

Related: [`../testing-and-ci/summary.md`](../testing-and-ci/summary.md), [`docs-and-changelog.md`](docs-and-changelog.md).
