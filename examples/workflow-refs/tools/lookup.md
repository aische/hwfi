---
name: tools/lookup
inputs:
  q: String
outputs:
  text: String
---

```step
return { text = "lookup: ${inputs.q}" }
```
