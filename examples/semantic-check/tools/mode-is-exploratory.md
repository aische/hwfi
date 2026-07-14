---
name: tools/mode-is-exploratory
inputs:
  mode: String
outputs:
  exploratory: Bool
imports:
  - builtin/record-filter
  - tools/hit-nonempty
---

## flow

True when review mode enables layer 3 LLM pragmatics.

```step
hits <- builtin/record-filter(
  items = [{ mode = ${inputs.mode} }],
  where = { mode = "exploratory" }
) @probe

rows <- foreach row in ${hits.items} {
  return { hit = "yes" }
} @rows

pack <- try {
  _ <- tools/hit-nonempty(items = ${rows}) @hit
  return { exploratory = true }
} catch {
  return { exploratory = false }
} @branch

return { exploratory = ${pack.exploratory} }
```
