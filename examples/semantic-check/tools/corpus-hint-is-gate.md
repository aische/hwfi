---
name: tools/corpus-hint-is-gate
inputs:
  hint: types/finding
outputs:
  gate: Bool
imports:
  - builtin/text-grep
  - tools/string-nonempty
---

## flow

True when a corpus hint should feed layer 3 (entropy outlier or cluster divergence).

```step
pack <- try {
  grep <- builtin/text-grep(
    text = ${inputs.hint.claim},
    pattern = "entropy is an outlier|diverge in Shannon entropy"
  ) @grep

  _ <- tools/string-nonempty(items = ${grep.matches}) @hit

  return { gate = true }
} catch {
  return { gate = false }
} @probe

return { gate = ${pack.gate} }
```
