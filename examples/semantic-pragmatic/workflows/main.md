---
name: workflows/main
inputs:
  source_run: String
  schema: Json
outputs:
  report_path: String
imports:
  - builtin/concat
  - builtin/read-json
  - builtin/write-file
  - tools/json-values-or-empty
  - tools/patch-pragmatic-report
  - tools/pragmatic-review-gate-json
---

## overview

Optional layer 3 pragmatic review. Loads `semantic-report.json` from a prior
`semantic-check` run, runs bounded `llm-gen-object` on `review_gate` items, and
writes `pragmatic_findings` back into the same run directory.

## flow

```step
report_path <- builtin/concat(
  parts = [".hwfi/runs/", "${inputs.source_run}", "/semantic-report.json"]
) @report_path

loaded <- builtin/read-json(path = ${report_path.text}) @load

gate <- tools/json-values-or-empty(
  json = ${loaded.value},
  path = "review_gate"
) @gate

review <- tools/pragmatic-review-gate-json(
  items = ${gate.values},
  schema = ${inputs.schema}
) @review

patched <- tools/patch-pragmatic-report(
  report = ${loaded.value},
  findings = ${review.findings}
) @patched

_ <- builtin/write-file(
  path = ${report_path.text},
  text = ${patched.text}
) @write

return {
  report_path = ${report_path.text}
}
```
