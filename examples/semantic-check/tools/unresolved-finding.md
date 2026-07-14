---
name: tools/unresolved-finding
inputs:
  mention: String
  catalog: List<types/catalog-entry>
  file: String
  section: String
  claim: String
  evidence: String
  suggestion: String
outputs:
  findings: List<types/finding>
imports:
  - builtin/record-filter
  - tools/nonempty
  - tools/builtin-or-dead
  - tools/empty-findings
---

## flow

Emit a dead-reference finding when `mention` is absent from the project catalog
and is not a shipped builtin.

```step
hits <- builtin/record-filter(
  items = ${inputs.catalog},
  field = "qname",
  equals = ${inputs.mention}
) @filter

result <- try {
  _ <- tools/nonempty(items = ${hits.items}) @project_hit
  pack <- tools/empty-findings() @ok
} catch {
  pack <- tools/builtin-or-dead(
    mention = ${inputs.mention},
    file = ${inputs.file},
    section = ${inputs.section},
    claim = ${inputs.claim},
    evidence = ${inputs.evidence},
    suggestion = ${inputs.suggestion}
  ) @fallback
} @resolve

return { findings = ${result.findings} }
```
