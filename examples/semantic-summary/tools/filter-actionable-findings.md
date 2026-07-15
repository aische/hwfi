---
name: tools/filter-actionable-findings
inputs:
  findings: List<Json>
outputs:
  findings: List<Json>
imports:
  - builtin/list-concat
  - builtin/record-map
  - tools/finding-is-actionable
---

## flow

Keep findings whose severity is `error` or `warning`.

```step
rows <- foreach finding in ${inputs.findings} {
  act <- tools/finding-is-actionable(finding = ${finding}) @act

  pack <- if ${act.actionable} {
    return { findings = [${finding}] }
  } else {
    return { findings = [] }
  } @branch

  return { findings = ${pack.findings} }
} @rows

layers <- builtin/record-map(items = ${rows}, field = "findings") @pick
flat <- builtin/list-concat(lists = ${layers.values}) @flat

return { findings = ${flat.items} }
```
