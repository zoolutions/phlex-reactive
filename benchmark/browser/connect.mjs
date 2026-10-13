// Browser bench: what a page pays to connect and disconnect reactive roots,
// measured in headless Chromium with the SHIPPED client (the minified bundle
// the dummy app vendors) and the real Stimulus. The happy-dom benches in
// benchmark/client/ are engine-relative: they showed a 5-10x connect
// "regression" that was mostly happy-dom's own cost, and missed a real
// quadratic (one window listener per guarded root) that only a browser's
// listener bookkeeping shows. This is the number to trust for connect.
//
//   rake bench:browser                                   # the vendored client
//   bun run benchmark/browser/connect.mjs <vendor dir>   # any build, e.g. main's
//
// Per shape and size it reports the median of 15 insert+connect runs and of
// 15 disconnects, and the cost of doubling N (2.0x is linear). Then a heap
// soak: 60 rounds of 500 roots mounted and unmounted, heap after a forced GC
// (it must stay flat).
import { chromium } from "playwright"
import { readFileSync, existsSync } from "node:fs"
import { join, resolve } from "node:path"

const vendor = resolve(process.argv[2] ?? "spec/dummy/public/vendor")
const SIZES = [500, 2000, 4000]
const SHAPES = {
  bare: "",
  guarded: 'data-reactive-warn-unsaved="true"',
  persisted: (i) => `data-reactive-persist='{"key":"k${i}","ttl":60,"debounce":300}'`,
}

const browser = await chromium.launch()
const page = await browser.newPage()
await page.route("http://bench.test/**", (route) => {
  const path = new URL(route.request().url()).pathname
  if (path === "/") {
    const imports = {
      "@hotwired/stimulus": "/vendor/stimulus.js",
      "phlex/reactive/reactive_controller": "/vendor/reactive_controller.js",
      "phlex/reactive/confirm": "/vendor/confirm.js",
      "phlex/reactive/confirm_predicate": "/vendor/confirm_predicate.js",
      "phlex/reactive/compute": "/vendor/compute.js",
    }
    return route.fulfill({
      contentType: "text/html",
      body: `<!doctype html><html><head><script type="importmap">${JSON.stringify({ imports })}</script></head><body><div id="host"></div></body></html>`,
    })
  }
  const file = join(vendor, path.replace(/^\/vendor\//, ""))
  if (!existsSync(file)) return route.fulfill({ status: 404, body: "" })
  return route.fulfill({ contentType: "text/javascript", body: readFileSync(file) })
})
await page.goto("http://bench.test/")
const cdp = await page.context().newCDPSession(page)

// A subclass counts connects, so the bench works on a client that predates
// the reactive:connect event.
await page.evaluate(async () => {
  const { Application } = await import("@hotwired/stimulus")
  const { default: Reactive } = await import("phlex/reactive/reactive_controller")
  window.connected = 0
  Application.start().register(
    "reactive",
    class extends Reactive {
      connect() {
        super.connect()
        window.connected++
      }
    },
  )
  window.settle = () => new Promise((done) => setTimeout(done, 0))
  window.untilConnected = (target) =>
    new Promise((done) => {
      const check = () => (window.connected >= target ? done() : setTimeout(check, 0))
      check()
    })
})

const markup = (shape, n, start) =>
  Array.from({ length: n }, (_, k) => {
    const i = start + k
    const extra = typeof SHAPES[shape] === "function" ? SHAPES[shape](i) : SHAPES[shape]
    return (
      `<div id="r${i}" data-controller="reactive" data-reactive-token-value="T" ${extra}>` +
      `<input name="a" data-action="input->reactive#trackDirty"><input name="b">` +
      `<button data-action="click->reactive#dispatch" data-reactive-action-param="go"></button></div>`
    )
  }).join("")

const median = (values) => values.sort((a, b) => a - b)[values.length >> 1]
let serial = 0

async function cycle(shape, n) {
  const html = markup(shape, n, (serial += n))
  return page.evaluate(
    async ([html, n]) => {
      const host = document.getElementById("host")
      const target = window.connected + n
      let t = performance.now()
      host.innerHTML = html
      await window.untilConnected(target)
      const connect = performance.now() - t
      t = performance.now()
      host.innerHTML = ""
      await window.settle()
      return [connect, performance.now() - t]
    },
    [html, n],
  )
}

for (const shape of Object.keys(SHAPES)) {
  const connects = {}
  for (const n of SIZES) {
    await cycle(shape, n) // warm
    const runs = []
    for (let k = 0; k < 15; k++) runs.push(await cycle(shape, n))
    connects[n] = median(runs.map((r) => r[0]))
    const disconnect = median(runs.map((r) => r[1]))
    console.log(`${shape.padEnd(10)} ${String(n).padStart(5)} roots  connect ${connects[n].toFixed(1).padStart(6)} ms  disconnect ${disconnect.toFixed(1).padStart(6)} ms`)
  }
  console.log(`${shape.padEnd(10)} doubling 2000 -> 4000 costs ${(connects[4000] / connects[2000]).toFixed(2)}x (2.00x is linear)`)
}

const heap = async () => {
  await cdp.send("HeapProfiler.collectGarbage")
  await cdp.send("HeapProfiler.collectGarbage")
  return (await cdp.send("Runtime.getHeapUsage")).usedSize
}
for (let k = 0; k < 3; k++) await cycle("guarded", 500)
const base = await heap()
const points = []
for (let round = 1; round <= 60; round++) {
  await cycle(round % 2 ? "guarded" : "persisted", 500)
  if (round % 20 === 0) points.push(`${(((await heap()) - base) / 1024).toFixed(0)} KB`)
}
console.log(`heap after 20/40/60 rounds of 500 roots mounted and unmounted: ${points.join(" / ")} (must stay flat)`)

await browser.close()
