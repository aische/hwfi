---
name: tools/review-gate-dedupe-cap
inputs:
  items: List<types/review-gate-item>
outputs:
  items: List<types/review-gate-item>
imports:
  - builtin/list-unique-by
---

## flow

Deduplicate gate candidates by slice id, then cap at eight items.

```step
capped <- builtin/list-unique-by(
  items = ${inputs.items},
  fields = ["slice_id"],
  limit = 8
) @cap

return { items = ${capped.items} }
```
