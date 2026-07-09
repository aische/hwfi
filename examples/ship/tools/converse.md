---
name: tools/converse
inputs:
  history: types/chat-log
  model: String
outputs:
  text: String
imports:
  - builtin/llm-chat
---

## reviewer

You are a rigorous technical reviewer. You verify that code changes match the
original specification, note remaining risks, and write a concise ship report.
When asked for a final report, output only the report text.

## flow

```step
resp <- builtin/llm-chat(
  system   = @self#reviewer,
  messages = ${inputs.history},
  model    = ${inputs.model}
)
return { text = ${resp.text} }
```
