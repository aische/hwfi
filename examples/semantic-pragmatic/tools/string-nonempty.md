---
name: tools/string-nonempty
inputs:
  items: List<String>
outputs:
  item: String
imports: []
---

## flow

Return the first string or fail catchably when the list is empty.

```step
return { item = ${inputs.items[0]} }
```
