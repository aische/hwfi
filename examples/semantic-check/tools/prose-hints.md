---
name: tools/prose-hints
inputs: {}
outputs:
  findings: List<types/finding>
imports:
  - builtin/grep
  - builtin/record-map
  - tools/prose-hint-finding
---

## flow

Layer 1 (interim): flag lines that contain qname-like text for manual review.

```step
hits <- builtin/grep(
  pattern = "(workflows|tools|skills|types|builtin)/[a-zA-Z0-9._-]+",
  path = "."
) @grep

rows <- foreach hit in ${hits.matches} {
  row <- tools/prose-hint-finding(
    file = ${hit.file},
    line = ${hit.line},
    text = ${hit.text}
  ) @row
} @rows

picked <- builtin/record-map(items = ${rows}, field = "finding") @pick

return { findings = ${picked.values} }
```
