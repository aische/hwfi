# `ship` — capstone coding agent pipeline

A multi-phase **plan → implement → repair → verify → review** workflow that
exercises nearly every v1 capability in one coherent project. Compared to
[`../research`](../research) (read/analyse/synthesize) and [`../coding`](../coding)
(single agent loop), `ship` combines scripted orchestration with agentic steps.

## What it does

Given a user spec and a task list, it:

1. **Authorizes** the run on a secret token (`tools/authorize`).
2. **Plans** with structured JSON via `llm-gen-object` (`workflows/plan`).
3. **Implements** each task with a scoped `llm-agent` (`workflows/implement`).
4. **Repairs** in a capped `while` loop (`workflows/continue-pred` +
   `workflows/repair`, `max_iterations = 2`).
5. **Validates** all targets in parallel with `par` + `builtin/exec` (`sh -n`).
6. **Reviews** the outcome via multi-turn `llm-chat` (`workflows/review`).
7. **Audits** with `builtin/introspect` + `ctx.trace` (`workflows/audit`).

Optional post-run: **`workflows/distill`** slices a prior agent trace and writes a
draft skill (Mode A, spec §6.6).

## Feature coverage

| Feature | Where |
|---------|-------|
| Sub-workflows + tools | `main` → `plan`, `implement`, `repair`, `review`, `audit` |
| Shared type aliases | `types/task`, `types/message`, `types/chat-log` |
| `llm-gen-object` + `Json` schema | `workflows/plan` |
| `llm-agent` + mutation + `exec` | `implement`, `repair` |
| `llm-chat` multi-turn | `tools/converse` → `review` |
| `foreach` / `par` / `while` | `main` (`tasks`, `targets`, repair loop) |
| `builtin/json-get`, `concat`, `log` | `main`, `plan`, `tools/task-line` |
| `find-files`, `grep`, `edit-file` | `implement` agent tools |
| Secrets + `ctx.env` | `SHIP_API_TOKEN`, `ENGINEER_NAME` |
| `ctx.trace` / `introspect` | `workflows/audit` |
| `trace-slice` + skill draft | `workflows/distill` (alternate entry) |

## Prerequisites

The catalog uses **DeepSeek** (`deepseek-v4-flash`). Set `DEEPSEEK_API_KEY` via
[`.env.example`](.env.example) → `.env`, `--env-file`, or your shell.

Two env vars are required at startup (`project.json` `env` whitelist):

```bash
export ENGINEER_NAME="Ada Lovelace"
export SHIP_API_TOKEN="demo-token"
```

## Running it

```bash
cp -r examples/ship/sample-workspace /tmp/ship-ws

cabal run hwfi -- run examples/ship \
  --workspace /tmp/ship-ws \
  --input-json examples/ship/inputs.example.json
```

On success the workspace contains `ship-report.md`, `audit/`, and
`.hwfi/runs/<run-id>/`. Confirm the library scripts pass syntax check:

```bash
sh -n /tmp/ship-ws/lib/greet.sh && sh -n /tmp/ship-ws/lib/farewell.sh
```

Inspect the trace (note redacted secrets and `workflow-log` lines):

```bash
cabal run hwfi -- show /tmp/ship-ws <run-id>
```

## `while` + validation note

v1 expressions have no comparison operators, so the repair predicate cannot branch
on `exit_code` directly. This example uses `workflows/continue-pred` (always
`continue = true`) with a low `max_iterations` cap; the implement/repair agents
run `sh -n` internally and stop when syntax passes. Final verification is the
parallel `par` + `exec` pass over `inputs.targets`.

## Distill a skill (optional)

After a successful run, distill the implement agent step:

```bash
cabal run hwfi -- run examples/ship \
  --workspace /tmp/ship-ws \
  --entry workflows/distill \
  --input source_run=<run-id> \
  --input source_qname=workflows/implement \
  --input source_step_id=implement \
  --input target_path=skills/fix-shell.md \
  --input skill_name=skills/fix-shell \
  --input kind=tool
```

Then `hwfi check /tmp/ship-ws` and promote the skill via `imports:` on a later run.

## Resume

```bash
cabal run hwfi -- resume /tmp/ship-ws <run-id>
```

Agent steps are non-cacheable black boxes, but inner tool calls replay from cache
(§8.2.1). Audit and `builtin/log` steps re-execute on resume (§8.1).
