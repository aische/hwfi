---
name: tools/pragmatic-felicity-valid
inputs:
  evidence: String
outputs:
  valid: Bool
imports:
  - builtin/text-grep
  - tools/string-nonempty
---

## flow

Reject felicity strings that repeat layer-2 trigger boilerplate instead of slice prose.

```step
pack <- try {
  bleed <- builtin/text-grep(
    text = ${inputs.evidence},
    pattern = "Shannon entropy|outlier among slices|compression ratio|diverge in Shannon|Directive sentence lacks|review tooling"
  ) @bleed

  _ <- tools/string-nonempty(items = ${bleed.matches}) @hit

  return { valid = false }
} catch {
  return { valid = true }
} @probe

return { valid = ${pack.valid} }
```
