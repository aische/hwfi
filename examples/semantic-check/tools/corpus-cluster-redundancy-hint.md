---
name: tools/corpus-cluster-redundancy-hint
inputs:
  cluster: types/corpus-cluster
outputs:
  findings: List<types/finding>
imports: []
---

## flow

Emit a redundancy finding for one similarity cluster.

```step
return {
  findings = [{
    severity = "warning",
    category = "redundancy",
    location = { file = "", section = "" },
    claim = "Multiple prose slices share substantial overlap",
    evidence = "score=${inputs.cluster.score}; members=${inputs.cluster.members}; span=${inputs.cluster.span}",
    suggestion = "Consolidate duplicated guidance or differentiate the sections"
  }]
}
```
