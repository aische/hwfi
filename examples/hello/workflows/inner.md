---
name: workflows/inner
inputs:
  note: String
outputs:
  ok: String
imports:
  - builtin/write-file
---

## flow

A sub-workflow that writes a marker file. Called from `workflows/main` to
exercise sub-workflow calls and nested trace events.

```step
_ <- builtin/write-file(path = "inner.txt", text = ${inputs.note}) @w
return { ok = "done" }
```
