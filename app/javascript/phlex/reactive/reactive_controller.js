// phlex/reactive/reactive_controller — the DEFAULT client: ONE file with the
// whole runtime in it. This is what `import ReactiveController from
// "phlex/reactive/reactive_controller"` has always given an app, and what the
// install generator wires up.
//
// The runtime's source is a core (core.js) plus feature modules (features/*.js,
// issue #275). This entry imports all of them STATICALLY and hands each
// feature to the core before the controller can connect anything, so:
//
//   * nothing is imported on demand — no request for a feature, ever;
//   * every feature a root needs connects inside connect(), in the same task,
//     in table order — a draft is restored there, a lazy shell armed there;
//   * `featuresReady` is already resolved, no request waits for a feature,
//     and the import timeout can never fire.
//
// In short: it behaves as the client did before it was split. The shipped
// reactive_controller.min.js is this module BUNDLED with the core and the
// features (scripts/build_client.js). The seams an app may override stay
// separate modules, imported by their bare names exactly as before:
// phlex/reactive/confirm, phlex/reactive/confirm_predicate, phlex/reactive/compute.
//
// The opt-in alternative is phlex/reactive/core: the same controller without
// the features, which it then imports when a root on the page needs one. An
// app imports ONE of the two, never both — each carries its own copy of the
// runtime's state, and the second to load says so in the console.
import ReactiveController, { registerReactiveFeature } from "phlex/reactive/core"
import * as persist from "phlex/reactive/features/persist"
import * as defer from "phlex/reactive/features/defer"

// Table order is the core's (persist first); this only supplies the modules.
registerReactiveFeature("persist", persist)
registerReactiveFeature("defer", defer)

export * from "phlex/reactive/core"
export default ReactiveController
