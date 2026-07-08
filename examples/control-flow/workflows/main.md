---
name: workflows/main
inputs:
  scripts: List<String>
  strict: Bool
outputs:
  report: String
  first_status: Int
imports:
  - builtin/exec
---

## flow

A **scripted** workflow that exercises the M8 control-flow constructs (spec §13):
`par` (bounded parallel loop), `foreach` (ordered sequential loop), and `if`/`else`
(value-producing conditional). Control-flow constructs are *value-producing*, just
like step calls: a block's value is the value of its last statement, so a loop binds
a `List<U>` and a conditional binds the common type of its two branches.

Every `builtin/exec` call inside the loops and branches is an ordinary cacheable
step, individually content-addressed with an iteration/branch-scoped key. On resume
(spec §8.2) a completed iteration's command is **not** re-run: its result is served
from the cache, so per-iteration side effects apply exactly once across a
run + resume.

```step
-- Syntax-check every script concurrently, at most 4 at a time. `par` preserves
-- input order in the result list regardless of completion order, and aborts on
-- the lowest-index failure. Each iteration's exec step gets a distinct,
-- iteration-scoped cache key.
checks <- par(max = 4) path in ${inputs.scripts} {
  c <- builtin/exec(
    program = "sh",
    args = ["-n", ${path}],
    stdin = "",
    timeout_ms = 0
  )
} @check

-- Record each checked script into a manifest, in input order. `foreach` runs the
-- body once per element sequentially; here the result list is discarded (`_`),
-- so the loop is used purely for its ordered side effects.
_ <- foreach path in ${inputs.scripts} {
  w <- builtin/exec(
    program = "sh",
    args = ["-c", "echo ${path} >> manifest.txt"],
    stdin = "",
    timeout_ms = 0
  )
} @manifest

-- Branch on the caller's flag. Both arms bind the same name and reuse the
-- same step @id@ — legal under block-local scoping (§4.2); only the taken arm
-- runs and the `if` yields that arm's exec record.
summary <- if ${inputs.strict} {
  msg <- builtin/exec(
    program = "sh",
    args = ["-c", "echo STRICT mode: every script must pass"],
    stdin = "",
    timeout_ms = 0
  ) @notify
} else {
  msg <- builtin/exec(
    program = "sh",
    args = ["-c", "echo LENIENT mode: failures are warnings"],
    stdin = "",
    timeout_ms = 0
  ) @notify
} @mode

return { report = ${summary.stdout}, first_status = ${checks[0].exit_code} }
```
