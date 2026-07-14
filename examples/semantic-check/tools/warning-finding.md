---
name: tools/warning-finding
inputs:
  message: String
outputs:
  finding: types/finding
imports: []
---

## flow

Convert a structural check warning string into a layer 0 finding.

```step
return {
  finding = {
    severity = "warning",
    category = "policy",
    location = { file = "", section = "" },
    claim = "Project check warning",
    evidence = ${inputs.message},
    suggestion = "Review the warning text"
  }
}
```
