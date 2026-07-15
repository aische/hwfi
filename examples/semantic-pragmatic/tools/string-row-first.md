---
name: tools/string-row-first
inputs:
  items: List<types/string-row>
outputs:
  item: types/string-row
imports: []
---

## flow

Return the first row or fail when the list is empty.

```step
return { item = ${inputs.items[0]} }
```
