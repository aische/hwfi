---
name: workflows/audit
inputs:
  label: String
outputs:
  note: String
imports:
  - builtin/introspect
  - builtin/write-file
---

## flow

Non-cacheable observation steps (spec §8.1, A7).

```step
dump <- builtin/introspect()
_    <- builtin/write-file(path = "audit/introspection.json", text = "${dump.data}") @dumpfile
_    <- builtin/write-file(
  path = "audit/trace.txt",
  text = "run ${ctx.run.id} — trace so far:\n${ctx.trace}"
) @tracefile
return { note = "audited '${inputs.label}'" }
```
