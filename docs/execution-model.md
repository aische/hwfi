# Execution model (v2 runtime)

Design for the **cursor + frames** machine runtime. Legacy step-cache behaviour
is documented historically in git history pre-M6; author guide:
[caching-and-resume.md](caching-and-resume.md).

## Goals

1. **Explicit pause / step** — operator or API can stop after a transition and
   continue later.
2. **Exact restore** — resume loads the persisted machine snapshot and continues
   as if execution had not stopped (including mid–agent-loop and mid–`par`).
3. **Real `par`** — bounded concurrent branch execution (keep hwfi’s pool).
4. **User confirmation** — cooperative global freeze inside an active `par` pool.
5. **Pluggable stores** — filesystem locally; database on server (phase 2).

Non-goals for this tranche: Lisp IR, deleting the markdown surface, backward
compat with `.hwfi/runs/*/steps/` cache layout.

## Unit of execution

A **transition** is one atomic step of the machine:

- enter / complete one workflow statement (`bind <- callee …`)
- one LLM model call (agent round)
- one agent tool call
- one sync builtin that does not decompose further

Crash or explicit pause persists state **after** a completed transition, or
**before** starting the next. A transition interrupted mid-flight (e.g. kill
during HTTP) is re-run on resume.

CLI/API `step` runs until: `paused`, `awaiting_confirm`, `par` join boundary
(relaxed stepping), or run end.

## Machine shape

```
Machine
  status          running | draining | paused | completed | failed
  project_hash    staleness check on continue
  scope           step-key-style prefix (branch/iteration disambiguation)
  path            StmtPath — where we are in the static AST
  current         what is being reduced now (agent model/tool, dispatch, …)
  frames          defunctionalized continuations (seq, par join, while, try, …)
  bindings        name → RValue
  last_result     value of last completed statement in this block
```

The **program** (workflow AST) is not stored in the snapshot; it is reloaded
from `ProjectStore` by `project_hash`. The snapshot stores **position + data**.

### StmtPath

Address in the checked AST:

- `qname` of the enclosing workflow
- stack of `(statement_index, block_kind)` for nested `if` / loop / `try` / inline
  `while` bodies

Helper: `Hwfi.Runtime.MachinePath`.

## `par` and confirmation (policy)

**Real parallelism** with a **cooperative global freeze** when any branch hits a
confirm gate:

1. Scheduler stops **starting** new transitions on any branch.
2. In-flight branches **finish the current transition** only.
3. Run → `draining`, then `paused` with `awaiting_confirm`.
4. User approves → blocked branch continues; scheduler resumes until next
   gate, join, or end.

No branch may start a new transition while the pool is draining or paused for
confirm. This avoids workspace races while one branch waits for a human.

### Per-branch crash/resume

`FrPar` holds:

- evaluated item list and per-index slot (`pending | running | done | failed |
  awaiting_confirm`)
- `active :: Map Int Machine` — full branch machines for in-flight work
- scheduler cursor (`next_index`, concurrency cap)
- pool phase (`scheduling | draining | paused_confirm`)

Completed iterations are **not** re-run on resume. In-flight branches restore
from their `BranchMachine` snapshot.

## Persistence

### Run snapshot (source of truth for control flow)

One JSON blob per persisted point (every transition, or on pause/crash flush):

```
run_snapshots(run_id, seq, snapshot_json, at)
```

Legacy `steps/<step-key>.json` skip-as-resume is **deprecated** by this model.

### Trace (audit)

Append-only events remain for `hwfi show` and `ctx.trace`, but progress is
defined by the machine snapshot, not cache hits.

### Project store (optional / deferred)

Server mode: workflows in DB, not on disk. `ProjectStore` loads declarations by
`project_id` / hash. Local mode keeps filesystem project dir. Not scheduled until
after M6; may not ship.

## Staleness

If `project_hash` at continue time ≠ snapshot’s hash → refuse continue (or
require new run). No Merkle auto-invalidation of memoized steps; the snapshot
is authoritative.

## Migration plan

| Phase | Deliverable |
|-------|-------------|
| **M0** (now) | `Machine` types, `StmtPath`, snapshot JSON, tests |
| **M1** | `stepMachine` for sequential statements + builtins |
| **M2** | Agent as `Current` states; drop agent sub-key replay |
| **M3** | `FrPar` + cooperative confirm + branch snapshots |
| **M4** | CLI `step` / `resume`; replace `performResume` |
| **M6** | Remove step-key cache path, update spec §8 (**done**) |
| **M5** | `ProjectStore` DB + server API (optional; deferred) |

## Modules

| Module | Role |
|--------|------|
| `Hwfi.Runtime.Machine` | `Machine`, `Current`, `Frame`, status |
| `Hwfi.Runtime.MachinePath` | AST navigation by `StmtPath` |
| `Hwfi.Runtime.MachineSnapshot` | JSON encode/decode |
| `Hwfi.Runtime.StepDriver` | `stepMachine` interpreter loop |

## References

- Prior art: [llm-workflow](https://github.com/aische/llm-workflow) `Stack (Step, Kont)`
  — same transition idea; hwfi uses untyped serializable state instead of GADTs.
- Legacy: [caching-and-resume.md](caching-and-resume.md), spec §8.1–§8.2.
