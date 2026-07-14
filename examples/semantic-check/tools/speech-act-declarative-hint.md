---
name: tools/speech-act-declarative-hint
inputs:
  tag: types/speech-act-tag
outputs:
  hints: List<types/speech-act-hint>
imports:
  - tools/empty-speech-act-hints
  - tools/strings-equal
---

## flow

Flag declarative role-assignment language in agent-facing prose.

```step
force <- tools/strings-equal(
  left = ${inputs.tag.force},
  right = "declarative"
) @force_chk

pack <- if ${force.equal} {
  return {
    hints = [{
      severity = "info",
      category = "policy",
      location = ${inputs.tag.location},
      claim = "Agent section uses declarative role assignment language",
      evidence = ${inputs.tag.sentence},
      suggestion = "Confirm the role assignment is allowed by workflow policy and matches step metadata",
      force = "declarative",
      step_id = ""
    }]
  }
} else {
  empty <- tools/empty-speech-act-hints() @skip
  return { hints = ${empty.hints} }
} @branch

return { hints = ${pack.hints} }
```
