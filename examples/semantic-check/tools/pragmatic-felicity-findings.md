---
name: tools/pragmatic-felicity-findings
inputs:
  value: Json
  location: types/location
outputs:
  findings: List<types/finding>
imports:
  - builtin/json-values
  - builtin/record-map
  - builtin/list-concat
  - tools/empty-findings
---

## flow

Map `felicity_violations` strings to ambiguity findings.

```step
pack <- try {
  got <- builtin/json-values(json = ${inputs.value}, path = "felicity_violations") @got

  rows <- foreach violation in ${got.values} {
    return {
      findings = [{
        severity = "warning",
        category = "ambiguity",
        location = ${inputs.location},
        claim = "Pragmatic felicity violation",
        evidence = "${violation}",
        suggestion = "Add verifiable conditions or align the directive with workflow capabilities"
      }]
    }
  } @rows

  layers <- builtin/record-map(items = ${rows}, field = "findings") @pick
  flat <- builtin/list-concat(lists = ${layers.values}) @flat

  return { findings = ${flat.items} }
} catch {
  empty <- tools/empty-findings() @skip
  return { findings = ${empty.findings} }
} @probe

return { findings = ${pack.findings} }
```
