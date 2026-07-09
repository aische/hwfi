---
name: workflows/implement
inputs:
  task: types/task
outputs:
  answer: String
  rounds: Int
imports:
  - builtin/llm-agent
  - builtin/read-file
  - builtin/grep
  - builtin/find-files
  - builtin/edit-file
  - builtin/exec
---

## agent

You are a coding agent in a sandboxed workspace. Implement or repair the target
file for the given task.

Workflow:

1. Run `sh -n <target>` via `builtin/exec` to see syntax errors.
2. Use `builtin/read-file`, `builtin/grep`, and `builtin/find-files` to inspect.
3. Use `builtin/edit-file` for the smallest fix that satisfies the task.
4. Re-run `sh -n` until it exits 0.

When the syntax check passes, stop calling tools and reply in one sentence.

## flow

```step
result <- builtin/llm-agent(
  system = @self#agent,
  prompt = """Task [${inputs.task.id}]: ${inputs.task.description}

Target file: ${inputs.task.target}

Repair or implement the file so `sh -n ${inputs.task.target}` exits 0.""",
  model = "smart",
  tools = [
    builtin/read-file,
    builtin/grep,
    builtin/find-files,
    builtin/edit-file,
    builtin/exec
  ],
  max_rounds = 12
) @implement
return { answer = ${result.text}, rounds = ${result.rounds} }
```
