---
name: tools/speech-act-step-align
inputs:
  decl: types/declaration-summary
  step: types/step-summary
  tags: List<types/speech-act-tag>
outputs:
  hints: List<types/speech-act-hint>
imports:
  - tools/speech-act-agent-tool-hint
---

## flow

Speech-act alignment checks for one workflow step.

```step
pack <- tools/speech-act-agent-tool-hint(
  decl = ${inputs.decl},
  step = ${inputs.step},
  tags = ${inputs.tags}
) @align

return { hints = ${pack.hints} }
```
