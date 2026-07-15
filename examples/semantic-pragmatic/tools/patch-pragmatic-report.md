---
name: tools/patch-pragmatic-report
inputs:
  report: Json
  findings: List<types/finding>
outputs:
  text: String
imports:
  - builtin/concat
  - builtin/json-get
---

## flow

Re-serialize a `semantic-report.json` value with updated `pragmatic_findings`.
Embed `json-get` values directly — they already render as valid JSON literals.

```step
schema <- builtin/json-get(json = ${inputs.report}, path = "schema") @schema
mode <- builtin/json-get(json = ${inputs.report}, path = "mode") @mode
entry <- builtin/json-get(json = ${inputs.report}, path = "entry") @entry
ok <- builtin/json-get(json = ${inputs.report}, path = "ok") @ok
check_error <- builtin/json-get(json = ${inputs.report}, path = "check_error") @err
review_gate <- builtin/json-get(json = ${inputs.report}, path = "review_gate") @gate
structural_errors <- builtin/json-get(json = ${inputs.report}, path = "structural_errors") @se
structural_warnings <- builtin/json-get(json = ${inputs.report}, path = "structural_warnings") @sw
entry_findings <- builtin/json-get(json = ${inputs.report}, path = "entry_findings") @ef
prose_hints <- builtin/json-get(json = ${inputs.report}, path = "prose_hints") @ph
step_referential <- builtin/json-get(json = ${inputs.report}, path = "step_referential") @sr
corpus_profile <- builtin/json-get(json = ${inputs.report}, path = "corpus_profile") @cp
corpus_hints <- builtin/json-get(json = ${inputs.report}, path = "corpus_hints") @ch
speech_act_hints <- builtin/json-get(json = ${inputs.report}, path = "speech_act_hints") @sa

report_text <- builtin/concat(parts = [
  "{\n",
  "  \"schema\": ", "${schema.value}", ",\n",
  "  \"mode\": ", "${mode.value}", ",\n",
  "  \"entry\": ", "${entry.value}", ",\n",
  "  \"ok\": ", "${ok.value}", ",\n",
  "  \"check_error\": ", "${check_error.value}", ",\n",
  "  \"review_gate\": ", "${review_gate.value}", ",\n",
  "  \"structural_errors\": ", "${structural_errors.value}", ",\n",
  "  \"structural_warnings\": ", "${structural_warnings.value}", ",\n",
  "  \"entry_findings\": ", "${entry_findings.value}", ",\n",
  "  \"prose_hints\": ", "${prose_hints.value}", ",\n",
  "  \"step_referential\": ", "${step_referential.value}", ",\n",
  "  \"corpus_profile\": ", "${corpus_profile.value}", ",\n",
  "  \"corpus_hints\": ", "${corpus_hints.value}", ",\n",
  "  \"speech_act_hints\": ", "${speech_act_hints.value}", ",\n",
  "  \"pragmatic_findings\": ", "${inputs.findings}", "\n",
  "}\n"
]) @report

return { text = ${report_text.text} }
```
