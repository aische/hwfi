---
name: tools/finding-as-text
inputs:
  finding: Json
outputs:
  text: String
imports:
  - builtin/concat
---

## flow

Render a finding JSON value as text for pattern matching.

```step
line <- builtin/concat(parts = ["${inputs.finding}"]) @line
return { text = ${line.text} }
```
