---
name: tools/search
inputs:
  query: String
outputs:
  hits: List<String>
---

## flow

```step
return { hits = ["stub result for ${inputs.query}"] }
```
