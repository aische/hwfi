---
name: tools/corpus-profile-section
inputs:
  file: String
  section: String
  body: String
  kind: String
  qname: String
outputs:
  slice: types/corpus-slice
imports:
  - builtin/text-metrics
  - tools/corpus-slice-id
---

## flow

Compute corpus metrics for one markdown section body.

```step
metrics <- builtin/text-metrics(
  text = ${inputs.body},
  tokenize = "word"
) @metrics

id_pack <- tools/corpus-slice-id(
  location = {
    file = ${inputs.file},
    section = ${inputs.section}
  }
) @id

return {
  slice = {
    id = ${id_pack.id},
    location = {
      file = ${inputs.file},
      section = ${inputs.section}
    },
    kind = ${inputs.kind},
    qname = ${inputs.qname},
    body = ${inputs.body},
    chars = ${metrics.chars},
    tokens = ${metrics.tokens},
    lines = ${metrics.lines},
    paragraphs = ${metrics.paragraphs},
    shannon_entropy = ${metrics.shannon_entropy},
    compression_ratio = ${metrics.compression_ratio}
  }
}
```
