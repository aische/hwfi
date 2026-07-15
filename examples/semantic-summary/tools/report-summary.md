---
name: tools/report-summary
inputs:
  report: Json
outputs:
  summary_text: String
imports:
  - builtin/concat
  - tools/collect-actionable-findings
  - tools/render-findings-body
  - tools/summary-header
---

## flow

Build a mechanical markdown summary from `semantic-report.json`.

```step
header <- tools/summary-header(report = ${inputs.report}) @header

collected <- tools/collect-actionable-findings(report = ${inputs.report}) @collected

body <- tools/render-findings-body(
  findings = ${collected.findings}
) @body

summary <- builtin/concat(
  parts = [${header.text}, ${body.text}]
) @summary

return { summary_text = ${summary.text} }
```
