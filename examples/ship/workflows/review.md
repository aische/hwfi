---
name: workflows/review
inputs:
  spec: String
  plan: Json
  notes: String
outputs:
  summary: String
imports:
  - tools/converse
---

## flow

Multi-turn review over the ship report using `tools/converse` → `builtin/llm-chat`.

```step
out <- tools/converse(
  model = "smart",
  history = [
    {
      role = "user",
      content = """Original spec:

${inputs.spec}

Structured plan (JSON):
${inputs.plan}

Implementation log:
${inputs.notes}

Write a concise ship report: what was fixed, what was verified, and any risks."""
    },
    { role = "assistant", content = "Understood. I will review the changes against the spec." },
    { role = "user", content = "Return only the final ship report." }
  ]
) @review
return { summary = ${out.text} }
```
