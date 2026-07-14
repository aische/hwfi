---
name: tools/corpus-cluster-divergence-hint
inputs:
  left_id: String
  right_id: String
  cluster: types/corpus-cluster
  slices: List<types/corpus-slice>
outputs:
  findings: List<types/finding>
imports:
  - tools/corpus-slice-by-id
  - tools/doubles-equal
  - tools/empty-findings
  - tools/strings-equal
---

## flow

When two cluster members have divergent entropy, flag a layer-3 review candidate.

```step
same <- tools/strings-equal(
  left = ${inputs.left_id},
  right = ${inputs.right_id}
) @same

result <- if ${same.equal} {
  empty <- tools/empty-findings() @none
  return { findings = ${empty.findings} }
} else {
  left <- tools/corpus-slice-by-id(id = ${inputs.left_id}, slices = ${inputs.slices}) @left
  right <- tools/corpus-slice-by-id(id = ${inputs.right_id}, slices = ${inputs.slices}) @right

  eq <- tools/doubles-equal(
    left = ${left.slice.shannon_entropy},
    right = ${right.slice.shannon_entropy}
  ) @eq

  branch <- if ${eq.equal} {
    empty <- tools/empty-findings() @none
    return { findings = ${empty.findings} }
  } else {
    return {
      findings = [{
        severity = "info",
        category = "ambiguity",
        location = ${left.slice.location},
        claim = "Similar slices diverge in Shannon entropy",
        evidence = "cluster_score=${inputs.cluster.score}; other=${inputs.right_id}; left_entropy=${left.slice.shannon_entropy}; right_entropy=${right.slice.shannon_entropy}",
        suggestion = "Review for contradictory guidance on the same topic"
      }]
    }
  } @branch

  return { findings = ${branch.findings} }
} @pair

return { findings = ${result.findings} }
```
