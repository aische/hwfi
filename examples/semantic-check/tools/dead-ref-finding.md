---
name: tools/dead-ref-finding
inputs:
  file: String
  section: String
  claim: String
  evidence: String
  suggestion: String
outputs:
  findings: List<types/finding>
imports: []
---

## flow

Wrap a single dead-reference finding as a one-element list.

```step
return {
  findings = [{
    severity = "warning",
    category = "dead_reference",
    location = { file = ${inputs.file}, section = ${inputs.section} },
    claim = ${inputs.claim},
    evidence = ${inputs.evidence},
    suggestion = ${inputs.suggestion}
  }]
}
```
