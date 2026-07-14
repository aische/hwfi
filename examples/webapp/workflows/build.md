---
name: workflows/build
inputs:
  spec: String
outputs:
  answer: String
  rounds: Int
imports:
  - builtin/llm-agent
  - builtin/read-file
  - builtin/write-file
  - builtin/edit-file
  - builtin/exec
---

## agent

You are a front-end coding agent working in an empty, sandboxed workspace. Build
a single self-contained `index.html` file (inline CSS and JavaScript, no external
dependencies or network requests) that implements the web app described by the
user.

Workflow:

1. Write the file with `builtin/write-file` (path `index.html`), authoring the
   complete HTML/CSS/JS yourself to satisfy the user's description.
2. Verify it with `builtin/exec`: `program = "sh"`,
   `args = ["-c", "test -s index.html && grep -qi '<html' index.html"]`. A zero
   exit means the file exists and looks like an HTML document.
3. If the check fails, inspect the file with `builtin/read-file`, fix it with
   `builtin/edit-file`, and re-run the check.

Keep the app usable and self-contained. When the check passes, answer in one
sentence describing what you built. Do not invent file contents you did not
actually write.

## flow

An LLM-driven builder (spec §6.1): the app is authored **at runtime** from the
user's `spec` input — nothing is copied. `builtin/llm-agent` advertises the
read/write/edit/exec builtins and lets the model create `index.html` from
nothing, then self-check it with an allowlisted command, editing until it passes.
The agent step is a non-cacheable black box (spec §8.1). Resume continues from
`CurAgent` state in `machine.json` (spec §8).

```step
result <- builtin/llm-agent(
  system = @self#agent,
  prompt = ${inputs.spec},
  model = "deepseek4flash",
  tools = [ builtin/read-file, builtin/write-file, builtin/edit-file, builtin/exec ],
  max_rounds = 10
) @build
return { answer = ${result.text}, rounds = ${result.rounds} }
```
