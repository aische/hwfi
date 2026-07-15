---
name: tools/strings-equal
inputs:
  left: String
  right: String
outputs:
  equal: Bool
imports:
  - builtin/record-filter
  - tools/string-row-first
---

## flow

Return whether two strings are equal (via `record-filter`).

```step
hits <- builtin/record-filter(
  items = [{ value = ${inputs.left} }],
  field = "value",
  equals = ${inputs.right}
) @hits

result <- try {
  _ <- tools/string-row-first(items = ${hits.items}) @hit
  return { equal = true }
} catch {
  return { equal = false }
} @probe

return { equal = ${result.equal} }
```
