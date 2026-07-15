---
name: tools/report-as-text
inputs:
  report: Json
outputs:
  text: String
imports:
  - builtin/concat
---

## flow

Render the full report JSON as text for pattern matching.

```step
line <- builtin/concat(parts = ["${inputs.report}"]) @line
return { text = ${line.text} }
```
