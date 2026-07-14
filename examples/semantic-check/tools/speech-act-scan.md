---
name: tools/speech-act-scan
inputs:
  slices: List<types/corpus-slice>
outputs:
  tags: List<types/speech-act-tag>
imports:
  - builtin/list-concat
  - builtin/record-map
  - tools/speech-act-slice-scan
---

## flow

Layer 2b: pattern-based illocutionary tagging over corpus slices.

```step
rows <- foreach slice in ${inputs.slices} {
  pack <- tools/speech-act-slice-scan(slice = ${slice}) @slice
  return { tags = ${pack.tags} }
} @rows

layers <- builtin/record-map(items = ${rows}, field = "tags") @pick
flat <- builtin/list-concat(lists = ${layers.values}) @flat

return { tags = ${flat.items} }
```
