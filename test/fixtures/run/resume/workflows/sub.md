---
name: workflows/sub
inputs:
  note: String
outputs:
  marker: String
imports:
  - builtin/write-file
---

## flow

A sub-workflow called as a cacheable step by `workflows/main`. Editing this file
changes its fingerprint and therefore the caller's step-key (A13).

```step
_ <- builtin/write-file(path = "sub-marker.txt", text = ${inputs.note}) @w
return { marker = "SUB:${inputs.note}" }
```
