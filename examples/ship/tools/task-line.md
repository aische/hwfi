---
name: tools/task-line
inputs:
  task: types/task
outputs:
  line: String
imports:
  - builtin/concat
---

## flow

Render a one-line task summary with `builtin/concat` (§13.1.2).

```step
line <- builtin/concat(
  parts = [
    "[",
    ${inputs.task.id},
    "] ",
    ${inputs.task.description},
    " → ",
    ${inputs.task.target}
  ]
)
return { line = ${line.text} }
```
