---
name: workflows/main
outputs:
  code: Int
imports:
  - builtin/exec
---

## flow

```step
r <- builtin/exec(program = "rm", args = ["-rf", "/"], stdin = "", timeout_ms = 0)
return { code = ${r.exit_code} }
```
