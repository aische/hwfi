---
name: tools/json-get-location
inputs:
  json: Json
  path: String
outputs:
  location: types/location
imports:
  - builtin/json-get-string
---

## flow

Read a nested location object from JSON without double-encoding string fields.

```step
file <- builtin/json-get-string(
  json = ${inputs.json},
  path = "${inputs.path}.file"
) @file

section <- builtin/json-get-string(
  json = ${inputs.json},
  path = "${inputs.path}.section"
) @section

return {
  location = {
    file = ${file.text},
    section = ${section.text}
  }
}
```
