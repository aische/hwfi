---
name: tools/entry-finding
inputs:
  entry: String
  catalog: List<types/catalog-entry>
outputs:
  findings: List<types/finding>
imports:
  - builtin/record-filter
  - tools/nonempty
  - tools/empty-findings
  - tools/entry-missing-finding
---

## flow

Warn when the requested entrypoint qname is absent from the checked project.

```step
hits <- builtin/record-filter(
  items = ${inputs.catalog},
  field = "qname",
  equals = ${inputs.entry}
) @filter

result <- try {
  _ <- tools/nonempty(items = ${hits.items}) @hit
  pack <- tools/empty-findings() @ok
} catch {
  pack <- tools/entry-missing-finding(entry = ${inputs.entry}) @miss
} @resolve

return { findings = ${result.findings} }
```
