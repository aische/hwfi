---
name: tools/prose-hints
inputs:
  catalog: List<types/catalog-entry>
outputs:
  findings: List<types/finding>
imports:
  - builtin/find-files
  - builtin/list-concat
  - builtin/record-map
  - tools/empty-findings
  - tools/prose-file-scan
---

## flow

Layer 1: flag unresolved qname mentions in project markdown prose.

```step
paths <- builtin/find-files(path = ".", glob = "**/*.md") @paths

qnames <- builtin/record-map(items = ${inputs.catalog}, field = "qname") @qmap

file_rows <- foreach path in ${paths.paths} {
  result <- try {
    pack <- tools/prose-file-scan(
      file = ${path},
      catalog = ${qnames.values}
    ) @file
    return { findings = ${pack.findings} }
  } catch {
    empty <- tools/empty-findings() @skip
    return { findings = ${empty.findings} }
  } @scan
} @files

layers <- builtin/record-map(items = ${file_rows}, field = "findings") @pick
flat <- builtin/list-concat(lists = ${layers.values}) @flat

return { findings = ${flat.items} }
```
