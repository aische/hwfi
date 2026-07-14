---
name: tools/spread-finding
inputs:
  finding: types/finding
outputs:
  severity: String
  category: String
  location: types/location
  claim: String
  evidence: String
  suggestion: String
imports: []
---

## flow

Re-export a finding record so `foreach` bodies can yield `types/finding` fields
as the iteration value (nested-loop flattening helper).

```step
return {
  severity = ${inputs.finding.severity},
  category = ${inputs.finding.category},
  location = ${inputs.finding.location},
  claim = ${inputs.finding.claim},
  evidence = ${inputs.finding.evidence},
  suggestion = ${inputs.finding.suggestion}
}
```
