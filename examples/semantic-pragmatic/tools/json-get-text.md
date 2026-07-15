---
name: tools/json-get-text
inputs:
  json: Json
  path: String
outputs:
  text: String
imports:
  - builtin/concat
  - builtin/json-get
---

## flow

Read one JSON field and render its value as text.

```step
got <- builtin/json-get(json = ${inputs.json}, path = ${inputs.path}) @got

line <- builtin/concat(parts = ["${got.value}"]) @line

return { text = ${line.text} }
```
