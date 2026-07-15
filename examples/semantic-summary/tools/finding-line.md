---
name: tools/finding-line
inputs:
  finding: Json
outputs:
  line: String
imports:
  - builtin/concat
  - tools/finding-as-text
---

## flow

Render one finding as a markdown bullet line (compact JSON).

```step
text <- tools/finding-as-text(finding = ${inputs.finding}) @text

line <- builtin/concat(
  parts = ["- ", ${text.text}, "\n"]
) @line

return { line = ${line.text} }
```
