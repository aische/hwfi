---
name: tools/corpus-entropy-outlier-hint
inputs:
  slice: types/corpus-slice
  slices: List<types/corpus-slice>
outputs:
  findings: List<types/finding>
imports:
  - builtin/record-filter
  - tools/empty-findings
  - tools/list-has-second
---

## flow

Flag slices whose Shannon entropy is unique within the same declaration kind.

```step
peers <- builtin/record-filter(
  items = ${inputs.slices},
  field = "kind",
  equals = ${inputs.slice.kind}
) @peers

pack <- try {
  _ <- tools/list-has-second(items = ${peers.items}) @count

  inner <- try {
    matches <- builtin/record-filter(
      items = ${peers.items},
      field = "shannon_entropy",
      equals = ${inputs.slice.shannon_entropy}
    ) @matches

    _ <- tools/list-has-second(items = ${matches.items}) @dup

    empty <- tools/empty-findings() @skip
    return { findings = ${empty.findings} }
  } catch {
    return {
      findings = [{
        severity = "info",
        category = "ambiguity",
        location = ${inputs.slice.location},
        claim = "Shannon entropy is an outlier among slices of the same kind",
        evidence = "entropy=${inputs.slice.shannon_entropy}; kind=${inputs.slice.kind}",
        suggestion = "Inspect whether information density is unusually high or low for this slice"
      }]
    }
  } @unique

  return { findings = ${inner.findings} }
} catch {
  empty <- tools/empty-findings() @skip
  return { findings = ${empty.findings} }
} @probe

return { findings = ${pack.findings} }
```
