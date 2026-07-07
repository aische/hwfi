---
name: workflows/main
inputs:
  q: String
outputs:
  answer: String
imports:
  - builtin/llm-agent
  - tools/privileged
---

## sys

Agent with an ineligible tool.

## flow

```step
r <- builtin/llm-agent(
  system = @self#sys,
  prompt = ${inputs.q},
  model = "fast",
  tools = [ tools/privileged ],
  max_rounds = 3
)
return { answer = ${r.text} }
```
