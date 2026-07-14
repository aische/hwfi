---
name: tools/corpus-profile-public
inputs:
  slice: types/corpus-slice
outputs:
  row: types/corpus-profile
imports: []
---

## flow

Strip internal body text for the public report row.

```step
return {
  row = {
    location = ${inputs.slice.location},
    kind = ${inputs.slice.kind},
    qname = ${inputs.slice.qname},
    chars = ${inputs.slice.chars},
    tokens = ${inputs.slice.tokens},
    lines = ${inputs.slice.lines},
    paragraphs = ${inputs.slice.paragraphs},
    shannon_entropy = ${inputs.slice.shannon_entropy},
    compression_ratio = ${inputs.slice.compression_ratio}
  }
}
```
