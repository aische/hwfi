---
name: tools/nonempty
inputs:
  items: List<types/catalog-entry>
outputs:
  item: types/catalog-entry
imports: []
---

## flow

Return the first row or fail catchably when the list is empty.

```step
return { item = ${inputs.items[0]} }
```
