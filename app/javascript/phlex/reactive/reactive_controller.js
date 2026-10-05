// phlex/reactive/reactive_controller — the DEFAULT client: ONE file with the
// whole runtime in it. This is what `import ReactiveController from
// "phlex/reactive/reactive_controller"` has always given an app, and what the
// install generator wires up.
//
// The client's source is a shared runtime (runtime.js: the controller) plus
// feature modules (features/*.js, issue #275). This entry imports all of them
// STATICALLY and hands each feature to the runtime before the controller can
// connect anything, so:
//
//   * nothing is imported on demand — no request for a feature, ever;
//   * every feature a root needs connects inside connect(), in the same task,
//     in table order — a draft is restored there, a lazy shell armed there;
//   * `featuresReady` is already resolved, no request waits for a feature,
//     and the import timeout can never fire.
//
// In short: it behaves as the client did before it was split. The shipped
// reactive_controller.min.js is this module BUNDLED with the runtime and the
// features (scripts/build_client.js). It contains no import() at all: the
// table of where each feature module lives belongs to the other entry. The seams an app may override stay
// separate modules, imported by their bare names exactly as before:
// phlex/reactive/confirm, phlex/reactive/confirm_predicate, phlex/reactive/compute.
//
// The opt-in alternative is phlex/reactive/core (core.js): the same runtime
// without the features, which it then imports when a root on the page needs one. An
// app imports ONE of the two, never both — each carries its own copy of the
// runtime's state, and the second to load says so in the console.
import ReactiveController, { registerReactiveDev, registerReactiveFeature } from "phlex/reactive/runtime"
import * as persist from "phlex/reactive/features/persist"
import * as defer from "phlex/reactive/features/defer"
import * as form from "phlex/reactive/features/form"
import * as effects from "phlex/reactive/features/effects"
import * as dev from "phlex/reactive/features/dev"

// Table order is the runtime's (persist first); this only supplies the
// features — for each, a plain object of exactly what the runtime calls, so
// the bundler can drop the rest of the module's exports (and the module
// namespace object itself).
registerReactiveFeature("persist", { install: persist.install, connect: persist.connect, disconnect: persist.disconnect, abandon: persist.abandon, writeState: persist.writeState, clearRoot: persist.clearRoot })
registerReactiveFeature("defer", { install: defer.install, connect: defer.connect, disconnect: defer.disconnect, streamAction: defer.streamAction, materialize: defer.materialize })
registerReactiveFeature("form", { connect: form.connect, disconnect: form.disconnect, scan: form.scan })
registerReactiveFeature("effects", { wrap: effects.wrap, sweep: effects.sweep })
registerReactiveFeature("dev", { attach: dev.attach, delay: dev.delay })
// The runtime registered with Turbo while it was being evaluated, before the
// dev module was handed over: give a development page its console handle now, in
// this task, as it always was.
registerReactiveDev()

export * from "phlex/reactive/runtime"
// The latency simulator's named exports (issue #102), where they have always
// been importable from. With phlex/reactive/core, import them from
// phlex/reactive/features/dev.
export { enableLatencySim, disableLatencySim, LATENCY_KEY } from "phlex/reactive/features/dev"
export default ReactiveController
