---
name: workflows/main
inputs:
  q: String
outputs:
  text: String
imports:
  - tools/search
---

```step
r <- search(q = ${inputs.q})
return { text = ${r.text} }
```
