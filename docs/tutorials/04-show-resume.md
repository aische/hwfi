# Tutorial 4: Show and resume

Inspect durable runs, understand step caching, and resume without redoing
completed work.

**Time:** ~15 minutes  
**Example:** [`examples/coding`](../../examples/coding) (scripted `render` works
without an API key; agent `fix` optional)

## What you will learn

- Where run state lives in the workspace
- Reading traces with `hwfi show`
- Resume behaviour for cacheable steps
- When to use `hwfi cache clear`

Normative detail: [caching-and-resume.md](../caching-and-resume.md).

## 1. Run and capture the run id

Use a fresh scratch workspace:

```bash
rm -rf /tmp/resume-ws
cp -r examples/coding/sample-workspace /tmp/resume-ws

cabal run hwfi -- run examples/coding \
  --workspace /tmp/resume-ws \
  --input name="Bob"
```

The CLI prints result JSON. The run id is also the directory name under
`.hwfi/runs/`:

```bash
ls /tmp/resume-ws/.hwfi/runs/
export RUN_ID=$(ls /tmp/resume-ws/.hwfi/runs/ | head -1)
echo $RUN_ID
```

Each run directory contains `run.json`, `trace.jsonl`, and cached step results
under `steps/`.

## 2. Inspect the trace

```bash
cabal run hwfi -- show /tmp/resume-ws $RUN_ID
```

Look for:

| Event kind | Meaning |
|------------|---------|
| `step-start` | Cacheable step beginning (may show `[cacheable]`) |
| `file-io` | `read-file`, `write-file`, `edit-file` |
| `exec` | Allowlisted command (`sh`, …) with exit code |
| `loop-start` / `loop-end` | Control-flow loops (in other examples) |

The trace **redacts secrets**; step result files under `steps/` hold actual
values used on resume.

## 3. Resume an interrupted run

`hwfi resume` only works when the run did **not** finish cleanly. Resumable
statuses: `running` (process killed or crashed mid-run), `aborted` (workflow
error), `crashed`. A **`completed`** run returns an error — that is expected.

### What resume does

Resume re-executes orchestration but **reuses cached step results** for
cacheable steps. For `workflows/render` that means:

- A cached `edit-file` step is **not** re-applied
- A cached `exec` step is **not** re-run

Mutations and command results stay on disk; the cache stores step *outputs* so
resume does not repeat side effects.

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
cabal run hwfi -- resume /tmp/coding-ws $RUN_ID
```

On resume, prior model rounds and tool calls replay from cache — the agent does
not re-pay for LLM calls or re-apply edits it already made.

### Inspect cache without resume

After any completed run, cached step results live under the run directory:

```bash
ls /tmp/resume-ws/.hwfi/runs/$RUN_ID/steps/
```

Use `hwfi show` to correlate trace events with those files. See
[caching-and-resume.md](../caching-and-resume.md) for semantics.

## 4. Cache clear during development

Automatic invalidation handles **workflow source edits** (Merkle fingerprints).
You may need manual busting when:

- Workspace files changed outside the workflow but step inputs did not
- You are re-running tutorial steps against an old run directory
- You suspect a corrupted `steps/` entry after a crash

```bash
cabal run hwfi -- cache clear /tmp/resume-ws $RUN_ID

# Or invalidate from a specific step onward (keeps upstream cache):
cabal run hwfi -- cache invalidate /tmp/resume-ws $RUN_ID --from-step workflows/main#edit
```

Then `resume` recomputes cleared steps. For a clean slate, use a new workspace
directory instead.

## 5. Workspace vs cache

| Situation | Behaviour |
|-----------|-----------|
| Cached `write-file` / `edit-file` | File on disk; write not re-applied on resume |
| Cached `read-file` | Returns cached text; does **not** re-read disk |
| You edit a file **outside** the workflow | Cached `read-file` may return stale content |

**Rule:** treat the workspace as source of truth for mutations; treat the cache
as memoization for unchanged code and inputs.

## 6. Try control-flow resume

[`examples/control-flow`](../../examples/control-flow) loops cache per iteration.
Interrupt a run or resume after a workflow error to see per-iteration cache
behaviour — a completed run is not resumable. See
[`examples/control-flow/README.md`](../../examples/control-flow/README.md).

## 7. Done

You have walked through the core path:

1. [Hello](01-hello.md) — file pipeline, no keys
2. [Check](02-check.md) — static validation
3. [Agent](03-agent.md) — tool loop with exec
4. **Show and resume** — observability and durability

Continue with the [workflow author reference](../workflow-reference.md) or the
advanced examples on the [tutorial hub](README.md).
