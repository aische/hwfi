---
name: tools/speech-act-hint-is-gate
inputs:
  hint: types/speech-act-hint
outputs:
  gate: Bool
imports:
  - builtin/text-grep
  - tools/string-nonempty
  - tools/strings-equal
---

## flow

True when a speech-act hint is a step↔agent mismatch or unguarded directive.

```step
gap <- tools/strings-equal(
  left = ${inputs.hint.category},
  right = "coverage_gap"
) @gap

pack <- if ${gap.equal} {
  return { gate = true }
} else {
  amb <- tools/strings-equal(
    left = ${inputs.hint.category},
    right = "ambiguity"
  ) @amb

  inner <- if ${amb.equal} {
    probe <- try {
      grep <- builtin/text-grep(
        text = ${inputs.hint.claim},
        pattern = "Directive sentence lacks"
      ) @grep

      _ <- tools/string-nonempty(items = ${grep.matches}) @hit

      return { gate = true }
    } catch {
      return { gate = false }
    } @probe

    return { gate = ${probe.gate} }
  } else {
    return { gate = false }
  } @branch

  return { gate = ${inner.gate} }
} @kind

return { gate = ${pack.gate} }
```
