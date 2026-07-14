---
name: tools/doubles-equal
inputs:
  left: Double
  right: Double
outputs:
  equal: Bool
imports:
  - builtin/record-filter
  - tools/double-row-first
---

## flow

Return whether two doubles are exactly equal (via `record-filter`).

```step
hits <- builtin/record-filter(
  items = [{ value = ${inputs.left} }],
  field = "value",
  equals = ${inputs.right}
) @hits

result <- try {
  _ <- tools/double-row-first(items = ${hits.items}) @hit
  return { equal = true }
} catch {
  return { equal = false }
} @probe

return { equal = ${result.equal} }
```
