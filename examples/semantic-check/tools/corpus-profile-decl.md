---
name: tools/corpus-profile-decl
inputs:
  decl: types/declaration-summary
outputs:
  slices: List<types/corpus-slice>
imports:
  - builtin/list-concat
  - builtin/parse-markdown
  - builtin/record-map
  - tools/corpus-profile-section
---

## flow

Parse one declaration file and profile each markdown section.

```step
md <- builtin/parse-markdown(
  path = ${inputs.decl.path},
  sections = true,
  frontmatter = false,
  fences = false
) @md

sec_rows <- foreach sec in ${md.sections} {
  pack <- tools/corpus-profile-section(
    file = ${inputs.decl.path},
    section = ${sec.slug},
    body = ${sec.body},
    kind = ${inputs.decl.kind},
    qname = ${inputs.decl.qname}
  ) @sec
  return { slice = ${pack.slice} }
} @sections

picked <- builtin/record-map(items = ${sec_rows}, field = "slice") @pick

return { slices = ${picked.values} }
```
