---
name: workflows/b
imports:
  - workflows/a
---

## flow

```step
_ <- workflows/a() @callA
```
