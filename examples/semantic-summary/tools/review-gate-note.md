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

Describe whether layer 3 `review_gate` is populated.

```step
gate <- tools/json-values-or-empty(
  json = ${inputs.report},
  path = "review_gate"
) @gate

rows <- foreach slice_id in ${gate.values} {
  return { hit = "yes" }
} @rows

pack <- try {
  _ <- tools/hit-nonempty(items = ${rows}) @hit
  return { text = "populated (exploratory layer 3)" }
} catch {
  return { text = "none (strict or no gated slices)" }
} @probe

return { text = ${pack.text} }
```
