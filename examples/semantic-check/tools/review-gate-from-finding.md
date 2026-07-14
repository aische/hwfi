---
name: tools/review-gate-from-finding
inputs:
  hint: types/finding
  slices: List<types/corpus-slice>
outputs:
  items: List<types/review-gate-item>
imports:
  - builtin/text-grep
  - tools/corpus-slice-by-id
  - tools/corpus-slice-id
  - tools/empty-review-gate-items
  - tools/string-nonempty
---

## flow

Build one review-gate item from a corpus finding and matching slice body.

```step
pack <- try {
  id <- tools/corpus-slice-id(location = ${inputs.hint.location}) @id

  slice <- tools/corpus-slice-by-id(
    id = ${id.id},
    slices = ${inputs.slices}
  ) @slice

  source <- try {
    grep <- builtin/text-grep(
      text = ${inputs.hint.claim},
      pattern = "diverge in Shannon entropy"
    ) @grep

    _ <- tools/string-nonempty(items = ${grep.matches}) @hit

    return { gate_source = "cluster_divergence" }
  } catch {
    return { gate_source = "entropy_outlier" }
  } @label

  return {
    items = [{
      location = ${inputs.hint.location},
      slice_id = ${slice.slice.id},
      body = ${slice.slice.body},
      gate_source = ${source.gate_source},
      trigger_claim = ${inputs.hint.claim}
    }]
  }
} catch {
  empty <- tools/empty-review-gate-items() @skip
  return { items = ${empty.items} }
} @probe

return { items = ${pack.items} }
```
