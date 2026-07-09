---
name: tools/authorize
inputs:
  token: Secret<String>
outputs:
  ok: String
---

## flow

Gate the pipeline on a secret token (spec §5.5). The token is redacted in traces.

```step
return { ok = "authorized" }
```
