---
kind: type-alias
name: types/corpus-slice
definition: "Record<{ id: String, location: types/location, kind: String, qname: String, body: String, chars: Int, tokens: Int, lines: Int, paragraphs: Int, shannon_entropy: Double, compression_ratio: Double }>"
---

Internal prose slice with body text for layer 2 clustering. Not emitted in the
public report — map to `types/corpus-profile` for `corpus_profile`.
