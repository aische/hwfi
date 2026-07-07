---
name: workflows/main
outputs:
  code: Int
imports:
  - builtin/exec
---

## flow

```step
r <- builtin/exec(program = "git", args = ["status"], stdin = "", timeout_ms = 0)
return { code = ${r.exit_code} }
```
