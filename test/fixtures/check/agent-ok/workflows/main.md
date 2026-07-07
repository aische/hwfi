---
name: workflows/main
inputs:
  q: String
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
  tools = [ tools/search, workflows/fetch ],
  max_rounds = 4
)
return { answer = ${r.text} }
```
