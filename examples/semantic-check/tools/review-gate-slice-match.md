---
name: tools/review-gate-slice-match
inputs:
  slice: types/corpus-slice
  candidates: List<types/review-gate-item>
outputs:
  hit: Bool
  item: types/review-gate-item
imports:
  - builtin/list-concat
  - builtin/record-map
  - tools/empty-review-gate-items
  - tools/location-equal
---

## flow

When any candidate matches this slice location, return the first gate item.

```step
rows <- foreach cand in ${inputs.candidates} {
  loc <- tools/location-equal(
    left = ${cand.location},
    right = ${inputs.slice.location}
  ) @loc

  pack <- if ${loc.equal} {
    return {
      items = [{
        location = ${inputs.slice.location},
        slice_id = ${inputs.slice.id},
        body = ${inputs.slice.body},
        gate_source = ${cand.gate_source},
        review_task = ${cand.review_task},
        peer_location = ${cand.peer_location},
        peer_body = ${cand.peer_body},
        context = ${cand.context},
        priority = ${cand.priority}
      }]
    }
  } else {
    empty <- tools/empty-review-gate-items() @skip
    return { items = ${empty.items} }
  } @branch

  return { items = ${pack.items} }
} @rows

layers <- builtin/record-map(items = ${rows}, field = "items") @pick
flat <- builtin/list-concat(lists = ${layers.values}) @flat

pack <- try {
  return {
    hit = true,
    item = ${flat.items[0]}
  }
} catch {
  return {
    hit = false,
    item = {
      location = ${inputs.slice.location},
      slice_id = ${inputs.slice.id},
      body = "",
      gate_source = "",
      review_task = "",
      peer_location = { file = "", section = "" },
      peer_body = "",
      context = "",
      priority = 0
    }
  }
} @probe

return { hit = ${pack.hit}, item = ${pack.item} }
```
