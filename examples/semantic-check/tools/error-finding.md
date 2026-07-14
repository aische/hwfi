---
name: tools/error-finding
inputs:
  message: String
outputs:
  finding: types/finding
imports: []
---

## flow

Convert a structural check error string into a layer 0 finding.

```step
return {
  finding = {
    severity = "error",
    category = "policy",
    location = { file = "", section = "" },
    claim = "Project failed structural type check",
    evidence = ${inputs.message},
    suggestion = "Fix the parse or type error reported by hwfi check"
  }
}
```
