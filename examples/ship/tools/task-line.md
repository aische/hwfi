---
name: tools/task-line
inputs:
  task: Json
outputs:
  line: String
imports:
  - builtin/concat
---

## flow

Render a one-line task summary for the ship report.

```step
line <- builtin/concat(
  parts = ["Task JSON: ", "${inputs.task}"]
)
return { line = ${line.text} }
```
