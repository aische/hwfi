---
name: tools/pragmatic-contradiction-findings
inputs:
  value: Json
  location: types/location
outputs:
  findings: List<types/finding>
imports:
  - builtin/json-get
  - builtin/json-values
  - builtin/list-concat
  - builtin/record-map
  - tools/empty-findings
---

## flow

Map `contradictions` objects to contradiction findings.

```step
pack <- try {
  got <- builtin/json-values(json = ${inputs.value}, path = "contradictions") @got

  rows <- foreach row in ${got.values} {
    other <- builtin/json-get(json = ${row}, path = "other_location") @other
    evidence <- builtin/json-get(json = ${row}, path = "evidence") @evidence

    inner <- try {
      return {
        findings = [{
          severity = "warning",
          category = "contradiction",
          location = ${inputs.location},
          claim = "Pragmatic contradiction with another location",
          evidence = "other=${other.value}; ${evidence.value}",
          suggestion = "Reconcile conflicting guidance or narrow scope to one authoritative section"
        }]
      }
    } catch {
      empty <- tools/empty-findings() @skip
      return { findings = ${empty.findings} }
    } @probe

    return { findings = ${inner.findings} }
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
