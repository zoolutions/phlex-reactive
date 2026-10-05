// Micro-bench: connect() — what every reactive root pays once, when Stimulus
// connects it (a page load, a Turbo visit, a plain replace). It is the one
// place the feature modules (issue #275) add per-root work: each feature's
// marker check runs for every root, whether or not the root uses the feature.
//
// Each iteration connects and then disconnects 2,000 roots (disconnect is the
// teardown the next iteration needs; it is part of the number). Shapes:
//
//   bare root            a token and an id, nothing else — a counter, a row
//   5-field form         the same, with five owned inputs
//   dirty-tracked form   a 5-field form with track_dirty + warn_unsaved — a
//                        root that USES a feature, to keep that path honest
//
// The harness imports phlex/reactive/reactive_controller — the default entry,
// where every feature is already registered, so nothing is imported on demand.
//
// happy-dom numbers are ENGINE-RELATIVE (see the docs performance page): a valid
// same-machine before/after delta, NOT an absolute browser cost.

import { bench, group } from "mitata"
import { makeDom, buildController } from "./support/harness.js"

const ROOTS = 2000
const { document } = await makeDom()
globalThis.document = document
globalThis.window = document.defaultView
globalThis.navigator = { onLine: true }

function buildRoots(shape) {
  const controllers = []
  for (let i = 0; i < ROOTS; i++) {
    const root = document.createElement("div")
    root.id = `${shape}-${i}`
    root.setAttribute("data-controller", "reactive")
    root.setAttribute("data-reactive-token-value", "TOKEN")
    if (shape !== "bare") {
      for (let f = 0; f < 5; f++) {
        const input = document.createElement("input")
        input.setAttribute("type", "text")
        input.setAttribute("name", `f${f}`)
        if (shape === "dirty") input.setAttribute("data-action", "input->reactive#trackDirty")
        root.appendChild(input)
      }
    }
    if (shape === "dirty") root.setAttribute("data-reactive-warn-unsaved", "true")
    document.body.appendChild(root)
    controllers.push(buildController(root, "TOKEN"))
  }
  return controllers
}

function cycle(controllers) {
  for (const controller of controllers) controller.connect()
  for (const controller of controllers) controller.disconnect()
}

const bare = buildRoots("bare")
const form = buildRoots("form")
const dirty = buildRoots("dirty")

group(`connect + disconnect, ${ROOTS} roots`, () => {
  bench("2,000 bare roots", () => cycle(bare))
  bench("2,000 5-field forms", () => cycle(form))
  bench("2,000 dirty-tracked 5-field forms", () => cycle(dirty))
})
