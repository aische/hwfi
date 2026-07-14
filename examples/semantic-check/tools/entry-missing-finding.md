---
name: tools/entry-missing-finding
inputs:
  entry: String
outputs:
  findings: List<types/finding>
imports: []
---

## flow

Finding list when the requested entrypoint qname is absent from the project.

```step
return {
  findings = [{
    severity = "error",
    category = "coverage_gap",
    location = { file = "project.json", section = "entrypoint" },
    claim = "Entrypoint qname is not declared in the target project",
    evidence = ${inputs.entry},
    suggestion = "Set project.json entrypoint to an existing workflow qname"
  }]
}
```
