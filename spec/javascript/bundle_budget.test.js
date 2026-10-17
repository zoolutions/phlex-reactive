// The client's byte budget (issue #275).
//
// The gem ships one minified file per module; the browser pays their gzipped
// size. The client has TWO entries, and an app loads one of them:
//
//   reactive_controller    the DEFAULT: the runtime and every feature in
//                          ONE file. Every page with a reactive root loads
//                          all of it, and nothing later.
//   core                   opt-in: the runtime alone. It then imports
//                          features/<name> on a page that uses one.
//
// This file REPORTS every built module and holds these lines:
//
//   early.min.js           the one module every page loads eagerly — its own
//                          budget, asserted since issue #273.
//   reactive_controller    a no-growth RATCHET on the default bundle.
//   core                   a RATCHET that each phase of #275 lowered to the
//                          size it reached, as code moved out to features;
//                          now the final size (see BUDGET OUTCOME below).
//   features/<name>        a ceiling each; a feature without one fails.
//   SPLIT TOTAL            core + every feature: what a page on the split
//                          client downloads if it uses everything. Moving code
//                          into its own file costs bytes (it compresses worse
//                          alone), so this line keeps the sum honest while
//                          the core shrinks.
//
// TARGET_CORE_GZIP is the maintainer's target for the core — 10,240 B. It is
// reported against on every run, and is the ratchet itself when met.
//
// Sizes are of the COMMITTED build (rake build:js_check guards that it matches
// a fresh one), gzipped at level 9 by bun's zlib. Another gzip (the CLI, a
// CDN) lands within about half a percent of these numbers, not on them.
//
// Run with: bun test spec/javascript
import { test, expect } from "bun:test"
import { existsSync, readdirSync, readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { gzipSync } from "node:zlib"

const root = join(dirname(fileURLToPath(import.meta.url)), "../..")
const srcDir = join(root, "app/javascript/phlex/reactive")

// Every module the build emits, read from the build script itself so a new
// entry (a feature module) is reported without anyone editing this file.
const buildScript = readFileSync(join(root, "scripts/build_client.js"), "utf8")
const ENTRIES = [...buildScript.match(/const ENTRIES = \[([^\]]*)\]/)[1].matchAll(/"([^"]+)"/g)].map(([, name]) => name)
const BUNDLE = buildScript.match(/const BUNDLE = "([^"]+)"/)[1]
const SPLIT = buildScript.match(/const SPLIT = "([^"]+)"/)[1]
const MODULES = [BUNDLE, SPLIT, ...ENTRIES]
const FEATURES = ENTRIES.filter((name) => name.startsWith("features/"))

// Raised from 1,100 for window-bound (hotkey) capture, issue #303. Issue #357
// (a shortcut: is prevented before connect; the other platform's twin and a
// press in an editable field are skipped, for key-filtered descriptors
// only) adds 195 B: 1,296 → 1,491 B. Issue #366 (a delete/backspace chord binds
// a bare keydown: the chord read off the element decides what is queued and
// prevented) adds 134 B: 1,487 → 1,621 B.
const EARLY_GZIP_BUDGET = 1621
// How far a ceiling may sit above the real size: the rounding it is set with.
const SLACK = 250

// The DEFAULT bundle. Before the split the one file was 22,272 B (a32937b).
// The split left it at 26,132 B — 3,860 B more. Issue #305 builds it with
// __SPLIT__ false: the runtime imports every feature statically and calls it
// directly, so the loader, the feature table and the hand-over fold away
// (24,675 B, 1,457 B recovered). Issue #306 (the cache: shell fallback) adds
// 87 B: 24,762 B.
//
// BUDGET OUTCOME (issue #305; the rest is #310): the target is TARGET_BUNDLE_GZIP, 22,700 B (the
// pre-split size plus a loader's worth). It is reported on every run, and is
// the ratchet itself when met. What the flag cannot recover is how the
// features are WRITTEN as modules — per-root state records where the
// controller had private fields, exported wrappers, the `core` handle — not
// the boundary between them and the runtime. Issue #303 (replaying
// window-bound hotkeys) adds 214 B on that 24,762 B baseline: 24,976 B. The
// ratchet below sits 24 B above the real size (inside SLACK): room for a
// fix in flight, not for a feature. Issue #297 (a select's reset state)
// adds 44 B: 25,020 B, and the ratchet moves by the 20 B it needs. Issue
// #298 (one unsaved-changes prompt per visit) adds 17 B: 25,037 B. Skipping
// a disabled <optgroup>'s options in the reset state (#297) adds 11 B: 25,048 B.
// Merged on top of #300, #292/#294 and #301 (which used the 24 B of slack):
// 25,067 B. Issue #299 (a nested row serialized like a real submit, incl. a
// <fieldset disabled> ancestor via :disabled) adds 24 B: 25,091 B. Issues
// #295/#296 (effects settle: hidden-tab legs exit, descendant end events)
// add 46 B: 25,137 B. Issue #319 (bulk selection: the checked: term,
// reactive_enable/select_all/count with their MutationObserver, and
// js.submit's submitter:, review fixes included) adds 796 B: 25,933 B.
//
// Issue #310 rewrote the features' per-root records as closures (form,
// bindings, persist, defer), shortened compute's, dropped the per-call
// context records and wrapper exports (hints, devtools, bindings), and laid
// the features out in the bundle so gzip's 32 KB window reaches the runtime
// code they repeat (the import order in runtime.js): 1,008 B recovered,
// 24,925 B. That leaves the target 2,225 B away, about 800 B of it #319's
// feature; what remains is the features' own code, not how they are written
// as modules. runTransition's settle fix (its own end event only, both
// listeners dropped, transitionend, a late frame canceled) adds 37 B: 24,962 B.
// Its run token and computed-duration fallback add 212 B: 25,174 B; counting
// an animation's iterations in that fallback adds 71 B: 25,245 B. Issue #338
// (a morph keeps the focused field's value, its default written) adds 184 B: 25,429 B.
// Issue #336 (a defer reply renders now, not a frame later) adds 128 B: 25,557 B.
// Issue #342 (the check_group op, a form reset re-syncs the group) adds 132 B: 25,689 B;
// its reset also re-arming on_complete latches adds 9 B: 25,698 B.
// Issue #343 (cross-root group targets: a count and an enable outside the
// owning root, sharing the show targets' guard and parser) adds 218 B: 25,916 B.
// Issue #346 (on_client's detail: filter on event.detail) adds 69 B: 25,985 B.
// Issue #348 (a checked-only show target decides at zero boxes) adds 29 B: 26,014 B.
// Issue #350 (sortable lists: a NEW feature module — pointer and keyboard
// drags, the placeholder, auto-scroll, the live region, the rollback — plus
// the runtime's marker and core.proceed's reply) adds 2,930 B: 28,944 B. The
// issue's aim was 3 KB or less for the feature in the default entry; the
// default entry has no import(), so it carries it. Its review fixes (the live
// region made at connect and written a frame later, boundary moves announced)
// add 22 B: 28,966 B. PR #352 review (one pointer drives a drag, a cancelled
// click, targets: selectors, nested-root keys) adds 87 B: 29,053 B.
// Issue #351 (editable text: the collector, the server text and the morph hold
// in the core; keys, paste and the plaintext-only fallback in bindings; dirty
// and drafts) adds 963 B on main (26,977 B); merged on top of #350, 921 B: 29,887 B.
// With #352's review fixes merged in: 29,964 B. A first editable a stream
// appends loads bindings on its focus (#351): 29,978 B. Issue #355 (the plaintext-only
// fallback moves from bindings into one runtime observer) adds 152 B: 30,130 B; observing data-reactive-editable too, 30,135 B.
// Issue #357 (shortcut: — the platform twin, the editable guard, the prevent) adds 177 B: 30,312 B.
// Issue #356 (a stream into a connected root re-reads its markers and re-runs
// its seeds; form and bindings wire a gate that reads true only then) adds 274 B on
// #355 (30,409 B); on top of #357, 305 B: 30,617 B.
// Issue #358 (presence: a NEW feature module — the minted source, the announce,
// the me / same-member marks, the joined/left diff — plus the runtime's marker,
// the presence op and the X-Reactive-Presence header) adds 769 B: 30,904 B; on top of #357 and #356, 763 B: 31,380 B. Its real-SSE fixes (mint the source before
// pgbus defines it, re-announce until the roster shows the tab, the root seat list) add 242 B: 31,622 B. On pgbus 0.18 (pgbus:connected after the join) the
// re-announce becomes one check: -62 B, 31,560 B; logging a failed announce adds 49 B: 31,609 B.
// Issue #366 (delete/backspace in the key map; the shortcut check moved ahead of
// dispatch/runOps's bookkeeping for a bare keydown) adds 31 B: 31,640 B.
// Issue #365 (show_modal / close_dialog and the data-reactive-modal upgrade) adds 421 B: 32,030 B;
// telling a kept `open` from a removed one adds 78 B: 32,108 B; upgrading a root
// that is itself the dialog adds 12 B: 32,120 B.
// #365 and #366 together: 32,147 B.
// Issue #369 (keep: on client ops — the kept-result registry and its one
// turbo:morph-element listener; entries kept in op order) adds 251 B: 32,398 B.
// Issue #370 (the held mark, reactive:held, X-Reactive-Held and the own-reply
// release; the error reply never marks; checkboxes and radios are never held) adds 550 B on #366/#365 (32,697 B); on top of #369, 534 B: 32,932 B.
// Issue #374 (the set_value op, comparing a <select multiple>'s whole selection)
// adds 111 B on #366/#365 (32,258 B); on top of #369 and #370, 134 B: 33,066 B.
// Issue #375 (js.preview_file: the op, its object-URL map and the observer that
// revokes) adds 367 B on #366/#365 (32,514 B); on top of #369, #370 and #374,
// 323 B: 33,389 B.
// Issue #373 (copy_media, the media marker, the reactive_media binding, refusing srcset
// and a media label of @root) adds 404 B on #366/#365 (32,551 B); on top of #369, #370,
// #374 and #375, 410 B: 33,799 B; slicing take: by code point, 33,805 B.
// One window listener pair for every warn_unsaved root (connecting N guarded
// forms was quadratic) adds 110 B: 33,915 B. One document submit-end listener for
// every persisted root, 84 B: 33,999 B.
// Issue #381 (an <img> source without src is a hit: copy_media keeps its alt) adds 1 B: 34,000 B.
// Issue #382 (preview_file valid: — an invalid input previews as empty) adds 23 B: 34,022 B;
// on top of #381, 22 B: 34,022 B.
// Issue #380 (reactive_media pending: take/match, pending: keep, data-reactive-media-state)
// adds 160 B on #373 (34,159 B); on top of #381 and #382, 152 B: 34,174 B.
// Issue #383 (reactive_image_fallback: the document error/load listener, the
// morph that keeps a src keeping its state, the copy_media/preview_file reset,
// the restoration-safe hidden mark and the decode() check in the sweep) adds
// 582 B on #381; on top of #382, 584 B (34,606 B); on top of #380, 586 B: 34,760 B;
// ignoring a stale sweep decode(), 11 B: 34,771 B.
// Issue #390 (reactive_media when:, the whole field before the pool lookup) adds 25 B: 34,796 B.
// Issue #398 (nested select-all groups: under: paths, in bindings) adds 76 B on #390: 34,872 B.
// Issue #395 (the same: show term, in bindings) adds 103 B: 34,874 B.
// Issue #396 (the digits: term and the after: blur gate, in bindings) adds 232 B: 35,106 B.
// Issue #394 (clear:/focus:/scroll: on a show's visibility change, in bindings) adds 282 B: 35,388 B;
// its review fixes (clear: by attribute, visibility tracked for every binding) 23 B: 35,411 B;
// on top of #390, 35,438 B; on top of #398, 35,509 B.
// Issue #397 (reactive_persist storage: :session, in persist) on top of #394: 35,528 B.
// Issue #391 (preview_file wrap:, max_bytes:, accept:, reactive:file-rejected, with its
// review fix) and #392 (reactive_image_fallback wrap:) add 396 B on top of #397: 35,924 B.
// Issue #393 (on_client debounce:/throttle: on on()'s timers, keyed per record) adds 150 B: 34,921 B.
// Issue #399 (the blur op) adds 41 B: 34,962 B.
// Keying an on_client wait on the record's ordinal too (two identical records keep their own) adds 23 B: 34,985 B.
// #393/#399 on top of #391, #392, #394, #395, #396, #397 and #398: 36,114 B.
// Issue #400 (countdown: a NEW feature module — the Date.now tick, the wake
// re-sync, the once-per-deadline event, ignoring a bad selector — plus the runtime's marker) adds 573 B: 35,344 B;
// its review fixes (every fired deadline kept, an id-less root's own key) 67 B: 35,411 B;
// on top of #390 (34,796 B), 643 B in all: 35,439 B; on top of #398 (34,872 B), 635 B: 35,507 B;
// on top of #394/#395/#396 (35,509 B), 648 B: 36,157 B; on top of #397 (35,528 B), 648 B: 36,176 B;
// on top of #391/#392 (35,924 B), 641 B: 36,565 B; on top of #393/#399 (36,114 B), 653 B: 36,767 B.
// Issue #410 (a tokenless client-only root forwards server dispatches to the
// token-bearing root above and is transparent to its field collection) adds 337 B: 37,104 B;
// its review fix (a held dispatch cancels the native default at once) 77 B: 37,181 B.
// Issue #413 (X-Reactive-Refused: a refused reply keeps the held marks it names) adds 65 B: 37,246 B.
// Issue #417 (reactive_css_vars: fields fed into CSS custom properties, in bindings, plus the
// runtime's marker) adds 457 B: 37,703 B; its review fix (a to: that does not parse matches nothing) 3 B: 37,706 B.
// Issue #416 (draggable regions: a NEW feature module — pointer and keyboard
// moves and resizes, the aspect lock and re-fit, the live region, the morph
// hold — plus the runtime's marker) adds 2,702 B: 39,948 B; its review fixes (rounding kept inside the
// frame, a keyboard drag whose element was removed) 95 B: 40,043 B;
// on top of #417 (37,706 B), 2,788 B: 40,494 B; its PR review fix (a release after a morph removed
// the element sends nothing) 1 B: 40,495 B.
const BUNDLE_GZIP_CEILING = 40_495
const TARGET_BUNDLE_GZIP = 22_700
// The split core (the runtime + the import table). The monolith was 22,272 B;
// phase 1 (the loader) brought it to 22,787 B, phase 2 (persist + editors
// out) to 21,233 B, phase 3 (defer / lazy out) to 19,740 B, phase 4 (effects
// and dismiss, dirty tracking and the paste gate, the latency simulator out)
// to 18,536 B, phase 5 (the form bindings, compute, the hint engine, the
// diagnostics and the debug trace out) to 12,383 B.
//
// BUDGET OUTCOME (issue #275): the maintainer's target for the core is
// TARGET_CORE_GZIP, 10,240 B. The honest moves left the core 2,143 B over it, so the ratchet below is the real size rounded up to the next 250 B, and the target is printed in the report; the PR body's Budget outcome section has the gap and the remaining options.
// Issue #303 (replaying window-bound hotkeys, shared runtime code) adds 210 B: 12,688 B.
// Issue #319 (the submit op's submitter:, the bindings marker for the group
// bindings) adds 129 B: 12,817 B; its review fixes (the morph-installed
// observer, show-target checked_* re-sync) add 14 B: 12,831 B. Issue #310
// (feature internals only) leaves it unchanged. runTransition's settle fix
// adds 51 B: 12,882 B. Its run token and computed-duration fallback add
// 199 B: 13,081 B; counting animation iterations adds 56 B: 13,137 B.
// Issue #338 (a morph keeps the focused field's value) adds 186 B: 13,323 B.
// Issue #336 (a held stream wraps a copy, not the event's detail) adds 21 B: 13,344 B.
// Issue #342 (the check_group op) adds 40 B: 13,384 B.
// Issue #343 (the bindings marker for group targets) adds 8 B: 13,392 B.
// Issue #346 (on_client's detail: filter) adds 55 B: 13,447 B.
// Issue #350 (the sortable marker and table entry, core.proceed's busy hint
// and its reply) adds 54 B: 13,501 B.
// Issue #351 (editable text: the collector, the server text, the morph hold
// and the bindings marker) adds 376 B on main (13,823 B); on top of #350, 369 B: 13,870 B. A stream bringing
// an editable starts the bindings import, and its focus loads it: 13,906 B.
// Issue #355 (the plaintext-only probe and observer, from bindings) adds 240 B: 14,146 B; observing data-reactive-editable too, 14,147 B.
// Issue #357 (shortcut:) adds 192 B: 14,339 B.
// Issue #356 (the stream-into-root signal; the hold reads every stream's content)
// adds 211 B on #355 (14,358 B); on top of #357, 215 B: 14,554 B.
// Issue #358 (the presence marker and table entry, the presence op, the
// X-Reactive-Presence header) adds 103 B: 14,250 B; on top of #357 and #356, 100 B: 14,654 B.
// Issue #366 (delete/backspace in the key map, the early shortcut bail) adds 23 B: 14,677 B.
// Issue #365 (show_modal / close_dialog and the data-reactive-modal upgrade) adds 359 B: 15,013 B;
// telling a kept `open` from a removed one adds 66 B: 15,079 B; upgrading a root
// that is itself the dialog adds 14 B: 15,093 B.
// #365 and #366 together: 15,112 B.
// Issue #369 (keep: on client ops, in the runtime) adds 247 B: 15,359 B.
// Issue #370 (the held mark, reactive:held, X-Reactive-Held and the own-reply
// release; the error reply never marks; checkboxes and radios are never held) adds 566 B on #366/#365 (15,678 B); on top of #369, 559 B: 15,918 B.
// Issue #374 (the set_value op) adds 120 B on #366/#365 (15,232 B); on top of
// #369 and #370, 117 B: 16,035 B.
// Issue #375 (js.preview_file) adds 374 B on #366/#365 (15,486 B); on top of
// #369, #370 and #374, 356 B: 16,391 B.
// Issue #373 (copy_media, the media marker, refusing srcset) adds 182 B on #366/#365
// (15,294 B); on top of #369, #370, #374 and #375, 170 B: 16,561 B.
// Issue #381 (an <img> source without src is a hit: copy_media keeps its alt) saves 2 B: 16,559 B.
// Issue #382 (preview_file valid: — an invalid input previews as empty) adds 30 B: 16,591 B;
// on top of #381, 34 B: 16,593 B.
// Issue #383 (reactive_image_fallback, in the runtime) adds 546 B on #381; on top
// of #382, 546 B: 17,139 B.
// Ignoring a stale sweep decode() adds 4 B: 17,143 B.
// Issue #394 (set_value's write on the feature handle, for reactive_show clear:) adds 10 B: 17,153 B.
// Issue #391 (preview_file wrap:, max_bytes:, accept:, reactive:file-rejected, with its
// review fix) and #392 (reactive_image_fallback wrap:) add 387 B on top of #394: 17,540 B.
// Issue #393 (on_client debounce:/throttle:) adds 127 B: 17,270 B.
// Issue #399 (the blur op) adds 39 B: 17,309 B.
// Keying an on_client wait on the record's ordinal too adds 22 B: 17,331 B.
// #393/#399 on top of #391, #392 and #394: 17,727 B.
// Issue #400 (the countdown marker and table entry) adds 27 B: 17,170 B; on top of #394, 25 B: 17,178 B;
// on top of #391/#392 (17,540 B), 24 B: 17,564 B; on top of #393/#399 (17,727 B), 31 B: 17,758 B.
// Issue #410 (client-only roots transparent to server round trips, in the runtime) adds 349 B: 18,107 B;
// its review fix (a held dispatch cancels the native default at once) 66 B: 18,173 B.
// Issue #413 (X-Reactive-Refused: a refused reply keeps the held marks it names) adds 60 B: 18,233 B.
// Issue #417 (the bindings marker for reactive_css_vars) adds 16 B: 18,249 B.
// Issue #416 (the drag marker and table entry) adds 55 B: 18,288 B; on top of #417, 51 B: 18,300 B.
const CORE_GZIP_CEILING = 18_300
const FEATURE_GZIP_CEILINGS = {
  // Issue #319 (bulk selection) took it from 5,360 B to 5,967 B; its review
  // fixes to 6,015 B. Issue #310 (listeners and seeds as closures, no
  // wrappers) to 5,859 B. Issue #310 lowered every ceiling below to its
  // module's real size, rounded up to the next 50 B. Issue #342 (check_group,
  // the reset re-sync) takes it to 5,988 B.
  // module's real size, rounded up to the next 50 B. Issue #343 (cross-root
  // group targets) takes it to 6,203 B. Issue #351 (editable text: Enter,
  // Escape, paste/drop, the plaintext-only fallback) takes it to 6,771 B.
  // Issue #373 (the reactive_media binding) takes it from 6,664 B to 6,884 B;
  // never resolving a label or pool value of @root, 6,888 B; slicing take: by
  // code point, 6,895 B.
  // Issue #380 (the pending state, match:, pending: keep, data-reactive-media-state) to 7,047 B.
  // Issue #390 (reactive_media when:) to 7,069 B.
  // Issue #398 (nested select-all groups: under: paths) to 7,135 B.
  // Issue #395 (the same: term and its ASCII fold) to 7,144 B.
  // Issue #396 (the digits: term and the after: blur gate) to 7,362 B.
  // Issue #394 (clear:/focus:/scroll: on a show's visibility change) to 7,658 B;
  // its review fixes to 7,680 B; on top of #390, 7,719 B;
  // on top of #398, 7,783 B.
  // Issue #417 (reactive_css_vars: the number read, the unit and name allowlists) to 8,238 B;
  // its review fix (a to: that does not parse matches nothing) to 8,245 B.
  "features/bindings": 8_245,
  // Issue #336 (render a defer reply now) takes it from 2,845 B to 2,974 B.
  "features/defer": 2_974,
  "features/compute": 2_050,
  "features/hints": 1_000,
  "features/effects": 1_750,
  // Issue #351 (an editable drafted through the core's collector) takes it to 3,167 B.
  // One document submit-end listener for every persisted root, to 3,283 B.
  // Issue #397 (storage: :session selects sessionStorage) to 3,303 B.
  "features/persist": 3_303,
  // Issue #351 (an editable's dirty diff against its server text) takes it to 1,088 B.
  // Issue #356 (a gate wired the first time it reads true, and reseed) to 1,152 B.
  // One window listener pair for every warn_unsaved root, to 1,268 B.
  "features/form": 1_268,
  "features/devtools": 1_600,
  // Issue #350: sortable lists, 3,094 B; its review fixes take it to 3,130 B; PR #352 review to 3,215 B.
  "features/sortable": 3_215,
  // Issue #416: draggable regions, 3,478 B; its review fixes take it to 3,572 B; its PR review fix to 3,576 B.
  "features/drag": 3_576,
  // Issue #358: presence, 1,084 B (the issue's aim was 1.5 KB or less); its real-SSE
  // fixes (the late-defined source, the re-announce, the root seat list) take it to 1,353 B;
  // on pgbus 0.18 the re-announce becomes one check: 1,297 B; logging a failed announce: 1,362 B.
  "features/presence": 1_362,
  // Issue #400: countdown, 914 B; its review fixes (every fired deadline kept, an
  // id-less root's own key) take it to 966 B.
  "features/countdown": 966,
}
// Phase 5: 12,383 B core + 5,360 + 2,846 + 2,084 + 1,024 + 1,693 + 3,210 + 1,015 + 1,589 B of
// features = 31,204 B. Issue #305 (the default entry's static path) costs the
// core 84 B: 12,467 + 18,821 = 31,288 B. Issue #306 (a cache: shell's refused
// URL falls back to a GET; no __materialize POST without a token) adds 97 B:
// 31,385 B. Issue #303 (window-bound hotkeys, in the core) adds 215 B: 31,600 B.
// The backlog fixes (#292-#301, #295/#296) together use the 150 B of room and
// 37 B more: 31,787 B. Issue #319 (bulk selection, in the core and bindings)
// adds 781 B: 32,568 B. Issue #310 (the features' internals) recovers 541 B:
// 32,027 B. runTransition's settle fix (in the core) adds 51 B: 32,078 B;
// its run token and computed-duration fallback add 199 B: 32,277 B; counting
// animation iterations adds 56 B: 32,333 B. Issue #338 (a morph keeps the
// focused field's value, in the core) adds 186 B: 32,519 B. Issue #336 (render a
// defer reply now, in features/defer, plus the core's held-stream fix) adds
// 150 B: 32,669 B. Issue #342 (check_group, in the core and bindings) adds
// 169 B: 32,838 B; its reset re-arming on_complete latches adds 11 B: 32,849 B.
// 150 B: 32,669 B. Issue #343 (cross-root group targets, in bindings plus the
// core's marker) adds 212 B: 33,061 B.
// Issue #346 (on_client's detail: filter, in the core) adds 55 B: 33,116 B.
// Issue #348 (a checked-only show target decides at zero boxes, in bindings)
// adds 31 B: 33,147 B.
// Issue #350 (the sortable feature module, 3,094 B, plus 54 B in the core)
// adds 3,146 B: 36,293 B; its review fixes add 36 B: 36,329 B; PR #352 review adds 85 B: 36,414 B.
// Issue #351 (editable text, in the core, bindings, form and persist) adds
// 986 B on main (34,133 B); on top of #350, 981 B: 37,310 B.
// With #352's review fixes merged in: 37,395 B; a late editable's bindings: 37,416 B.
// Issue #355 (the plaintext-only fallback: +240 B core, -138 B bindings) adds 102 B: 37,518 B (37,519 B with data-reactive-editable observed).
// Issue #357 (shortcut:, in the core) adds 192 B: 37,711 B.
// Issue #356 (+215 B core, +64 B form, +46 B bindings) adds 325 B: 38,036 B.
// Issue #358 (the presence feature module, 1,084 B, plus 103 B in the core) adds 1,187 B: 38,706 B; on top of #357 and #356 (1,084 B + 100 B core), 1,184 B: 39,220 B; its real-SSE fixes
// (+269 B presence) take it to 39,489 B; on pgbus 0.18 (one check, no re-announce),
// 39,433 B; logging a failed announce (+65 B), 39,498 B.
// Issue #366 (delete/backspace, in the core) adds 23 B: 39,521 B.
// Issue #365 (the dialog ops and the modal upgrade, in the core) adds 359 B: 39,857 B;
// telling a kept `open` from a removed one adds 66 B: 39,923 B; upgrading a root
// that is itself the dialog adds 14 B: 39,937 B.
// #365 and #366 together: 39,956 B.
// Issue #369 (keep: on client ops, in the core) adds 247 B: 40,203 B.
// Issue #370 (in the core) adds 566 B on #366/#365 (40,522 B); on top of #369, 559 B: 40,762 B.
// Issue #374 (the set_value op, in the core) adds 120 B on #366/#365 (40,076 B);
// on top of #369 and #370, 117 B: 40,879 B.
// Issue #375 (js.preview_file, in the core) adds 374 B on #366/#365 (40,330 B);
// on top of #369, #370 and #374, 356 B: 41,235 B.
// Issue #373 (+170 B core, +224 B bindings) on top of #369, #370, #374 and #375
// adds 394 B: 41,629 B; slicing take: by code point, 41,636 B.
// One window listener pair for every warn_unsaved root (form) adds 116 B: 41,752 B.
// One document submit-end listener for every persisted root (persist), 116 B: 41,868 B.
// Issue #381 (copy_media keeps a src-less source's alt, in the core) saves 2 B: 41,866 B.
// Issue #382 (preview_file valid:, in the core) adds 30 B: 41,898 B; on top of #381, 34 B: 41,900 B.
// Issue #380 (reactive_media pending, in bindings; the core unchanged) adds 152 B: 42,052 B.
// Issue #383 (reactive_image_fallback, in the core) adds 546 B on #381; on top of
// #382 (42,446 B) and #380, 546 B: 42,598 B; ignoring a stale sweep decode(),
// 4 B: 42,602 B.
// Issue #390 (reactive_media when:, in bindings; the core unchanged) adds 22 B: 42,624 B.
// Issue #398 (nested select-all groups, in bindings; the core unchanged) adds 66 B on #390: 42,690 B.
// Issue #395 (the same: show term, in bindings) adds 97 B: 42,699 B.
// Issue #396 (the digits: term and the after: blur gate, in bindings) adds 218 B: 42,917 B.
// Issue #394 (clear:/focus:/scroll: on a show's visibility change, in bindings) adds 306 B: 43,223 B;
// its review fixes 22 B: 43,245 B;
// on top of #390, 43,284 B; on top of #398, 43,348 B.
// Issue #397 (storage: :session, in persist; the core unchanged) on top of #394: 43,368 B.
// Issue #391 (preview_file wrap:, max_bytes:, accept:, with its review fix) and #392
// (reactive_image_fallback wrap:), both in the core, add 387 B on top of #397: 43,755 B.
// Issue #393 (on_client debounce:/throttle:, in the core) adds 127 B: 42,729 B.
// Issue #399 (the blur op, in the core) adds 39 B: 42,768 B.
// Keying an on_client wait on the record's ordinal too (in the core) adds 22 B: 42,790 B.
// #393/#399 on top of #391, #392, #394, #395, #396, #397 and #398: 43,942 B.
// Issue #400 (the countdown feature module, 915 B, plus 27 B in the core) adds 942 B: 43,544 B;
// its review fixes, 51 B: 43,595 B; on top of #390 (42,624 B), 993 B: 43,617 B;
// on top of #398 (42,690 B), 993 B: 43,683 B; on top of #394/#395/#396 (43,348 B), 991 B: 44,339 B;
// on top of #397 (43,368 B), 991 B: 44,359 B; on top of #391/#392 (43,755 B), 990 B: 44,745 B;
// on top of #393/#399 (43,942 B), 997 B: 44,939 B.
// Issue #410 (client-only roots transparent to server round trips, in the core) adds 349 B: 45,288 B;
// its review fix 66 B: 45,354 B.
// Issue #413 (X-Reactive-Refused, in the core) adds 60 B: 45,414 B.
// Issue #417 (reactive_css_vars: +455 B bindings, +16 B core) adds 471 B: 45,885 B;
// its review fix (in bindings) 7 B: 45,892 B.
// Issue #416 (the drag feature module, 3,478 B, plus 55 B in the core) adds 3,533 B: 48,947 B;
// its review fixes (+94 B drag) take it to 49,041 B;
// on top of #417 (45,888 B), 3,623 B: 49,511 B; its PR review fix (+4 B drag): 49,515 B.
const SPLIT_TOTAL_GZIP_CEILING = 49_515
// The maintainer's target for the core. Asserted as the ratchet when met.
const TARGET_CORE_GZIP = 10 * 1024

const builtPath = (name) => join(srcDir, `${name}.min.js`)

function sizeOf(name) {
  const bytes = readFileSync(builtPath(name))
  return { name, min: bytes.length, gzip: gzipSync(bytes, { level: 9 }).length }
}

const splitTotal = () => ["core", ...FEATURES].reduce((sum, name) => sum + sizeOf(name).gzip, 0)

function expectRatchet(actual, ceiling) {
  expect(actual).toBeLessThanOrEqual(ceiling)
  // A ceiling left far above the real size would let it regrow unnoticed.
  expect(ceiling - actual).toBeLessThan(SLACK)
}

test("every client module has a committed minified build", () => {
  expect(BUNDLE).toBe("reactive_controller")
  expect(SPLIT).toBe("core")
  expect(ENTRIES).toContain("early")
  for (const name of MODULES) expect(existsSync(builtPath(name))).toBe(true)
})

test("no minified build exists that the build script does not emit", () => {
  const built = readdirSync(srcDir, { recursive: true })
    .filter((file) => file.endsWith(".min.js"))
    .map((file) => file.slice(0, -".min.js".length))

  expect(built.sort()).toEqual([...MODULES].sort())
})

test("reports the gzipped size of every module", () => {
  const sizes = MODULES.map(sizeOf)
  const core = sizeOf("core")
  const bundle = sizeOf(BUNDLE)
  const row = ({ name, min, gzip }) => `  ${`${name}.min.js`.padEnd(32)} ${String(min).padStart(7)} B  ${String(gzip).padStart(6)} B gzip`
  // process.stdout, not console.log: other test files swap `console` for a stub.
  process.stdout.write(
    `${[
      "[phlex-reactive] client bundle sizes",
      ...sizes.map(row),
      `  default bundle (everything, one file): ${bundle.gzip} B gzip — ${bundle.gzip <= TARGET_BUNDLE_GZIP ? "target met" : `${bundle.gzip - TARGET_BUNDLE_GZIP} B over the ${TARGET_BUNDLE_GZIP} B target (ratchet ${BUNDLE_GZIP_CEILING})`}`,
      `  split total (core + ${FEATURES.length} features): ${splitTotal()} B gzip — ${splitTotal() - bundle.gzip} B more than the bundle`,
      `  split core target: ${TARGET_CORE_GZIP} B gzip — ${core.gzip <= TARGET_CORE_GZIP ? "met" : `${core.gzip - TARGET_CORE_GZIP} B over (ratchet ${CORE_GZIP_CEILING})`}`,
    ].join("\n")}\n`,
  )

  for (const { gzip } of sizes) expect(gzip).toBeGreaterThan(0)
})

test("early.min.js stays within its eager budget", () => {
  expect(sizeOf("early").gzip).toBeLessThanOrEqual(EARLY_GZIP_BUDGET)
})

test("the default bundle does not grow past its ratchet", () => {
  expectRatchet(sizeOf(BUNDLE).gzip, BUNDLE_GZIP_CEILING)
})

test("the split core does not grow past its ratchet", () => {
  expectRatchet(sizeOf("core").gzip, CORE_GZIP_CEILING)
})

test("the split core is smaller than the default bundle by at least what moved out", () => {
  // The point of the split: a page that uses no feature downloads less.
  // (12,203 B since issue #305 took the loader out of the bundle; 12,094 B
  // since #310 made the features smaller inside it.)
  expect(sizeOf(BUNDLE).gzip - sizeOf("core").gzip).toBeGreaterThan(12_000)
})

// Issue #305: the default entry is built with __SPLIT__ false, so nothing of
// the opt-in entry's loader may be in it — no import(), no feature table, no
// wait for a module. Each mark is checked against core.min.js too, so a mark
// that stops meaning anything fails here instead of passing vacuously.
const LOADER_MARKS = {
  "an import()": /\bimport\(/,
  "the feature table": /\["persist",\[/,
  "the loader's no-import fallback": /this entry has no way to import it/,
  "the feature import timeout": /phlex-reactive-feature-timeout/,
}

test("the default bundle carries no import() and no feature lookup table", () => {
  const bundle = readFileSync(builtPath(BUNDLE), "utf8")
  const core = readFileSync(builtPath("core"), "utf8")
  for (const [what, mark] of Object.entries(LOADER_MARKS)) {
    expect({ what, inCore: mark.test(core) }).toEqual({ what, inCore: true })
    expect({ what, inBundle: mark.test(bundle) }).toEqual({ what, inBundle: false })
  }
})

test("every feature module has a ceiling, and stays under it", () => {
  expect(Object.keys(FEATURE_GZIP_CEILINGS).sort()).toEqual([...FEATURES].sort())
  for (const name of FEATURES) expectRatchet(sizeOf(name).gzip, FEATURE_GZIP_CEILINGS[name])
})

test("the split core and its features together do not grow past their ratchet", () => {
  expectRatchet(splitTotal(), SPLIT_TOTAL_GZIP_CEILING)
})
