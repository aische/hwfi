---
name: tools/pragmatic-review
inputs:
  items: List<types/review-gate-item>
  schema: Json
outputs:
  findings: List<types/finding>
imports:
  - builtin/list-concat
  - builtin/record-map
  - tools/pragmatic-review-one
---

## flow

Layer 3: run bounded pragmatic LLM review on gated slices.

```step
rows <- foreach item in ${inputs.items} {
  one <- tools/pragmatic-review-one(
    item = ${item},
    schema = ${inputs.schema}
  ) @one
  return { findings = ${one.findings} }
} @rows

layers <- builtin/record-map(items = ${rows}, field = "findings") @pick
flat <- builtin/list-concat(lists = ${layers.values}) @flat

return { findings = ${flat.items} }
```
