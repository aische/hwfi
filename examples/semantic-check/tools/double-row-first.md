---
name: tools/double-row-first
inputs:
  items: List<types/double-row>
outputs:
  item: types/double-row
imports: []
---

## flow

Return the first row or fail when the list is empty.

```step
return { item = ${inputs.items[0]} }
```
