---
name: tools/pragmatic-review-gate-json
inputs:
  items: List<Json>
  schema: Json
outputs:
  findings: List<types/finding>
imports:
  - builtin/list-concat
  - builtin/record-map
  - tools/pragmatic-review-one-json
---

## flow

Run bounded pragmatic LLM review on `review_gate` items from a prior check report.

```step
rows <- foreach item in ${inputs.items} {
  one <- tools/pragmatic-review-one-json(
    item = ${item},
    schema = ${inputs.schema}
  ) @one
  return { findings = ${one.findings} }
} @rows

layers <- builtin/record-map(items = ${rows}, field = "findings") @pick
flat <- builtin/list-concat(lists = ${layers.values}) @flat

return { findings = ${flat.items} }
```
