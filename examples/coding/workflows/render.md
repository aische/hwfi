---
name: workflows/render
inputs:
  name: String
outputs:
  greeting: String
  exit_code: Int
imports:
  - builtin/edit-file
  - builtin/exec
---

## flow

A **scripted** (non-agentic) mutation + `exec` pipeline (spec §6.2, §6.3): it
edits a template in place, then runs an allowlisted command to execute it. Both
steps are cacheable — on resume the edit is *not* re-applied and the command is
*not* re-run (the durable-workspace invariant, spec §8.2). `builtin/exec` is
allowlisted to `sh` by `project.json` (`exec.allow`, spec §7.5); a non-zero exit
would be returned as a value, not a run error.

```step
-- Fill the template placeholder with the caller's name (a mutation, §6.2).
_ <- builtin/edit-file(
  path = "hello.sh",
  find = "PLACEHOLDER",
  replace = ${inputs.name},
  expect = 1
) @edit
-- Run the rendered script under the sandbox and capture its output (§6.3).
r <- builtin/exec(
  program = "sh",
  args = ["hello.sh"],
  stdin = "",
  timeout_ms = 0
) @run
return { greeting = ${r.stdout}, exit_code = ${r.exit_code} }
```
