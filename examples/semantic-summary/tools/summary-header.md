---
name: tools/summary-header
inputs:
  report: Json
outputs:
  text: String
imports:
  - builtin/concat
  - tools/json-get-text
  - tools/report-ok-label
  - tools/review-gate-note
---

## flow

Render the markdown header for a semantic summary.

```step
entry <- tools/json-get-text(json = ${inputs.report}, path = "entry") @entry
mode <- tools/json-get-text(json = ${inputs.report}, path = "mode") @mode

status <- tools/report-ok-label(report = ${inputs.report}) @status
gate <- tools/review-gate-note(report = ${inputs.report}) @gate

header <- builtin/concat(
  parts = [
    "# Semantic review summary\n\n",
    "- Schema: semantic-report/v1\n",
    "- Entry: ",
    ${entry.text},
    "\n",
    "- Report mode: ",
    ${mode.text},
    "\n",
    "- Structural check: ",
    ${status.label},
    "\n",
    "- Review gate: ",
    ${gate.text},
    "\n\n",
    "Actionable findings (`error` and `warning` only). Info-level corpus and ",
    "speech-act hints are omitted — see `semantic-report.json`.\n"
  ]
) @header

return { text = ${header.text} }
```
