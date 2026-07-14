---
name: tools/builtin-or-dead
inputs:
  mention: String
  file: String
  section: String
  claim: String
  evidence: String
  suggestion: String
outputs:
  findings: List<types/finding>
imports:
  - tools/is-builtin
  - tools/empty-findings
---

## flow

When a mention is not in the project catalog, accept shipped builtins or emit
a dead-reference finding.

```step
result <- try {
  _ <- tools/is-builtin(mention = ${inputs.mention}) @hit
  pack <- tools/empty-findings() @ok
} catch {
  pack <- tools/dead-ref-finding(
    file = ${inputs.file},
    section = ${inputs.section},
    claim = ${inputs.claim},
    evidence = ${inputs.evidence},
    suggestion = ${inputs.suggestion}
  ) @dead
} @resolve

return { findings = ${result.findings} }
```
