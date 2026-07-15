---
name: workflows/main
inputs:
  report: Json
  mode: String
  out: String
outputs:
  summary_path: String
  summary_text: String
imports:
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
mechanical <- tools/report-summary(report = ${inputs.report}) @mech

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
  path = ${inputs.out},
  text = ${final.summary_text}
) @write

return {
  summary_path = ${inputs.out},
  summary_text = ${final.summary_text}
}
```
