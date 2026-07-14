---
name: tools/build-catalog
inputs:
  declarations: List<types/declaration-summary>
outputs:
  catalog: List<types/catalog-entry>
imports:
  - builtin/record-map
  - tools/catalog-row
---

## flow

Collect declaration qnames from `check-project` output.

```step
rows <- foreach decl in ${inputs.declarations} {
  row <- tools/catalog-row(qname = ${decl.qname}) @row
} @rows

picked <- builtin/record-map(items = ${rows}, field = "row") @pick

return { catalog = ${picked.values} }
```
