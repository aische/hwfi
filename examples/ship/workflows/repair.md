---
name: workflows/repair
inputs:
  task: types/task
outputs:
  note: String
  rounds: Int
imports:
  - builtin/llm-agent
  - builtin/read-file
  - builtin/edit-file
  - builtin/exec
---

## agent

You are a focused repair agent. The target file still fails `sh -n`. Read the
file, apply the smallest edit, and re-run the syntax check until it passes.

## flow

```step
result <- builtin/llm-agent(
  system = @self#agent,
  prompt = "Repair ${inputs.task.target}: ${inputs.task.description}",
  model = "smart",
  tools = [ builtin/read-file, builtin/edit-file, builtin/exec ],
  max_rounds = 6
) @repair
return { note = ${result.text}, rounds = ${result.rounds} }
```
