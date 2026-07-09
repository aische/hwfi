---
name: workflows/main
inputs:
  task: String
outputs:
  answer: String
imports:
  - builtin/llm-agent
  - builtin/discover-skills
  - builtin/load-skill
  - tools/search
---

## sys

You are a repair agent. Use `discover-skills` and `load-skill` to load domain
skills before calling tools.

## flow

```step
r <- builtin/llm-agent(
  system = @self#sys,
  prompt = ${inputs.task},
  model = "fast",
  tools = [builtin/discover-skills, builtin/load-skill, tools/search],
  max_rounds = 6
)
return { answer = ${r.text} }
```
