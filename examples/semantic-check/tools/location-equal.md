---
name: tools/location-equal
inputs:
  left: types/location
  right: types/location
outputs:
  equal: Bool
imports:
  - tools/strings-equal
---

## flow

Return whether two source locations match (file and section).

```step
file <- tools/strings-equal(
  left = ${inputs.left.file},
  right = ${inputs.right.file}
) @file

pack <- if ${file.equal} {
  section <- tools/strings-equal(
    left = ${inputs.left.section},
    right = ${inputs.right.section}
  ) @section
  return { equal = ${section.equal} }
} else {
  return { equal = false }
} @branch

return { equal = ${pack.equal} }
```
