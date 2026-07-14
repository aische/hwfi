---
name: tools/pragmatic-filter-findings
inputs:
  findings: List<types/finding>
outputs:
  findings: List<types/finding>
imports:
  - builtin/list-concat
  - builtin/record-map
  - tools/empty-findings
  - tools/pragmatic-felicity-valid
  - tools/strings-equal
---

## flow

Drop pragmatic felicity rows that fail trigger-bleed validation.

```step
rows <- foreach finding in ${inputs.findings} {
  pack <- try {
    felicity <- tools/strings-equal(
      left = ${finding.claim},
      right = "Pragmatic felicity violation"
    ) @felicity

    branch <- if ${felicity.equal} {
      valid <- tools/pragmatic-felicity-valid(
        evidence = ${finding.evidence}
      ) @valid

      inner <- if ${valid.valid} {
        return { findings = [${finding}] }
      } else {
        empty <- tools/empty-findings() @skip
        return { findings = ${empty.findings} }
      } @inner

      return { findings = ${inner.findings} }
    } else {
      return { findings = [${finding}] }
    } @branch

    return { findings = ${branch.findings} }
  } catch {
    return { findings = [${finding}] }
  } @probe
} @rows

layers <- builtin/record-map(items = ${rows}, field = "findings") @pick
flat <- builtin/list-concat(lists = ${layers.values}) @flat

return { findings = ${flat.items} }
```
