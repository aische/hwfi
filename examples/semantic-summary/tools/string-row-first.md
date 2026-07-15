---
name: tools/string-row-first
inputs:
  items: List<types/string-row>
outputs:
  item: types/string-row
imports: []
---

## flow

Return the first string row or fail catchably when the list is empty.

```step
return { item = ${inputs.items[0]} }
```
