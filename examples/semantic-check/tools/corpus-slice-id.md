---
name: tools/corpus-slice-id
inputs:
  location: types/location
outputs:
  id: String
imports:
  - builtin/concat
---

## flow

Stable document id for corpus clustering (`file#section`).

```step
id <- builtin/concat(
  parts = [${inputs.location.file}, "#", ${inputs.location.section}]
) @id

return { id = ${id.text} }
```
