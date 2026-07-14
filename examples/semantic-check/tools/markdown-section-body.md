---
name: tools/markdown-section-body
inputs:
  file: String
  section: String
outputs:
  body: String
imports:
  - builtin/parse-markdown
  - builtin/record-filter
---

## flow

Read one markdown section body by file path and section slug.

```step
pack <- try {
  md <- builtin/parse-markdown(
    path = ${inputs.file},
    sections = true,
    frontmatter = false,
    fences = false
  ) @md

  hits <- builtin/record-filter(
    items = ${md.sections},
    field = "slug",
    equals = ${inputs.section}
  ) @hits

  return { body = ${hits.items[0].body} }
} catch {
  return { body = "" }
} @probe

return { body = ${pack.body} }
```
