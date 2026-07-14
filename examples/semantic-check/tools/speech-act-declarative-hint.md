---
name: tools/speech-act-declarative-hint
inputs:
  tag: types/speech-act-tag
outputs:
  hints: List<types/speech-act-hint>
imports:
  - builtin/record-filter
  - tools/empty-speech-act-hints
  - tools/hit-nonempty
---

## flow

Flag declarative role-assignment language in agent-facing prose.

```step
declaratives <- builtin/record-filter(
  items = [${inputs.tag}],
  where = { force = "declarative" }
) @declaratives

pack <- try {
  rows <- foreach tag in ${declaratives.items} {
    return { hit = "yes" }
  } @rows

  _ <- tools/hit-nonempty(items = ${rows}) @force_hit

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
} catch {
  empty <- tools/empty-speech-act-hints() @skip
  return { hints = ${empty.hints} }
} @branch

return { hints = ${pack.hints} }
```
