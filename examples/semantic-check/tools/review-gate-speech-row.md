---
name: tools/review-gate-speech-row
inputs:
  hint: types/speech-act-hint
  slices: List<types/corpus-slice>
outputs:
  items: List<types/review-gate-item>
imports:
  - tools/corpus-slice-by-id
  - tools/corpus-slice-id
  - tools/empty-review-gate-items
  - tools/strings-equal
---

## flow

When a speech-act hint is a step↔agent coverage gap, build one review-gate item.

```step
pack <- try {
  gap <- tools/strings-equal(
    left = ${inputs.hint.category},
    right = "coverage_gap"
  ) @gap

  branch <- if ${gap.equal} {
    id <- tools/corpus-slice-id(location = ${inputs.hint.location}) @id

    slice <- tools/corpus-slice-by-id(
      id = ${id.id},
      slices = ${inputs.slices}
    ) @slice

    return {
      items = [{
        location = ${inputs.hint.location},
        slice_id = ${slice.slice.id},
        body = ${slice.slice.body},
        gate_source = "speech_act_mismatch",
        review_task = "check_coverage_gap",
        peer_location = { file = "", section = "" },
        peer_body = "",
        context = ${inputs.hint.evidence},
        priority = 20
      }]
    }
  } else {
    empty <- tools/empty-review-gate-items() @skip
    return { items = ${empty.items} }
  } @build

  return { items = ${branch.items} }
} catch {
  empty <- tools/empty-review-gate-items() @skip
  return { items = ${empty.items} }
} @probe

return { items = ${pack.items} }
```
