---
name: workflows/inspect
inputs:
  topic: String
outputs:
  data: Json
imports:
  - builtin/introspect
---

## flow

```step
d <- builtin/introspect()
return { data = ${d.data} }
```
