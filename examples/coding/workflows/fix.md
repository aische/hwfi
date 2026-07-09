---
name: workflows/fix
inputs:
  target: String
outputs:
  answer: String
  rounds: Int
imports:
  - builtin/llm-agent
  - builtin/read-file
  - builtin/grep
  - builtin/edit-file
  - builtin/exec
---

## agent

You are a coding agent working inside a sandboxed workspace. A shell script has a
syntax error that makes `sh -n <file>` fail. The sample is usually missing `fi`
to close an `if` block inside a function.

Workflow:

1. Run `builtin/exec` with `program = "sh"` and `args = ["-n", <file>]` to see the
   error and its line number.
2. Use `builtin/read-file` (and `builtin/grep` if helpful) to inspect the file.
3. Use `builtin/edit-file` to make the smallest change that fixes the syntax.
4. Re-run `sh -n <file>` to confirm it now exits 0.

When the check returns `exit_code = 0`, stop calling tools immediately and reply
in one sentence describing the fix. Do not fabricate file contents — always read
before you edit.

## flow

An LLM-driven coding loop (spec §6.1): instead of a fixed script, `builtin/llm-agent`
advertises the read/navigation/mutation/exec builtins to the model and lets it
decide which to call, and in what order, until the build passes. The agent step
is a non-cacheable black box to the enclosing workflow (spec §8.1), but every
model round and tool call inside it is content-addressed, so a resumed run
replays the model's prior choices and tool results — and does not re-run the
mutations or commands — without re-paying the LLM (spec §8.2.1).

```step
result <- builtin/llm-agent(
  system = @self#agent,
  prompt = "Fix the syntax error in ${inputs.target} so that `sh -n ${inputs.target}` passes.",
  model = "smart",
  tools = [ builtin/read-file, builtin/grep, builtin/edit-file, builtin/exec ],
  max_rounds = 12
) @fix
return { answer = ${result.text}, rounds = ${result.rounds} }
```
