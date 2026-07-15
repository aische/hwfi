---
name: workflows/main
inputs:
  source_run: String
  mode: String
outputs:
  summary_path: String
  summary_text: String
imports:
  - builtin/concat
  - builtin/read-json
  - builtin/write-file
  - tools/mode-is-narrative
  - tools/narrative-summary
  - tools/report-summary
---

## overview

Summarize a `semantic-report.json` from a prior `semantic-check` run.
**Mechanical** mode (default) needs no API keys. **Narrative** mode runs
`llm-generate` on the mechanical digest.

## flow

```step
report_path <- builtin/concat(
  parts = [".hwfi/runs/", "${inputs.source_run}", "/semantic-report.json"]
) @report_path

summary_path <- builtin/concat(
  parts = [".hwfi/runs/", "${inputs.source_run}", "/semantic-summary.md"]
) @summary_path

loaded <- builtin/read-json(path = ${report_path.text}) @load

mechanical <- tools/report-summary(report = ${loaded.value}) @mech

mode_pack <- tools/mode-is-narrative(mode = ${inputs.mode}) @mode

final <- if ${mode_pack.narrative} {
  narrative <- tools/narrative-summary(
    mechanical_text = ${mechanical.summary_text}
  ) @narrative

  return { summary_text = ${narrative.summary_text} }
} else {
  return { summary_text = ${mechanical.summary_text} }
} @pick

_ <- builtin/write-file(
  path = ${summary_path.text},
  text = ${final.summary_text}
) @write

return {
  summary_path = ${summary_path.text},
  summary_text = ${final.summary_text}
}
```
