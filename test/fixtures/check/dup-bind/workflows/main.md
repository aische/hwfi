---
name: workflows/main
inputs:
  path: FileRef
outputs:
  text: String
---

## flow

```step
c <- builtin/read-file(path = ${inputs.path})
c <- builtin/read-file(path = ${inputs.path}) @c2
return { text = ${c.text} }
```
