---
name: tools/review-gate-from-speech-hint
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

Build one review-gate item from a speech-act hint and matching slice body.

```step
pack <- try {
  id <- tools/corpus-slice-id(location = ${inputs.hint.location}) @id

  slice <- tools/corpus-slice-by-id(
    id = ${id.id},
    slices = ${inputs.slices}
  ) @slice

  gap <- tools/strings-equal(
    left = ${inputs.hint.category},
    right = "coverage_gap"
  ) @gap

  source <- if ${gap.equal} {
    return { gate_source = "speech_act_mismatch" }
  } else {
    return { gate_source = "speech_act_directive" }
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
