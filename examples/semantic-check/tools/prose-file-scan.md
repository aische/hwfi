---
name: tools/prose-file-scan
inputs:
  file: String
  catalog: List<String>
outputs:
  findings: List<types/finding>
imports:
  - builtin/list-concat
  - builtin/parse-markdown
  - builtin/record-map
  - tools/prose-section-scan
---

## flow

Parse a markdown file and scan each section for unresolved prose qnames.

```step
md <- builtin/parse-markdown(
  path = ${inputs.file},
  sections = true,
  frontmatter = false,
  fences = false
) @md

sec_rows <- foreach sec in ${md.sections} {
  pack <- tools/prose-section-scan(
    file = ${inputs.file},
    section = ${sec.slug},
    body = ${sec.body},
    catalog = ${inputs.catalog}
  ) @sec
  return { findings = ${pack.findings} }
} @sections

layers <- builtin/record-map(items = ${sec_rows}, field = "findings") @pick
flat <- builtin/list-concat(lists = ${layers.values}) @flat

return { findings = ${flat.items} }
```
