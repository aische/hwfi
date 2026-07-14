---
name: tools/speech-act-tag-is-directive
inputs:
  tag: types/speech-act-tag
  file: String
  section: String
outputs:
  ok: Bool
imports:
  - tools/strings-equal
---

## flow

True when the tag is a directive in the given file/section.

```step
force <- tools/strings-equal(
  left = ${inputs.tag.force},
  right = "directive"
) @force_chk

pack <- if ${force.equal} {
  file <- tools/strings-equal(
    left = ${inputs.tag.location.file},
    right = ${inputs.file}
  ) @file_chk

  inner <- if ${file.equal} {
    section <- tools/strings-equal(
      left = ${inputs.tag.location.section},
      right = ${inputs.section}
    ) @section_chk
    branch <- if ${section.equal} {
      return { ok = true }
    } else {
      return { ok = false }
    } @section_branch
    return { ok = ${branch.ok} }
  } else {
    return { ok = false }
  } @file_branch

  return { ok = ${inner.ok} }
} else {
  return { ok = false }
} @force_branch

return { ok = ${pack.ok} }
```
