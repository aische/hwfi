---
name: tools/pragmatic-clarity-finding
inputs:
  value: Json
  location: types/location
outputs:
  findings: List<types/finding>
imports:
  - builtin/json-get
  - tools/empty-findings
---

## flow

Emit an info finding documenting the LLM clarity score.

```step
pack <- try {
  got <- builtin/json-get(json = ${inputs.value}, path = "clarity_score") @got

  inner <- try {
    return {
      findings = [{
        severity = "info",
        category = "ambiguity",
        location = ${inputs.location},
        claim = "LLM clarity score for flagged slice",
        evidence = "clarity_score=${got.value}",
        suggestion = "Scores below 0.6 often indicate vague directives worth rewriting"
      }]
    }
  } catch {
    empty <- tools/empty-findings() @skip
    return { findings = ${empty.findings} }
  } @probe

  return { findings = ${inner.findings} }
} catch {
  empty <- tools/empty-findings() @skip
  return { findings = ${empty.findings} }
} @probe

return { findings = ${pack.findings} }
```
