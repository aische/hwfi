---
name: tools/privileged
inputs:
  token: Secret<String>
outputs:
  ok: Bool
---

## flow

```step
_ <- builtin/write-file(path = "marker.txt", text = "ran") @w
return { ok = true }
```
