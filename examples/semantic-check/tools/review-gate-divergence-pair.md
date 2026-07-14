---
name: tools/review-gate-divergence-pair
inputs:
  left_id: String
  right_id: String
  cluster: types/corpus-cluster
  slices: List<types/corpus-slice>
outputs:
  items: List<types/review-gate-item>
imports:
  - tools/corpus-slice-by-id
  - tools/doubles-equal
  - tools/empty-review-gate-items
  - tools/strings-equal
---

## flow

When two cluster members have divergent entropy, build a contradiction-review gate item.

```step
same <- tools/strings-equal(
  left = ${inputs.left_id},
  right = ${inputs.right_id}
) @same

pack <- if ${same.equal} {
  empty <- tools/empty-review-gate-items() @none
  return { items = ${empty.items} }
} else {
  left <- tools/corpus-slice-by-id(
    id = ${inputs.left_id},
    slices = ${inputs.slices}
  ) @left

  right <- tools/corpus-slice-by-id(
    id = ${inputs.right_id},
    slices = ${inputs.slices}
  ) @right

  eq <- tools/doubles-equal(
    left = ${left.slice.shannon_entropy},
    right = ${right.slice.shannon_entropy}
  ) @eq

  branch <- if ${eq.equal} {
    empty <- tools/empty-review-gate-items() @none
    return { items = ${empty.items} }
  } else {
    return {
      items = [{
        location = ${left.slice.location},
        slice_id = ${left.slice.id},
        body = ${left.slice.body},
        gate_source = "cluster_divergence",
        review_task = "check_contradiction",
        peer_location = ${right.slice.location},
        peer_body = ${right.slice.body},
        context = "cluster_score=${inputs.cluster.score}; left_entropy=${left.slice.shannon_entropy}; right_entropy=${right.slice.shannon_entropy}",
        priority = 20
      }]
    }
  } @branch

  return { items = ${branch.items} }
} @pair

return { items = ${pack.items} }
```
