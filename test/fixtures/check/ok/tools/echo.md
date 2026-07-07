---
name: tools/echo
inputs:
  m: types/message
outputs:
  out: String
---

## flow

Echo a message's content back out. Exercises a shared type alias (§2.1).

```step
return { out = ${inputs.m.content} }
```
