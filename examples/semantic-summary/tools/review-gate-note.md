---
name: tools/review-gate-note
inputs:
  report: Json
outputs:
  text: String
imports:
  - tools/hit-nonempty
  - tools/json-values-or-empty
---

## flow

Describe whether `review_gate` items are present for optional pragmatic review.

```step
gate <- tools/json-values-or-empty(
  json = ${inputs.report},
  path = "review_gate"
) @gate

rows <- foreach item in ${gate.values} {
  return { hit = "yes" }
} @rows

pack <- try {
  _ <- tools/hit-nonempty(items = ${rows}) @hit
  return { text = "populated (run semantic-pragmatic for LLM review)" }
} catch {
  return { text = "none (no high-signal gated slices)" }
} @probe

return { text = ${pack.text} }
```
