---
name: tools/corpus-clusters
inputs:
  slices: List<types/corpus-slice>
outputs:
  clusters: List<types/corpus-cluster>
imports:
  - builtin/record-map
  - builtin/text-search-corpus
---

## flow

Cluster similar prose slices via `text-search-corpus`.

```step
doc_rows <- foreach slice in ${inputs.slices} {
  return {
    doc = {
      id = ${slice.id},
      text = ${slice.body}
    }
  }
} @docs

picked <- builtin/record-map(items = ${doc_rows}, field = "doc") @pick

search <- builtin/text-search-corpus(
  documents = ${picked.values},
  method = "jaccard",
  threshold = 0.35,
  ngram = 3
) @search

return { clusters = ${search.clusters} }
```
