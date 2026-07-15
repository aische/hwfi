---
name: tools/collect-actionable-findings
inputs:
  report: Json
outputs:
  findings: List<Json>
imports:
  - builtin/list-concat
  - tools/filter-actionable-findings
  - tools/json-values-or-empty
---

## flow

Merge actionable finding arrays from a `semantic-report.json` value.

```step
structural_errors <- tools/json-values-or-empty(
  json = ${inputs.report},
  path = "structural_errors"
) @se

structural_warnings <- tools/json-values-or-empty(
  json = ${inputs.report},
  path = "structural_warnings"
) @sw

entry_findings <- tools/json-values-or-empty(
  json = ${inputs.report},
  path = "entry_findings"
) @ef

prose_hints <- tools/json-values-or-empty(
  json = ${inputs.report},
  path = "prose_hints"
) @ph

corpus_hints <- tools/json-values-or-empty(
  json = ${inputs.report},
  path = "corpus_hints"
) @ch

pragmatic_findings <- tools/json-values-or-empty(
  json = ${inputs.report},
  path = "pragmatic_findings"
) @pf

corpus_actionable <- tools/filter-actionable-findings(
  findings = ${corpus_hints.values}
) @ca

merged <- builtin/list-concat(lists = [
  ${structural_errors.values},
  ${structural_warnings.values},
  ${entry_findings.values},
  ${prose_hints.values},
  ${corpus_actionable.findings},
  ${pragmatic_findings.values}
]) @merged

return { findings = ${merged.items} }
```
