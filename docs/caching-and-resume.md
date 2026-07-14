# Resume and persistence — author guide

hwfi persists every run under `<workspace>/.hwfi/runs/<run-id>/`. Resume
continues from the **machine snapshot** (`machine.json`) plus the append-only
trace — not from a content-addressed step cache.

Normative detail: spec §8, [execution-model.md](execution-model.md).

## Run artifacts

```
run.json          # metadata: project hash, entrypoint, inputs, status
machine.json      # v2 cursor + frames snapshot (written after each transition)
trace.jsonl       # append-only event log
```

There is no `steps/` directory in the v2 runtime.

## How resume works

1. `hwfi run` (or `hwfi continue`) loads `machine.json` if
   present and the run is resumable (`run.json.status ∈ {running, crashed,
   aborted}`).
2. The runtime checks `project_hash` in `run.json` against the current project.
   If the project changed since the run started, continue is refused — start a
   new run id.
3. Execution continues via `stepMachine`: the same cursor, frames, bindings,
   and agent/`par` state as when the snapshot was written.
4. One `Resumed` event is appended to `trace.jsonl`; `seq` continues from the
   last value + 1.

**Completed steps are not skipped by step-key lookup.** If a transition finished
before pause/crash, the snapshot reflects that progress; if it did not, the
transition is re-run.

## Workspace durability

The **workspace** is durable across a run and resume. Side effects from
completed transitions (writes, exec, edits) remain on disk. Resume does not
re-apply work that is already represented in the machine snapshot.

| Situation | Behaviour on resume |
|-----------|---------------------|
| Body iteration completed (foreach/par/while) | Snapshot holds progress; iteration not re-run |
| Step mid-flight when killed | Transition re-run from snapshot |
| Workspace edited out-of-band | Reads see live disk; snapshot does not encode file contents |

## Agent steps

Agent loops (`builtin/llm-agent`) are resumed via **`CurAgent` state in
`machine.json`**, not via per-round sub-keys under `steps/`. Mid-loop resume
continues the same round/tool sequence from the persisted agent state.

## `while` predicate pinning

Predicate `continue`/`reason` decisions are recorded as `while-pred` trace events
(with optional `decision_key`). On resume, if a decision for iteration `i` is
already in the trace, the predicate sub-workflow for that iteration is not
re-invoked (§4.3.5). This matters when the predicate contains non-deterministic
steps such as `builtin/llm-agent`.

## Step-key hashing (static only)

The checker still computes **step-keys** and **fingerprints** for cacheability
classification (§8.1) and Merkle invalidation when callee code changes. These
hashes are **not** used to skip execution on resume in the v2 runtime.

## Inspecting runs

```bash
cabal run hwfi -- show <workspace> <run-id>
```

Shows the trace with secrets redacted.

## CLI

```bash
hwfi run <project-dir> <workspace-dir> <run-id> ...
hwfi continue <workspace-dir> <run-id>    # run to completion from snapshot
hwfi step <workspace-dir> <run-id>      # one transition batch, then pause
```

`hwfi cache clear` and `hwfi cache invalidate` were removed with the v2
cutover (M6). To force a clean retry, use a new `run-id`.
