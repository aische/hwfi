---
name: tools/narrative-summary
inputs:
  mechanical_text: String
outputs:
  summary_text: String
imports:
  - builtin/concat
  - builtin/llm-generate
---

## synthesizer

You turn a mechanical semantic-review summary into a short human-facing report.
Prioritize errors and warnings; group related items; suggest fix order. Use
markdown with a short title, 1–2 sentence overview, then bullet priorities.
Do not invent findings not present in the input.

## flow

Synthesize a narrative digest from the mechanical summary text.

```step
prompt <- builtin/concat(
  parts = [
    "Mechanical semantic review summary:\n\n",
    ${inputs.mechanical_text}
  ]
) @prompt

summary <- builtin/llm-generate(
  system = @self#synthesizer,
  prompt = ${prompt.text},
  model = "fast"
) @llm

return { summary_text = ${summary.text} }
```
