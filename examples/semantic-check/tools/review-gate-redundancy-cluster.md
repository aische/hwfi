---
name: tools/review-gate-redundancy-cluster
inputs:
  cluster: types/corpus-cluster
  slices: List<types/corpus-slice>
outputs:
  items: List<types/review-gate-item>
imports:
  - tools/corpus-slice-by-id
  - tools/empty-review-gate-items
---

## flow

Build one layer-3 gate item for a redundancy cluster (first two members).

```step
pack <- try {
  left <- tools/corpus-slice-by-id(
    id = ${inputs.cluster.members[0]},
    slices = ${inputs.slices}
  ) @left

  right <- tools/corpus-slice-by-id(
    id = ${inputs.cluster.members[1]},
    slices = ${inputs.slices}
  ) @right

  return {
    items = [{
      location = ${left.slice.location},
      slice_id = ${left.slice.id},
      body = ${left.slice.body},
      gate_source = "redundancy",
      review_task = "check_redundancy",
      peer_location = ${right.slice.location},
      peer_body = ${right.slice.body},
      context = ${inputs.cluster.span},
      priority = 30
    }]
  }
} catch {
  empty <- tools/empty-review-gate-items() @skip
  return { items = ${empty.items} }
} @probe

return { items = ${pack.items} }
```
