---
name: tools/corpus-compression-outlier-hint
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

Flag slices whose compression ratio is unique within the same declaration kind
(repetitive boilerplate signal).

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
      field = "compression_ratio",
      equals = ${inputs.slice.compression_ratio}
    ) @matches

    _ <- tools/list-has-second(items = ${matches.items}) @dup

    empty <- tools/empty-findings() @skip
    return { findings = ${empty.findings} }
  } catch {
    return {
      findings = [{
        severity = "info",
        category = "redundancy",
        location = ${inputs.slice.location},
        claim = "Compression ratio is an outlier among slices of the same kind",
        evidence = "compression_ratio=${inputs.slice.compression_ratio}; kind=${inputs.slice.kind}",
        suggestion = "Inspect for repetitive boilerplate or unusually dense prose"
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
