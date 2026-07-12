---
name: workflows/main
inputs:
  q: String
outputs:
  answer: String
imports:
  - builtin/llm-agent
  - tools/search
---

## sys

Test agent.

```step
r <- builtin/llm-agent(
  system = @self#sys,
  prompt = ${inputs.q},
  model = "fast",
  tools = [ ${inputs.q} ],
  max_rounds = 1
)
return { answer = ${r.text} }
```
