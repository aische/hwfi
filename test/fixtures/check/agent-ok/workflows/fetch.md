---
name: workflows/fetch
inputs:
  url: String
outputs:
  body: String
---

## flow

```step
return { body = "fetched ${inputs.url}" }
```
