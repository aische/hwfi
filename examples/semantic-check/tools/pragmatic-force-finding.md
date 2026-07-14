---
name: tools/pragmatic-force-finding
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

Emit an info finding documenting illocutionary force classification.

```step
pack <- try {
  got <- builtin/json-get(json = ${inputs.value}, path = "illocutionary_force") @got

  inner <- try {
    return {
      findings = [{
        severity = "info",
        category = "policy",
        location = ${inputs.location},
        claim = "Dominant illocutionary force in flagged slice",
        evidence = "illocutionary_force=${got.value}",
        suggestion = "Confirm force matches the step role (directive for agents, assertive for facts)"
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
