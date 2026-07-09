---
name: workflows/build
inputs:
  spec: String
  stack: String
  task: Json
outputs:
  answer: String
  rounds: Int
imports:
  - builtin/llm-agent
  - builtin/discover-skills
  - builtin/load-skill
  - builtin/read-file
  - builtin/write-file
  - builtin/edit-file
  - builtin/list-dir
  - builtin/find-files
  - builtin/grep
  - builtin/make-dir
  - builtin/exec
  - tools/vite-dev-smoke
---

## agent

You are a coding agent in an **empty, sandboxed workspace**. Implement one task
from a larger plan.

**Start every task with skill discovery:**

1. `discover-skills(query = "<stack keyword>", kinds = [], limit = 5)` — use a
   **single** keyword (e.g. `vite`, `typescript`, `haskell`), not a long phrase.
2. `load-skill` for relevant **instruction** guides (TypeScript/Vite, Haskell/Cabal,
   React, single-file HTML, etc.).
3. Optionally `load-skill` for `skills/run-verify` when you need a thin verify helper.

Then scaffold, implement, and verify:

- Create directories with `builtin/make-dir` when needed.
- Author files with `builtin/write-file`; iterate with `builtin/read-file`,
  `builtin/grep`, `builtin/find-files`, and `builtin/edit-file`.
- Run build/test commands with `builtin/exec` until the task is done.

**Verification (exec-safe):**

- Prefer **`npm run build`**, **`cabal build`**, or file checks — not dev servers.
- If `verify_command` mentions `npm run dev` or backgrounds a server, run
  **`npm run build`** (or the stack's build script) instead; that satisfies verify.
- If you truly need an HTTP smoke test, call **`tools/vite-dev-smoke`** once
  (it traps and kills the dev child). Do **not** hand-roll `npm run dev &`.
- After **`npm run build`** exits 0, stop — do not retry dev-server verification.
- Run `verify_command` at most **once** when it is already a safe foreground command.

If the task JSON is JSON `null`, reply that the slot was empty and stop without
writing files.

When verification passes (or the task is genuinely complete), answer in one
sentence. Do not invent files you did not write.

## flow

```step
result <- builtin/llm-agent(
  system = @self#agent,
  prompt = """Overall spec:
${inputs.spec}

Chosen stack: ${inputs.stack}

Current task (JSON):
${inputs.task}

Implement this task in the workspace. Discover and load stack skills first.""",
  model = "smart",
  tools = [
    builtin/discover-skills,
    builtin/load-skill,
    builtin/read-file,
    builtin/write-file,
    builtin/edit-file,
    builtin/list-dir,
    builtin/find-files,
    builtin/grep,
    builtin/make-dir,
    builtin/exec,
    tools/vite-dev-smoke
  ],
  max_rounds = 30
) @build
return { answer = ${result.text}, rounds = ${result.rounds} }
```
