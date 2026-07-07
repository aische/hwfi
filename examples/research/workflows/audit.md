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

Write an audit trail for the run. Both observing steps are **non-cacheable** and
are therefore always re-executed on `hwfi resume` (spec §8.1, §8.2, A7):

- `builtin/introspect` returns a JSON dump of everything the runtime knows about
  the current run (bindings, workspace, full trace), which forces the step
  non-cacheable.
- The `trace.txt` step references the volatile `${ctx.trace}` field, which also
  forces its step non-cacheable. Interpolating `ctx.trace` renders the whole
  event list as canonical JSON (spec §3.2.1); `ctx.run.id` renders as a string.

```step
dump <- builtin/introspect()
_    <- builtin/write-file(path = "audit/introspection.json", text = "${dump.data}") @dumpfile
_    <- builtin/write-file(
  path = "audit/trace.txt",
  text = "run ${ctx.run.id} — trace so far:\n${ctx.trace}"
) @tracefile
return { note = "audited '${inputs.label}'" }
```
