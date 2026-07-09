---
name: skills/run-verify
skill:
  kind: callable
  summary: Run a shell verify command and report exit status
  tags: [shell, verify, exec]
inputs:
  command: String
outputs:
  exit_code: Int
  stdout: String
imports:
  - builtin/exec
---

```step
r <- builtin/exec(
  program = "sh",
  args = ["-c", ${inputs.command}],
  stdin = "",
  timeout_ms = 0
)
return { exit_code = ${r.exit_code}, stdout = ${r.stdout} }
```
