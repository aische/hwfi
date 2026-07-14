---
name: tools/referential-scan
inputs:
  declarations: List<types/declaration-summary>
  catalog: List<types/catalog-entry>
outputs:
  step_results: types/step-ref-matrix
imports:
  - tools/step-ref-findings
---

## flow

Walk declaration step metadata with nested `foreach` (decl → step).

```step
step_results <- foreach decl in ${inputs.declarations} {
  per_step <- foreach step in ${decl.steps} {
    pack <- tools/step-ref-findings(
      step = ${step},
      file = ${decl.path},
      catalog = ${inputs.catalog}
    ) @step
  } @steps
} @decls

return { step_results = ${step_results} }
```
