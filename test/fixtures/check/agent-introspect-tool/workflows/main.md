---
name: workflows/main
inputs:
  q: String
outputs:
  answer: String
imports:
  - builtin/llm-agent
  - workflows/inspect
---

## sys

Agent advertising an introspect-reaching workflow.

## flow

```step
r <- builtin/llm-agent(
  system = @self#sys,
  prompt = ${inputs.q},
  model = "fast",
  tools = [ workflows/inspect ],
  max_rounds = 3
)
return { answer = ${r.text} }
```
