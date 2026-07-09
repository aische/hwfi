---
name: workflows/main
inputs:
  q: String
  toolbox: List<Json>
outputs:
  answer: String
imports:
  - builtin/llm-agent
  - tools/search
  - workflows/fetch
---

## sys

You are a helpful research agent. Use the tools when they help.

## flow

```step
r <- builtin/llm-agent(
  system = @self#sys,
  prompt = ${inputs.q},
  model = "fast",
  tools = ${inputs.toolbox},
  max_rounds = 4
)
return { answer = ${r.text} }
```
