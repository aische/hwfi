---
name: workflows/main
inputs:
  path: FileRef
outputs:
  out: String
---

## flow

```step
c <- builtin/read-file(path = ${nope})
return { out = ${c.text} }
```
