---
name: tools/speech-act-slice-scan
inputs:
  slice: types/corpus-slice
outputs:
  tags: List<types/speech-act-tag>
imports:
  - builtin/list-concat
  - builtin/record-map
  - builtin/split-text
  - tools/speech-act-tag-sentence
---

## flow

Split one corpus slice into sentences and tag each with force heuristics.

```step
chunks <- builtin/split-text(
  text = ${inputs.slice.body},
  max_chars = 0,
  overlap = 0,
  split_on = "sentence"
) @chunks

rows <- foreach sentence in ${chunks.chunks} {
  pack <- tools/speech-act-tag-sentence(
    sentence = ${sentence},
    location = ${inputs.slice.location}
  ) @row
  return { tags = ${pack.tags} }
} @rows

layers <- builtin/record-map(items = ${rows}, field = "tags") @pick
flat <- builtin/list-concat(lists = ${layers.values}) @flat

return { tags = ${flat.items} }
```
