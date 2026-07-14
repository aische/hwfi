---
name: tools/list-has-second
inputs:
  items: List<types/corpus-slice>
outputs:
  item: types/corpus-slice
imports: []
---

## flow

Fail catchably when the list has fewer than two elements.

```step
return { item = ${inputs.items[1]} }
```
