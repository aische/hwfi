---
name: tools/prose-hints
inputs: {}
outputs:
  findings: List<types/finding>
imports:
  - builtin/grep
---

## flow

Layer 1 (interim): flag lines that contain qname-like text for manual review.

```step
hits <- builtin/grep(
  pattern = "(workflows|tools|skills|types|builtin)/[a-zA-Z0-9._-]+",
  path = "."
) @grep

findings <- foreach hit in ${hits.matches} {
  return {
    severity = "info",
    category = "dead_reference",
    location = { file = ${hit.file}, section = "" },
    claim = "Prose or step block mentions a qname-like token",
    evidence = ${hit.text},
    suggestion = "Confirm the mention resolves; replace grep hints with resolve-qnames-in-text when available"
  }
} @rows

return { findings = ${findings} }
```
