---
name: tools/mode-is-exploratory
inputs:
  mode: String
outputs:
  exploratory: Bool
imports:
  - tools/strings-equal
---

## flow

True when review mode enables layer 3 LLM pragmatics.

```step
probe <- tools/strings-equal(
  left = ${inputs.mode},
  right = "exploratory"
) @probe

return { exploratory = ${probe.equal} }
```
