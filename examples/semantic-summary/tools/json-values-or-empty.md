---
name: tools/json-values-or-empty
inputs:
  json: Json
  path: String
outputs:
  values: List<Json>
imports:
  - builtin/json-values
---

## flow

Return `json-values` list or an empty list when the path is missing.

```step
pack <- try {
  got <- builtin/json-values(json = ${inputs.json}, path = ${inputs.path}) @got
  return { values = ${got.values} }
} catch {
  return { values = [] }
} @probe

return { values = ${pack.values} }
```
