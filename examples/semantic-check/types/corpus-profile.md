---
kind: type-alias
name: types/corpus-profile
definition: "Record<{ location: types/location, kind: String, qname: String, chars: Int, tokens: Int, lines: Int, paragraphs: Int, shannon_entropy: Double, compression_ratio: Double }>"
---

Per-slice corpus metrics row for `semantic-report/v1` (`corpus_profile`).
