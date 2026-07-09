---
name: workflows/tick-body
inputs: {}
outputs:
  line: String
imports:
  - builtin/exec
---

## flow

Body workflow for `workflows/tick-stop`. Would append a line via `sh` when the
predicate returns `continue = true`.

```step
out <- builtin/exec(
  program = "sh",
  args = ["-c", "echo tick"],
  stdin = "",
  timeout_ms = 0
) @tick
return { line = ${out.stdout} }
```
