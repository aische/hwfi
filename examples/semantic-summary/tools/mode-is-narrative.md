---
name: tools/mode-is-narrative
inputs:
  mode: String
outputs:
  narrative: Bool
imports:
  - builtin/record-filter
  - tools/hit-nonempty
---

## flow

True when summary mode enables LLM narrative synthesis.

```step
hits <- builtin/record-filter(
  items = [{ mode = ${inputs.mode} }],
  where = { mode = "narrative" }
) @probe

rows <- foreach row in ${hits.items} {
  return { hit = "yes" }
} @rows

pack <- try {
  _ <- tools/hit-nonempty(items = ${rows}) @hit
  return { narrative = true }
} catch {
  return { narrative = false }
} @branch

return { narrative = ${pack.narrative} }
```
