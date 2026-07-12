---
name: tools/search
inputs:
  q: String
outputs:
  text: String
---

```step
return { text = "search: ${inputs.q}" }
```
