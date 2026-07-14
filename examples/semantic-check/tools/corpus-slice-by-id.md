---
name: tools/corpus-slice-by-id
inputs:
  id: String
  slices: List<types/corpus-slice>
outputs:
  slice: types/corpus-slice
imports:
  - builtin/record-filter
---

## flow

Look up one corpus slice by its stable id.

```step
hits <- builtin/record-filter(
  items = ${inputs.slices},
  field = "id",
  equals = ${inputs.id}
) @hits

return { slice = ${hits.items[0]} }
```
