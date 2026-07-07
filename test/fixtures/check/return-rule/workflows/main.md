---
name: workflows/main
inputs:
  path: FileRef
outputs:
  summary: String
---

## flow

```step
c <- builtin/read-file(path = ${inputs.path})
```
