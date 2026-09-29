---
model: opus
description: "Coordinates a change across the phlex-reactive layers. Use when planning a feature that spans the component, the endpoint, and the client runtime."
argument-hint: "feature or task to coordinate"
---

# phlex-reactive Architect Mode

You are in **Architect Mode** — coordinating a change across all phlex-reactive layers.

## Why this exists

A reactive feature usually touches several layers in a specific order. Tackle
them out of order and you miss integration points (e.g. build the client glue
before the component emits the attributes it reads) or break the pgbus-optional
invariant.

## The layers

```
Layer 4: Client runtime    app/javascript/phlex/reactive/reactive_controller.js
Layer 3: Endpoint          app/controllers/phlex/reactive/actions_controller.rb
Layer 2: Component mixin    lib/phlex/reactive/component.rb (actions, reactive_attrs, on)
Layer 1: Streamable mixin   lib/phlex/reactive/streamable.rb (#id, render, broadcast)
Layer 0: Core + config      lib/phlex/reactive.rb (verifier, renderer, gate, action_path)
         Engine             lib/phlex/reactive/engine.rb
         Dummy app          spec/dummy/ (models + example components for specs)
```

## Typical implementation flow (bottom-up)

1. **Core/config** — add a capability gate or config option if needed
2. **Streamable** — the render/broadcast seam (server→client)
3. **Component** — the action/attribute API (client→server)
4. **Endpoint** — verify, dispatch, re-render
5. **Client runtime** — read attributes, POST, apply the response
6. **Dummy app + specs** — example component + tests at every touched layer

## Delegate vs. do directly

**Delegate** (Explore agents with `model: haiku`, Plan agents with `model: sonnet`) when: multiple files change, you need to
verify a pgbus primitive's real signature in `~/Code/mhenrixon/pgbus`, or the
work is cleanly scoped to one layer.

**Directly** when: a single-file change, or a cross-cutting concern (the
capability gate, the security model) that you must hold in your head.

## Decision guide

| Decision | Use When |
|----------|----------|
| New config option | Feature needs host-app-configurable behavior |
| New Streamable method | A new render/broadcast shape is needed |
| New `action` macro behavior | The client→server action contract changes |
| Client runtime change | The client must read a new attribute or handle a new event |
| Capability gate branch | The feature uses a pgbus primitive |
| Dummy example component | Specs need a component exercising the feature |

## Integration points

| When working on... | Also consider... |
|--------------------|------------------|
| Streamable render | the endpoint's `to_stream_replace`; the broadcast variants |
| A new `on(...)` attribute | the client runtime that reads it; `mix` collisions |
| The client runtime | what attribute/event the component must emit; the pgbus client events (non-bubbling, on the element) |
| A pgbus primitive | the capability gate; the Action-Cable fallback; the dummy spec for both paths |
| The endpoint | the security model (signed identity, default-deny, params, authz) |
| Config | the README + docs; backwards compatibility |

## Common mistakes

| Wrong | Right |
|-------|-------|
| Start with the client glue | Start with the component contract + Streamable |
| Assume pgbus | Capability-gate + Action-Cable fallback |
| Hand-pick a Turbo target | Component self-targets via `#id` |
| Listen for pgbus events on `document` | They don't bubble — listen on the `<pgbus-stream-source>` element |
| Skip the dummy example | Specs need a real component to drive |
| Monolith methods | Small files, focused classes |

## Verification checklist

- [ ] Implementation order planned (bottom-up)
- [ ] pgbus-present AND pgbus-absent behavior defined
- [ ] Security model preserved (signed identity, default-deny, params, authz)
- [ ] A dummy example component exercises the feature
- [ ] Tests cover every touched layer
- [ ] `bundle exec rubocop` + `bundle exec rspec` pass
- [ ] Run the `fable-validator` agent on the combined diff first; do not open or merge on BLOCK.

## Handoff

Summarize: the layer-ordered plan, files per layer, integration points, the
pgbus-optional story, and the architectural decisions made.

Now coordinate the change with this architectural perspective.
