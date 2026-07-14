---
name: tools/review-gate-dedupe-cap
inputs:
  items: List<types/review-gate-item>
  slices: List<types/corpus-slice>
outputs:
  items: List<types/review-gate-item>
imports:
  - builtin/list-concat
  - builtin/record-map
  - tools/empty-review-gate-items
  - tools/review-gate-first-eight
  - tools/review-gate-slice-match
---

## flow

Deduplicate gate candidates by slice location, then cap at eight items.

```step
rows <- foreach slice in ${inputs.slices} {
  pack <- tools/review-gate-slice-match(
    slice = ${slice},
    candidates = ${inputs.items}
  ) @match

  branch <- if ${pack.hit} {
    return { items = [${pack.item}] }
  } else {
    empty <- tools/empty-review-gate-items() @skip
    return { items = ${empty.items} }
  } @branch

  return { items = ${branch.items} }
} @rows

layers <- builtin/record-map(items = ${rows}, field = "items") @pick
flat <- builtin/list-concat(lists = ${layers.values}) @flat

capped <- tools/review-gate-first-eight(items = ${flat.items}) @cap

return { items = ${capped.items} }
```
