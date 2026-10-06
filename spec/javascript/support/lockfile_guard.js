// Preloaded by bunfig.toml before any JS spec (issue #331): refuse to run the
// suite against a happy-dom other than the one bun.lock pins.
//
// A git worktree without its own node_modules resolves packages from the main
// checkout's, which may be months behind the lockfile. happy-dom before
// 20.11.2 let a garbage collection kill a MutationObserver, so a stale install
// turned early.js's specs into a one-in-sixteen flake instead of a failure.
import { readFileSync } from "node:fs"
import { createRequire } from "node:module"
import { join } from "node:path"

const root = join(import.meta.dir, "../../..")
const lock = readFileSync(join(root, "bun.lock"), "utf8")
const pinned = /"happy-dom": \["happy-dom@([^"]+)"/.exec(lock)?.[1]
const manifest = createRequire(import.meta.path).resolve("happy-dom/package.json")
const installed = JSON.parse(readFileSync(manifest, "utf8")).version

if (!pinned) throw new Error("lockfile_guard: no happy-dom entry found in bun.lock; update the guard's pattern.")
if (installed !== pinned) {
  throw new Error(
    `happy-dom ${installed} is installed (${manifest}) but bun.lock pins ${pinned}. ` +
      `Run \`bun install\` in the checkout that owns that node_modules.`,
  )
}
