---
name: tools/catalog-row
inputs:
  qname: String
outputs:
  row: types/catalog-entry
imports: []
---

## flow

Wrap one qname as a catalog row for `foreach` iteration.

```step
return { row = { qname = ${inputs.qname} } }
```
