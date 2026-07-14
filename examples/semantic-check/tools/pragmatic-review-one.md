---
name: tools/pragmatic-review-one
inputs:
  item: types/review-gate-item
  schema: Json
outputs:
  findings: List<types/finding>
imports:
  - builtin/concat
  - builtin/llm-gen-object
  - tools/empty-findings
  - tools/pragmatic-llm-to-findings
---

## reviewer

You review workflow prose for pragmatic coherence. Given a flagged slice and trigger,
identify illocutionary force, felicity problems, contradictions with other locations,
and an overall clarity score from 0 to 1. Be conservative: only flag issues with
evidence in the text. Return JSON matching the supplied schema exactly.

## flow

Run `llm-gen-object` on one gated slice.

```step
prompt <- builtin/concat(
  parts = [
    "Gate source: ",
    ${inputs.item.gate_source},
    "\nTrigger: ",
    ${inputs.item.trigger_claim},
    "\nLocation: ",
    ${inputs.item.location.file},
    "#",
    ${inputs.item.location.section},
    "\n\nSlice body:\n",
    ${inputs.item.body}
  ]
) @prompt

pack <- try {
  obj <- builtin/llm-gen-object(
    system = @self#reviewer,
    prompt = ${prompt.text},
    schema = ${inputs.schema},
    model = "fast"
  ) @llm

  converted <- tools/pragmatic-llm-to-findings(
    value = ${obj.value},
    location = ${inputs.item.location}
  ) @findings

  return { findings = ${converted.findings} }
} catch {
  empty <- tools/empty-findings() @skip
  return { findings = ${empty.findings} }
} @probe

return { findings = ${pack.findings} }
```
