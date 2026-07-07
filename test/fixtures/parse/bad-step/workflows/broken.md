---
name: workflows/broken
inputs:
  path: FileRef
outputs:
  text: String
---

## flow

```step
contents <- builtin/read-file(path = ${inputs.path)
```
