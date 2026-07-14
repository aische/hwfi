# Tutorial 4: Show and continue

Inspect durable runs, understand machine snapshots, and continue without redoing
completed work.

**Time:** ~15 minutes  
**Example:** [`examples/coding`](../../examples/coding) (scripted `render` works
without an API key; agent `fix` optional)

## What you will learn

- Where run state lives in the workspace
- Reading traces with `hwfi show`
- Continue behaviour via `machine.json`
- When to start a new run id instead of continuing

Normative detail: [caching-and-resume.md](../caching-and-resume.md).

## 1. Run and capture the run id

Use a fresh scratch workspace:

```bash
rm -rf /tmp/continue-ws
cp -r examples/coding/sample-workspace /tmp/continue-ws

cabal run hwfi -- run examples/coding \
  --workspace /tmp/continue-ws \
  --input name="Bob"
```

The CLI prints the run id on stderr (`run-id: …`) and result JSON on stdout.
You can also read it from the directory name under `.hwfi/runs/`:

```bash
ls /tmp/continue-ws/.hwfi/runs/
export RUN_ID=$(ls /tmp/continue-ws/.hwfi/runs/ | head -1)
echo $RUN_ID
```

Each run directory contains `run.json`, `machine.json`, and `trace.jsonl`.

## 2. Inspect the trace

```bash
cabal run hwfi -- show /tmp/continue-ws $RUN_ID
```

Look for:

| Event kind | Meaning |
|------------|---------|
| `step-start` | Step beginning (may show `[cacheable]` from static classification) |
| `file-io` | `read-file`, `write-file`, `edit-file` |
| `exec` | Allowlisted command (`sh`, …) with exit code |
| `loop-start` / `loop-end` | Control-flow loops (in other examples) |

The trace **redacts secrets**. Actual values used at runtime live in
`run.json.inputs` and on the workspace filesystem.

## 3. Continue an interrupted run

`hwfi continue` only works when the run did **not**
finish cleanly. Continuable statuses: `running` (process killed or crashed
mid-run), `aborted` (workflow error), `crashed`. A **`completed`** run returns
an error — that is expected.

### What continue does

`hwfi continue` loads `machine.json` and drives via `stepMachine`. Completed
transitions are reflected in the snapshot; mid-flight work is re-run from the
saved cursor and frames.

For `workflows/render` that means:

- A completed `edit-file` step is **not** re-applied (workspace already mutated)
- A completed `exec` step is **not** re-run

Mutations stay on disk; the snapshot records orchestration progress.

### Hands-on (optional, needs API key)

The agent loop runs long enough to interrupt. Start a repair run and press
**Ctrl+C** once the run has started (after a few seconds is usually enough):

```bash
cp -r examples/coding/sample-workspace /tmp/coding-ws

cabal run hwfi -- run examples/coding \
  --workspace /tmp/coding-ws \
  --entry workflows/fix \
  --input target=broken.sh
# Ctrl+C once tool calls appear

export RUN_ID=$(ls /tmp/coding-ws/.hwfi/runs/ | head -1)
cabal run hwfi -- continue /tmp/coding-ws $RUN_ID
```

On continue, the agent picks up from `CurAgent` state in `machine.json` — prior
rounds and tool calls are not replayed from a step cache.

### Inspect the snapshot

After any run (completed or interrupted):

```bash
ls /tmp/continue-ws/.hwfi/runs/$RUN_ID/
# run.json  machine.json  trace.jsonl
```

Use `hwfi show` for the event log. See [caching-and-resume.md](../caching-and-resume.md)
for semantics.

## 4. Fresh retries during development

`hwfi continue` refuses when the **project** changed since the run started
(`project_hash` in `run.json` no longer matches). Edit workflow source and
start a new run id.

For a clean slate without project edits, use a new workspace directory or a new
`run-id` under the same workspace.

`hwfi cache clear` and `hwfi cache invalidate` were removed in the v2 runtime.

## 5. Workspace vs snapshot

| Situation | Behaviour |
|-----------|-----------|
| Completed `write-file` / `edit-file` | File on disk; write not re-applied on continue |
| Completed `read-file` before pause | Snapshot holds progress; read not repeated if step finished |
| You edit a file **outside** the workflow | Reads see live disk on the next `read-file` |

**Rule:** treat the workspace as source of truth for mutations; treat
`machine.json` as source of truth for orchestration progress.

## 6. Try control-flow continue

[`examples/control-flow`](../../examples/control-flow) exercises foreach/par/while
continue. Interrupt a run or continue after a workflow error — a completed run is
not continuable. See [`examples/control-flow/README.md`](../../examples/control-flow/README.md).

## 7. Done

You have walked through the core path:

1. [Hello](01-hello.md) — file pipeline, no keys
2. [Check](02-check.md) — static validation
3. [Agent](03-agent.md) — tool loop with exec
4. **Show and continue** — observability and durability

Continue with the [workflow author reference](../workflow-reference.md) or the
advanced examples on the [tutorial hub](README.md).
