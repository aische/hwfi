---
name: workflows/a
imports:
  - workflows/b
---

## flow

```step
_ <- workflows/b() @callB
```
