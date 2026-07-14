# Status

Last updated: 2026-07-14

## Current focus

**v2 runtime (cursor + frames)** — M6 done: single resume story via
`machine.json` + `MachineRun`. Design: [execution-model.md](execution-model.md).

**M5** (DB / server `ProjectStore`) remains deferred — optional, not blocking
local filesystem mode.

## Done recently

- **CLI UX** — `hwfi run` prints `run-id` on stderr; bare `hwfi` shows help;
  removed `resume` alias (use `continue`).
- **Resume robustness** — Collapse step dispatch into one transition; skip
  persisting `CurDispatch`; checkpoint before agent LLM/tool I/O; flush snapshot
  on crash/interrupt.
- **Resume snapshot fix** — Tagged `RValue` encoding in `machine.json` preserves
  typed bindings (`VRecord`/`VString`/…).
- **M6 cleanup** — Purged stale step-cache docs/examples; fixed runtime
  comments; wired `cacheable` trace flags from checker.

## Blockers

None.

## Next up

[TASKS.md](TASKS.md) — M5 (optional) or v1.1 backlog.
