---
name: tools/hit-nonempty
inputs:
  items: List<types/hit-row>
outputs:
  item: types/hit-row
imports: []
---

## flow

Return the first hit row or fail catchably when the list is empty.

```step
return { item = ${inputs.items[0]} }
```
