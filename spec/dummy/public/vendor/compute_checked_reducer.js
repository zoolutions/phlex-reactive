// The reducer for the checked-state compute repro (issue #262). `gift` is
// untyped (1/0), `express` is :boolean, `shipping` is :string (the checked
// radio's value). `readings` prints the typeof + value of each as the reducer
// RECEIVED it, so the spec pins the coercion itself, not just its arithmetic.
// `free_shipping` (a checkbox) and `tier` (a radio group) are OUTPUTS: the
// client writes their checked state, never their value attribute.
import { setComputeReducer } from "phlex/reactive/compute"

const RATES = { pickup: 0, post: 10, courier: 30 }

export function registerComputeChecked() {
  setComputeReducer("checked_total", ({ price, gift, express, shipping }) => {
    const total = price + (gift === 1 ? 25 : 0) + (express === true ? 50 : 0) + (RATES[shipping] ?? 0)
    const readings = [gift, express, shipping].map((v) => `${typeof v}:${v}`).join(" ")
    return { total, free_shipping: total >= 200, tier: total >= 200 ? "plus" : "basic", readings }
  })
}
