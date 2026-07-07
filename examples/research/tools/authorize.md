---
name: tools/authorize
inputs:
  token: Secret<String>
outputs:
  ok: String
---

## flow

Gate the pipeline on a secret token (spec §5.5). The token arrives as
`Secret<String>` because its source binding (`ctx.env.RESEARCH_API_TOKEN`) matches
the secret-name patterns and is auto-wrapped by the engine.

A `Secret<_>` value may only be passed to another `Secret<_>` parameter; it can
never be interpolated into a plain string, so it cannot leak. When this step's
`step-start` event is written to `trace.jsonl`, the `token` argument is redacted
as `<secret:RESEARCH_API_TOKEN>` (spec §8.3.4, A8). Inspect the trace with
`hwfi show` to confirm the cleartext token never appears.

```step
return { ok = "authorized" }
```
