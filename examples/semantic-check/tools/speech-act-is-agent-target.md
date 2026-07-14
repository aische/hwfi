---
name: tools/speech-act-is-agent-target
inputs:
  target: String
outputs:
  ok: Bool
imports:
  - builtin/record-filter
  - tools/hit-nonempty
---

## flow

True when the step target is an LLM agent builtin.

```step
hits <- builtin/record-filter(
  items = [
    { name = "builtin/llm-agent" },
    { name = "builtin/llm-agent-object" }
  ],
  field = "name",
  equals = ${inputs.target}
) @filter

rows <- foreach row in ${hits.items} {
  return { hit = "yes" }
} @rows

pack <- try {
  _ <- tools/hit-nonempty(items = ${rows}) @probe
  return { ok = true }
} catch {
  return { ok = false }
} @branch

return { ok = ${pack.ok} }
```
