---
name: tools/prose-hint-finding
inputs:
  file: String
  line: Int
  text: String
outputs:
  finding: types/finding
imports: []
---

## flow

Convert one grep hit into a layer 1 prose hint finding.

```step
return {
  finding = {
    severity = "info",
    category = "dead_reference",
    location = { file = ${inputs.file}, section = "" },
    claim = "Prose or step block mentions a qname-like token",
    evidence = ${inputs.text},
    suggestion = "Confirm the mention resolves; replace grep hints with resolve-qnames-in-text when available"
  }
}
```
