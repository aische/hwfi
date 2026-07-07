---
name: workflows/main
inputs:
  task: String
outputs:
  answer: String
imports:
  - builtin/llm-agent
  - builtin/read-file
  - builtin/edit-file
  - builtin/exec
---

## sys

You are a coding agent. Read, edit, and build to satisfy the task.

## flow

```step
r <- builtin/llm-agent(
  system = @self#sys,
  prompt = ${inputs.task},
  model = "fast",
  tools = [ builtin/read-file, builtin/edit-file, builtin/exec ],
  max_rounds = 8
)
return { answer = ${r.text} }
```
